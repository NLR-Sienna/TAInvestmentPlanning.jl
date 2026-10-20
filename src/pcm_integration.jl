# src/pcm_integration.jl
#
# Post-optimal validation: build expanded PowerSystems.System from CEM investment decisions
# and run a full production cost simulation (PCM) to validate CEM cost estimates.
#
# Workflow:
#   1. Extract investment decisions from CEM results (MW built per technology)
#   2. Build the case base system and add new generators at their target buses
#   3. Attach renewable capacity factor and load time series
#   4. Run annual UC simulation using existing infrastructure from simulation.jl
#   5. Compare CEM operational cost estimate vs PCM realized cost

"""
    build_post_investment_system(investment_results::Dict{String, Float64};
                                 arrivals::Vector{LoadArrival}=LoadArrival[],
                                 diesel_price::Float64=5.0) -> PSY.System

Build the case base system and add new generators and loads.

Arguments:
  investment_results: Dict mapping technology name to MW built (from CEM results extraction)
  arrivals: Optional vector of LoadArrival objects to add as new loads to the system
            (for post-investment validation). If empty, uses baseline system loads only.
  diesel_price: Diesel fuel price in dollars per gallon (default 5.0)

Returns:
  Expanded PowerSystems.System with new generators and optional load arrivals at appropriate buses
"""
function build_post_investment_system(
    investment_results::Dict{String, Float64};
    arrivals::Vector{<:Any} = [],
    diesel_price::Float64 = case_default_diesel_price(),
)
    # Start from the baseline system (operates in per-unit internally)
    sys, timestamps = build_case_system(; diesel_price=diesel_price, verbose=false)
    adjust_pcm_system!(sys, timestamps)

    # Add each built technology (system stays in per-unit)
    for (tech_name, capacity_mw) in investment_results
        capacity_mw > 0.1 || continue  # skip negligible builds
        _add_investment_to_system!(sys, tech_name, capacity_mw, timestamps, diesel_price)
    end

    # Add load arrivals if provided (for validation of post-investment system)
    if !isempty(arrivals)
        _add_load_arrivals_to_system!(sys, arrivals, timestamps)
        # Transform arrival time series to Deterministic forecasts to match base system format
        # (base system already has Deterministic forecasts; this ensures arrivals match)
        PSY.transform_single_time_series!(sys, Hour(48), Hour(24))
    end

    return sys
end

"""
    _attach_wind_time_series!(sys, gen)

Attach wind capacity factor time series to a RenewableDispatch wind generator by copying from existing wind generator.
"""
function _attach_wind_time_series!(sys::PSY.System, gen::PSY.RenewableDispatch)
    try
        # Get existing wind generator from base system
        existing_wind = PSY.get_component(PSY.RenewableDispatch, sys, settings().pcm.reference_wind_unit)
        if isnothing(existing_wind)
            @debug "Existing wind generator not found, skipping time series attachment"
            return
        end

        # Copy max_active_power time series (normalized profile) from existing wind generator
        if !PSY.has_time_series(existing_wind, PSY.SingleTimeSeries, "max_active_power")
            @debug "Existing wind generator has no max_active_power time series"
            return
        end
        ta = PSY.get_time_series_array(PSY.SingleTimeSeries, existing_wind, "max_active_power")

        # Create new time series with the same data
        new_ts = PowerSystems.SingleTimeSeries("max_active_power", ta)
        PSY.add_time_series!(sys, gen, new_ts)
        @info "Attached wind time series to $(PSY.get_name(gen))"

    catch e
        @warn "Error attaching wind time series to $(PSY.get_name(gen)): $e"
    end
end

"""
    _add_investment_to_system!(sys, tech_name, capacity_mw, timestamps, diesel_price)

Internal helper: instantiate a new generator in the system based on investment decision.

For renewables: creates RenewableDispatch with zero operating cost.
For diesel: creates ThermalStandard with fuel cost curve from build_system.jl.

All power values are converted from MW to per-unit on the component base, which is the system base power (100.0 MW).
"""
function _add_investment_to_system!(sys::PSY.System, tech_name::String, capacity_mw::Float64, timestamps::Vector{DateTime}, diesel_price::Float64=case_default_diesel_price())
    entry = get(settings().catalog, tech_name, nothing)
    isnothing(entry) && error("Built technology $tech_name is not in the case technology catalog")
    bus_name = something(entry.pcm_bus, settings().pcm.default_bus)
    bus = PSY.get_component(PSY.ACBus, sys, bus_name)

    sys_base_power = PSY.get_base_power(sys)  # 100.0 MW
    capacity_pu = capacity_mw / sys_base_power

    if entry.kind == "Wind"
        # Wind expansion: RenewableDispatch with zero variable cost
        gen = PSY.RenewableDispatch(;
            name = tech_name,
            available = true,
            bus = bus,
            active_power = capacity_pu,
            reactive_power = 0.0,
            rating = capacity_pu,
            prime_mover_type = PSY.PrimeMovers.WT,
            power_factor = 1.0,
            reactive_power_limits = nothing,
            base_power = sys_base_power,
            operation_cost = PSY.RenewableGenerationCost(nothing),
            input_basis = u"CU",
        )
        PSY.add_component!(sys, gen)

        # Attach wind capacity factor time series
        _attach_wind_time_series!(sys, gen)

    elseif entry.kind == "Diesel"
        # Diesel expansion: ThermalStandard with realistic fuel cost
        # Linear cost curve from the case's candidate heat rate curve
        fuel_price_mbtu = diesel_price * (1.0 / case_fuel_hhv_mbtu_per_gal())
        hr_curve = case_candidate_heat_rate_curve(capacity_mw)

        gen = PSY.ThermalStandard(;
            name = tech_name,
            available = true,
            status = PSY.OperationalStates.ONLINE,  # Allow diesel unit to operate
            bus = bus,
            active_power = 0.0,
            reactive_power = 0.0,
            rating = capacity_pu,
            active_power_limits = (min=0.0, max=capacity_pu),
            reactive_power_limits = (min=0.0, max=0.0),
            ramp_limits = (up=capacity_pu, down=capacity_pu),
            time_limits = (up=1, down=1),
            operation_cost = PSY.ThermalGenerationCost(;
                variable_operation_cost = PSY.CostCurve(;
                    value_curve = PSY.InputOutputCurve(diesel_io_curve(hr_curve, fuel_price_mbtu)),
                    power_units = PSY.NaturalUnit(),
                ),
                fixed = 0.0,
                start_up = settings().candidates.diesel_start_up_cost,
                shut_down = settings().candidates.diesel_shut_down_cost,
            ),
            prime_mover_type = PSY.PrimeMovers.IC,
            fuel = PSY.ThermalFuels.DISTILLATE_FUEL_OIL,
            base_power = sys_base_power,
            input_basis = u"CU",
        )
        PSY.add_component!(sys, gen)

    elseif entry.kind == "Battery"
        add_battery_to_system!(sys, bus_name, capacity_mw, entry.energy_mwh / entry.power_mw; battery_name=tech_name)
    else
        error("Unsupported technology kind $(entry.kind) for $tech_name")
    end
end

"""
    _add_load_arrivals_to_system!(sys, arrivals)

Add load arrivals to the system as new PowerLoad components.

Arguments:
  sys: PowerSystems.System to modify
  arrivals: Vector of LoadArrival objects (has year, mw, conforming, bus)

For each arrival, creates a PowerLoad with fixed active_power and max_active_power
connected to the specified bus. No time series is attached since load arrivals
represent constant new loads (unlike base system loads with hourly profiles).
"""
function _add_load_arrivals_to_system!(sys::PSY.System, arrivals::Vector, timestamps::Vector{DateTime})
    if isempty(arrivals)
        return
    end

    for (i, arrival) in enumerate(arrivals)
        # LoadArrival.mw is in natural units (MW)
        arrival_mw = arrival.mw
        bus_name = arrival.bus
        bus = PSY.get_component(PSY.ACBus, sys, bus_name)

        if isnothing(bus)
            @warn "Bus $bus_name not found for load arrival; skipping"
            continue
        end

        # Create load name (use formatted float for non-integer MW values)
        mw_str = isequal(arrival_mw, floor(arrival_mw)) ? "$(Int(floor(arrival_mw)))" : "$(round(arrival_mw, digits=2))"
        load_name = "Arrival_$(i)_$(mw_str)MW_$(bus_name)"

        # Create PowerLoad component with base_power=1.0 so values are in MW (like base system loads)
        load = PSY.PowerLoad(;
            name = load_name,
            available = true,
            bus = bus,
            active_power = arrival_mw,  # MW directly
            reactive_power = 0.0,
            max_active_power = arrival_mw,  # MW directly
            max_reactive_power = 0.0,
            base_power = 1.0,  # 1 MW base so values are in MW not per-unit
            input_basis = u"CU",
        )

        PSY.add_component!(sys, load)

        # Determine load profile: use custom profile if available, otherwise flat
        if !isnothing(arrival.custom_profile_path) && isfile(arrival.custom_profile_path)
            # Load custom profile from CSV
            try
                profile_data = CSV.read(arrival.custom_profile_path, DataFrame; header=false)
                # Convert to Float64 to ensure compatibility with PowerSimulations (expects Float64, not Int64)
                custom_profile = vec(Float64.(Matrix(profile_data)))

                # Validate profile length matches simulation period
                if length(custom_profile) != length(timestamps)
                    @warn "Custom profile for $load_name has $(length(custom_profile)) hours but simulation has $(length(timestamps)) hours. Cycling profile to match."
                    # Cycle the profile if needed
                    cycles_needed = ceil(Int, length(timestamps) / length(custom_profile))
                    custom_profile = repeat(custom_profile, cycles_needed)[1:length(timestamps)]
                end

                ta = TimeSeries.TimeArray(timestamps, custom_profile)
                ts = PSY.SingleTimeSeries("max_active_power", ta)
                PSY.add_time_series!(sys, load, ts)
                @info "Added load arrival: $load_name ($(arrival.mw) MW with custom profile from $(arrival.custom_profile_path), bus=$bus_name)"
            catch e
                @warn "Could not load custom profile from $(arrival.custom_profile_path): $e. Using flat profile instead."
                flat_profile = fill(1.0, length(timestamps))
                ta = TimeSeries.TimeArray(timestamps, flat_profile)
                ts = PSY.SingleTimeSeries("max_active_power", ta)
                PSY.add_time_series!(sys, load, ts)
                @info "Added load arrival: $load_name ($(arrival.mw) MW flat, bus=$bus_name)"
            end
        else
            # Add flat time series (constant normalized profile [0,1], scaled by max_active_power)
            # Use 1.0 for every hour (100% of max_active_power) to represent constant load
            flat_profile = fill(1.0, length(timestamps))
            ta = TimeSeries.TimeArray(timestamps, flat_profile)
            ts = PSY.SingleTimeSeries("max_active_power", ta)
            PSY.add_time_series!(sys, load, ts)
            @info "Added load arrival: $load_name ($(arrival.mw) MW constant, bus=$bus_name)"
        end
    end
end

"""
    run_postoptimal_pcm(
        investment_results::Dict{String, Float64};
        scenario::Symbol = :moderate,
        results_dir::String = "results/pcm",
        mip_gap::Float64 = 0.005,
        copper_plate::Bool = false,
        arrivals::Vector{<:Any} = [],
    ) -> Dict{String, Any}

Run a full annual production cost simulation on the post-investment system.

Arguments:
  investment_results: Dict mapping technology name → MW built (from CEM _extract_investment_results)
  scenario: Symbol for load profile scenario (:base, :moderate, :high)
  results_dir: Directory where simulation results will be written
  mip_gap: MILP optimality gap for solver
  copper_plate: Use CopperPlate model (fast) instead of NFANetworkModel (default: false)
  arrivals: Optional vector of LoadArrival objects to add as new loads (for validation)

Returns:
  Dict with keys:
    - "system": the expanded PSY.System used for the simulation
    - "simulation": the completed PSI.Simulation object
    - "scenario": the scenario symbol
    - "results_dir": the results directory path
"""
function run_postoptimal_pcm(
    investment_results::Dict{String, Float64};
    scenario::Symbol = :moderate,
    results_dir::String = "results/pcm",
    mip_gap::Float64 = 0.005,
    copper_plate::Bool = false,
    arrivals::Vector{<:Any} = [],
    diesel_price::Float64 = case_default_diesel_price(),
    day_start::Int = 1,
    day_end::Int = 365,
)
    # Build expanded system with new generators and load arrivals
    # (base system already has 13-year time series attached from build_case_system)
    sys = build_post_investment_system(investment_results; arrivals=arrivals, diesel_price=diesel_price)

    # Debug: verify load arrivals are in the system
    all_loads = collect(PSY.get_components(PSY.PowerLoad, sys))
    arrival_loads = [l for l in all_loads if startswith(PSY.get_name(l), "Arrival_")]
    @info "System verification after build_post_investment_system:"
    @info "  Total PowerLoad components: $(length(all_loads))"
    @info "  Load arrivals: $(length(arrival_loads))"
    for load in arrival_loads
        @info "    - $(PSY.get_name(load)) ($(PSY.get_active_power(load, u"MW")) MW)"
    end

    # Check time series format of existing loads vs new arrivals
    if !isempty(all_loads)
        existing_load = first(all_loads)
        if !startswith(PSY.get_name(existing_load), "Arrival_")
            try
                ts_existing = PSY.get_time_series(PSY.SingleTimeSeries, existing_load, "max_active_power")
                @info "Existing load time series type: $(typeof(ts_existing))"
            catch e
                @info "Could not read existing load time series: $e"
            end
        end
    end
    if !isempty(arrival_loads)
        arrival_load = first(arrival_loads)
        try
            ts_arrival = PSY.get_time_series(PSY.SingleTimeSeries, arrival_load, "max_active_power")
            @info "Arrival load time series type: $(typeof(ts_arrival))"
        catch e
            @info "Could not read arrival load time series: $e"
        end
    end

    # Build and run the simulation
    sim_folder = joinpath(results_dir, "sim_$(scenario)")
    mkpath(sim_folder)

    horizon_year = maximum(a.year for a in arrivals; init=settings().base_year)
    sim = build_pcm_simulation(
        sys;
        results_dir = dirname(sim_folder),
        sim_name = basename(sim_folder),
        mip_gap = mip_gap,
        copper_plate = copper_plate,
        day_start = day_start,
        day_end = day_end,
        sim_year = horizon_year,
    )

    @info "Running post-optimal PCM simulation ($scenario scenario, $(length(investment_results)) investments)..."
    run_simulation!(sim)

    # Debug: check if loads are preserved in simulation
    try
        sim_results = PSI.SimulationResults(sim)
        uc_results = PSI.get_decision_problem_results(sim_results, "UC")
        sys_from_sim = PSI.get_system(uc_results)
        all_loads_in_sim = collect(PSY.get_components(PSY.PowerLoad, sys_from_sim))
        arrival_loads_in_sim = filter(l -> startswith(PSY.get_name(l), "Arrival_"), all_loads_in_sim)
        @info "System verification after simulation:"
        @info "  Total PowerLoad components in sim system: $(length(all_loads_in_sim))"
        @info "  Load arrivals in sim system: $(length(arrival_loads_in_sim))"
    catch e
        @warn "Could not verify loads in simulation system: $e"
    end

    # Return the expanded system (with investments) that was actually used in simulation
    # along with the simulation results
    return Dict(
        "system" => sys,
        "simulation" => sim,
        "scenario" => scenario,
        "results_dir" => sim_folder,
    )
end

# Per-unit totals from a realized PCM variable (long DateTime/name/value or wide format)
function _sum_by_unit(df::DataFrame, f = identity)
    if hasproperty(df, :name) && hasproperty(df, :value)
        return Dict(String(k.name) => sum(f, g.value) for (k, g) in pairs(groupby(df, :name)))
    end
    return Dict(String(c) => sum(f, skipmissing(df[!, c])) for c in DataFrames.names(df) if eltype(df[!, c]) <: Number)
end

_n_hours(df::DataFrame) = hasproperty(df, :DateTime) ? length(unique(df.DateTime)) : nrow(df)

"""
    report_tier2_fuel_pcm(uc_results)

Print diesel fuel (all thermal units) and committed hours of Tier 2 units from PCM dispatch, with
annualized totals against the case limits. The PCM reports these limits; it does not constrain them.
"""
function report_tier2_fuel_pcm(uc_results)
    diesel_p = PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.ThermalStandard)
    isempty(diesel_p) && return
    hours = _n_hours(diesel_p)
    annual_scale = 8760.0 / hours
    energy = _sum_by_unit(diesel_p)

    println("\nDiesel Fuel (all thermal units, PCM dispatch):")
    println("  Limit: $(Int(settings().tier2_fuel_limit_gal)) gal/yr (PCM reports only; not constrained)")
    total_gal = 0.0
    for unit in sort(collect(keys(energy)))
        mwh = energy[unit]
        mwh <= 0 && continue
        hr = something(case_rated_heat_rate(unit), settings().default_heat_rate)
        gal = mwh * hr / case_fuel_hhv_mbtu_per_gal() * annual_scale
        total_gal += gal
        println("  $(rpad(unit, 30)) $(round(mwh, digits=0)) MWh simulated, $(round(gal, digits=0)) gal/yr annualized")
    end
    limit = settings().tier2_fuel_limit_gal
    status = total_gal > limit ? "EXCEEDS limit by $(round(total_gal - limit, digits=0)) gal/yr" : "within limit"
    println("  Total: $(round(total_gal, digits=0)) gal/yr ($status)")

    on = try
        PSI.read_realized_variable(uc_results, PSI.OnVariable, PSY.ThermalStandard)
    catch
        nothing
    end
    isnothing(on) && return
    on_hours = _sum_by_unit(on, x -> x > 0.5 ? 1.0 : 0.0)
    limit_h = settings().tier2_hours_per_yr
    println("\nTier 2 Unit Operation (committed hours, PCM; limit $(Int(limit_h)) h/yr per unit, not constrained):")
    println("  Simulated $(hours) h; limit pro-rated to the simulated period: $(round(limit_h / annual_scale, digits=1)) h")
    for unit in sort(collect(keys(on_hours)))
        unit_tier(unit) == 2 || continue
        h = on_hours[unit]
        status = h > limit_h / annual_scale + 1e-6 ? "OVER" : "ok"
        println("  $(rpad(unit, 30)) $(round(Int, h)) h simulated, $(round(Int, h * annual_scale)) h/yr annualized ($status)")
    end
end

"""
    report_pcm_results(pcm_results::Dict)

Print PCM simulation results summary with annual energy demand and generation by resource.
"""
function report_pcm_results(pcm_results::Dict)
    sim = get(pcm_results, "simulation", nothing)
    scenario = get(pcm_results, "scenario", :moderate)
    results_dir = get(pcm_results, "results_dir", "")
    sys = get(pcm_results, "system", nothing)

    if isnothing(sim) || isnothing(sys)
        @warn "Cannot report PCM results: missing simulation or system"
        return
    end

    println("\n" * "="^70)
    println("PCM Simulation Results ($scenario scenario)")
    println("="^70 * "\n")

    # System configuration (based on actual system data, not parameters)
    println("System Configuration:")

    # Total generation capacity from all generators
    total_gen_capacity_mw = sum(PSY.get_max_active_power(g, u"MW") for g in PSY.get_components(PSY.Generator, sys))
    println("  Total system generation capacity: $(round(total_gen_capacity_mw, digits=1)) MW")

    # Calculate peak load and annual demand from actual simulation time series

    # Get simulation results
    sim_results = PSI.SimulationResults(sim)
    uc_results = PSI.get_decision_problem_results(sim_results, "UC")
    report_tier2_fuel_pcm(uc_results)

    # Read actual load time series from results - must be available
    demand_data = PSI.read_realized_parameter(uc_results, "ActivePowerTimeSeriesParameter__PowerLoad")
    peak_load_mw = minimum(combine(groupby(demand_data, :DateTime), :value=>sum).value_sum) * -1.0
    annual_load_mwh = sum(demand_data.value) * -1.0  # Sum of negative values (loads are negative in PowerSystems)
    println("  System peak load: $(round(peak_load_mw, digits=2)) MW")
    println("  Simulation energy demand ($(length(unique(demand_data.DateTime)))) hours): $(round(annual_load_mwh, digits=0)) MWh")

    # Extract actual generation by resource from simulation results using PowerAnalytics
    println("\nGeneration Summary:")

    # Get decision problem results from simulation
    sim_results = PSI.SimulationResults(sim)
    uc_results = PSI.get_decision_problem_results(sim_results, "UC")

    # Calculate generation by component type using PowerAnalytics
    generation_by_type = Dict{String, Float64}(
        "Hydro" => 0.0,
        "Wind" => 0.0,
        "Solar" => 0.0,
        "Diesel" => 0.0,
    )

    # Get thermal generation (diesel)
    try
        thermal_selector = PA.make_selector(PSY.ThermalStandard)
        thermal_gen = PA.calc_active_power(thermal_selector, uc_results)
        if !isempty(thermal_gen)
            # Sum only numeric columns (skip timestamp/index columns)
            for col in eachcol(thermal_gen)
                if eltype(col) <: Number
                    generation_by_type["Diesel"] += sum(col)  # hourly MW summed = MWh
                end
            end
        end
    catch e
        @debug "No thermal generation data found: $e"
    end

    # Get renewable generation (wind + solar)
    try
        renewable_selector = PA.make_selector(PSY.RenewableDispatch)
        renewable_gen = PA.calc_active_power(renewable_selector, uc_results)
        if !isempty(renewable_gen)
            # Separate wind and solar by name
            for name in names(renewable_gen)
                col = renewable_gen[!, name]
                # Only sum numeric columns
                if eltype(col) <: Number
                    annual_mwh = sum(col)  # hourly MW summed = MWh
                    name_str = String(name)
                    component = PSY.get_component(PSY.RenewableDispatch, sys, name_str)
                    prime_mover = isnothing(component) ? nothing : PSY.get_prime_mover_type(component)
                    if prime_mover == PSY.PrimeMovers.WT || (isnothing(prime_mover) && occursin("Wind", name_str))
                        generation_by_type["Wind"] += annual_mwh
                    elseif prime_mover == PSY.PrimeMovers.PVe || (isnothing(prime_mover) && occursin("Solar", name_str))
                        generation_by_type["Solar"] += annual_mwh
                    end
                end
            end
        end
    catch e
        @debug "No renewable generation data found with RenewableDispatch: $e"
    end

    # Get hydro generation (HydroTurbine or HydroDispatch if still present)
    try
        hydro_selector = PA.make_selector(PSY.HydroTurbine)
        hydro_gen = PA.calc_active_power(hydro_selector, uc_results)
        if !isempty(hydro_gen)
            # Sum only numeric columns (skip timestamp/index columns)
            for col in eachcol(hydro_gen)
                if eltype(col) <: Number
                    generation_by_type["Hydro"] += sum(col)  # hourly MW summed = MWh
                end
            end
        end
    catch e
        @debug "No HydroTurbine generation data found: $e"
        # Fallback: try HydroDispatch if HydroTurbine not available
        try
            hydro_selector = PA.make_selector(PSY.HydroDispatch)
            hydro_gen = PA.calc_active_power(hydro_selector, uc_results)
            if !isempty(hydro_gen)
                for col in eachcol(hydro_gen)
                    if eltype(col) <: Number
                        generation_by_type["Hydro"] += sum(col)
                    end
                end
            end
        catch
            @debug "No hydro generation data found (HydroDispatch)"
        end
    end

    # Print generation summary
    total_gen = sum(values(generation_by_type))
    println("  Total simulation generation: $(round(total_gen, digits=0)) MWh")
    println("\n  Generation by resource:")
    for resource in ["Hydro", "Wind", "Solar", "Diesel"]
        gen_mwh = generation_by_type[resource]
        if gen_mwh > 0.1
            pct = gen_mwh / total_gen * 100
            println("    • $resource: $(round(gen_mwh, digits=0)) MWh ($(round(pct, digits=1))%)")
        end
    end

    # Transformer overload analysis
    try
        # Load transformer flow data from results
        transformer_flows = try
            PSI.read_realized_variable(uc_results, PSI.FlowActivePowerVariable, PSY.TwoWindingTransformer)
        catch e
            @debug "Could not read transformer flows: $e"
            nothing
        end

        if !isnothing(transformer_flows) && !isempty(transformer_flows)
            @info "Analyzing transformer overloads..."

            # Build rating lookup from system components
            transformers = get_components(PSY.TwoWindingTransformer, sys)
            ratings_dict = Dict(PSY.get_name(x) => transformer_rating_mw(x) for x in transformers)

            # transformer_flows is a long-format DataFrame with columns: DateTime, name, value
            # Group by transformer name and calculate statistics
            overloads = []
            unique_names = unique(transformer_flows.name)

            for xfmr_name in unique_names
                if !haskey(ratings_dict, xfmr_name)
                    continue  # Skip if transformer not in system
                end

                xfmr_rating_mw = ratings_dict[xfmr_name]
                flows_for_xfmr = transformer_flows[transformer_flows.name .== xfmr_name, :value]

                if !isempty(flows_for_xfmr)
                    abs_flows = abs.(flows_for_xfmr)
                    max_flow_mw = maximum(abs_flows)
                    overload_pct = (max_flow_mw / xfmr_rating_mw - 1.0) * 100.0

                    # Count hours with overload (absolute value exceeds rating)
                    overload_hours = count(>(xfmr_rating_mw), abs_flows)
                    total_hours = length(abs_flows)

                    if overload_pct > 0.1  # More than 0.1% over rating
                        avg_overload_pct = if overload_hours > 0
                            overload_flows = abs_flows[abs_flows .> xfmr_rating_mw]
                            mean((overload_flows ./ xfmr_rating_mw .- 1.0) .* 100.0)
                        else
                            0.0
                        end

                        push!(overloads, Dict(
                            :name => xfmr_name,
                            :rating_mw => xfmr_rating_mw,
                            :max_flow_mw => max_flow_mw,
                            :overload_pct => overload_pct,
                            :overload_hours => overload_hours,
                            :total_hours => total_hours,
                            :avg_overload_pct => avg_overload_pct,
                        ))
                    end
                end
            end

            # Print report if overloads found
            sort!(overloads; by=x -> x[:overload_pct], rev=true)

            sep = "=" ^ 80
            println("\n$sep")
            println("  TRANSFORMER OVERLOAD ANALYSIS")
            println(sep)

            if !isempty(overloads)
                println("\n  SUMMARY")
                println("  " * "-"^76)
                @printf "  Transformers analyzed:  %d\n" length(ratings_dict)
                @printf "  Transformers overloaded: %d (%.1f%%)\n" length(overloads) (100.0 * length(overloads) / length(ratings_dict))

                println("\n  OVERLOADED TRANSFORMERS (ranked by severity)")
                println("  " * "-"^76)
                @printf "  %-40s %8s  %8s  %10s  %8s\n" "Transformer" "Rating" "Max Flow" "Overload" "Hours"
                @printf "  %-40s %8s  %8s  %10s  %8s\n" "" "(MW)" "(MW)" "Over" "Violated"
                println("  " * "-"^76)

                for overload in overloads
                    @printf "  %-40s %8.2f  %8.2f  %9.1f%%  %8d\n" overload[:name] overload[:rating_mw] overload[:max_flow_mw] overload[:overload_pct] overload[:overload_hours]
                    if overload[:overload_hours] > 0
                        @printf "    └─ Average overload when violated: %.1f%% (%.2f MW avg)\n" overload[:avg_overload_pct] overload[:rating_mw] * (1.0 + overload[:avg_overload_pct]/100.0)
                    end
                end

                println("\n  INTERPRETATION")
                println("  " * "-"^76)
                critical = count(x -> x[:overload_pct] > 20, overloads)
                moderate = count(x -> 5 < x[:overload_pct] <= 20, overloads)
                minor = count(x -> 0.1 < x[:overload_pct] <= 5, overloads)

                if critical > 0
                    @printf "  🔴 CRITICAL: %d transformer(s) overloaded >20%%\n" critical
                end
                if moderate > 0
                    @printf "  🟡 MODERATE: %d transformer(s) overloaded 5–20%%\n" moderate
                end
                if minor > 0
                    @printf "  🟢 MINOR:    %d transformer(s) overloaded 0.1–5%%\n" minor
                end

                if critical > 0
                    println("\n  ⚠️  Action Required:")
                    println("      • Upgrade overloaded transformers, or")
                    println("      • Implement demand management / load shifting, or")
                    println("      • Add generation capacity on constrained feeders")
                end
            else
                println("\n  ✓ No transformer overloads detected")
                @printf "  All %d transformers operating within ratings\n" length(ratings_dict)
            end

            println("\n$sep\n")
        else
            @debug "No transformer flow data available for analysis"
        end
    catch e
        @warn "Transformer overload analysis error: $e"
        Base.showerror(stderr, e, catch_backtrace())
    end

    # Operating reliability metrics
    println("\nOperating Reliability Metrics:")

    # Unserved energy (load shedding) - requires loss of load variable in model
    try
        # Try to read loss of load variable if it exists
        loss_of_load = try
            PSI.read_realized_variable(uc_results, PSI.SystemBalanceSlackUp, PSY.System)
        catch
            nothing
        end

        if !isnothing(loss_of_load)
            # If we have load data, compare to actual demand to calculate shortfall
            total_unserved_mwh = sum(loss_of_load.value)
            if total_unserved_mwh > 0.01
                println("  ⚠️  Total unserved energy: $(round(total_unserved_mwh, digits=2)) MWh (load shedding)")
            else
                println("  ✓ Total unserved energy: 0.00 MWh (all load met)")
            end
        else
            println("  • Total unserved energy: [no loss-of-load variable - check simulation config]")
        end
    catch e
        @debug "Could not analyze unserved energy: $e"
        println("  • Total unserved energy: [data not available]")
    end

    # Unserved reserve - use ReserveRequirementSlack if available
    try
        reserve_slack = read_reserve_slack(uc_results, case_operating_reserve_name())
        total_unserved_reserve_mwh = if !isempty(reserve_slack) && size(reserve_slack, 1) > 0
            sum(col -> eltype(col) <: Number ? sum(skipmissing(col)) : 0.0, eachcol(reserve_slack))
        else
            0.0
        end
        if total_unserved_reserve_mwh > 0.01
            println("  ⚠️  Total unserved reserve: $(round(total_unserved_reserve_mwh, digits=2)) MWh (reserve shortfall)")
        else
            println("  ✓ Total unserved reserve: 0.00 MWh (reserve requirement met)")
        end
    catch e
        @debug "Could not read reserve slack: $e"
        println("  • Total unserved reserve: [data not available]")
    end

    # Diesel generator runtime hours
    try
        thermal_commitment = PSI.read_realized_variable(uc_results, PSI.OnVariable, PSY.ThermalStandard)
        if !isempty(thermal_commitment) && size(thermal_commitment, 1) > 0
            println("\n  Diesel Generator Runtime (hours):")

            # Calculate total commitment hours for each generator
            diesel_hours = Dict{String, Int}()
            for gen_name in unique(thermal_commitment.name)
                rows = thermal_commitment.name .== gen_name
                values = thermal_commitment.value[rows]
                hours = count(x -> !ismissing(x) && x > 0.5, values)
                diesel_hours[String(gen_name)] = hours
            end

            # Sort by runtime descending
            sorted_hours = sort(collect(diesel_hours), by=x -> x[2], rev=true)

            if !isempty(sorted_hours)
                for (gen_name, hours) in sorted_hours
                    if hours > 0
                        @printf "    • %-40s: %4d hours\n" gen_name hours
                    end
                end
            else
                println("    [No diesel generators with commitment data]")
            end
        else
            println("\n  Diesel Generator Runtime (hours): [no data available]")
        end
    catch e
        @debug "Could not read diesel commitment data: $e"
        println("  • Diesel runtime: [data not available]")
    end

    # Results location
    println("\nSimulation Results:")
    println("  Output directory: $results_dir")
    if !isempty(results_dir) && isdir(results_dir)
        try
            result_files = readdir(results_dir, join=true)
            if !isempty(result_files)
                println("  Result files: $(length(filter(f -> !isdir(f), result_files))) files")
            end
        catch
        end
    end

    println("\n" * "="^70 * "\n")
end

"""
    extract_battery_cost_data(battery_sizes::Vector{Float64}, battery_results::Dict, results_no_battery::Dict)

Extract battery size vs cost data from simulation results.

Returns tuple: (battery_mws::Vector{Float64}, costs::Vector{Float64})
"""
function extract_battery_cost_data(
    battery_sizes::Vector{Float64},
    battery_results::Dict,
    results_no_battery::Dict,
)
    battery_mws = Float64[]
    costs = Float64[]

    # Helper to extract results directory from various data structures
    function get_results_dir(results_dict::Dict)
        if haskey(results_dict, "results_dir")
            return results_dict["results_dir"]
        elseif haskey(results_dict, :results_dir)
            return results_dict[:results_dir]
        else
            return nothing
        end
    end

    # Add baseline (no battery) cost
    try
        results_dir = get_results_dir(results_no_battery)
        if !isnothing(results_dir)
            sim_results = PSI.SimulationResults(results_dir)
            uc_results = PSI.get_decision_problem_results(sim_results, "UC")
            stats = PSI.read_optimizer_stats(uc_results)
            baseline_cost = sum(stats.objective_value)
            push!(battery_mws, 0.0)
            push!(costs, baseline_cost)
        end
    catch e
        @debug "Could not extract baseline cost: $e"
    end

    # Extract costs for each battery configuration
    for battery_mw in battery_sizes
        if haskey(battery_results, battery_mw)
            try
                results_dir = get_results_dir(battery_results[battery_mw])
                if !isnothing(results_dir)
                    sim_results = PSI.SimulationResults(results_dir)
                    uc_results = PSI.get_decision_problem_results(sim_results, "UC")
                    stats = PSI.read_optimizer_stats(uc_results)
                    cost = sum(stats.objective_value)
                    push!(battery_mws, battery_mw)
                    push!(costs, cost)
                end
            catch e
                @debug "Could not extract cost for battery $(battery_mw) MW: $e"
            end
        end
    end

    return (battery_mws, costs)
end

"""
    build_battery_sensitivity_plot(traces::Vector; title::String="Annual Operating Cost vs Battery Size", output_dir::String="results/plots", output_file::String="battery_cost_relationship.html")

Build and save a plot with multiple battery cost sensitivity traces.

Arguments:
  traces: Vector of Plotly trace Dicts (e.g. `Dict("type" => "scatter", "x" => ..., "y" => ...)`)
  title: Plot title
  output_dir: Directory where plot will be saved
  output_file: Filename for the HTML output

Returns the plot object and output path.
"""
function build_battery_sensitivity_plot(
    traces::Vector;
    title::String = "Annual Operating Cost vs Battery Size",
    output_dir::String = "results/plots",
    output_file::String = "battery_cost_relationship.html",
)
    if isempty(traces)
        @warn "No traces provided for plot"
        return nothing, ""
    end

    mkpath(output_dir)

    try
        layout = Dict{String, Any}(
            "title" => title,
            "xaxis" => Dict("title" => "Battery Capacity (MW)"),
            "yaxis" => Dict("title" => "Annual Operating Cost (\$)"),
            "height" => 500,
            "width" => 900,
            "hovermode" => "closest",
        )

        p = PlotlyLight.Plot(traces, layout)

        # Save plot
        plot_path = joinpath(output_dir, output_file)
        PlotlyLight.save(p, plot_path)
        @info "Battery sensitivity plot saved: $plot_path"

        return p, plot_path
    catch e
        @warn "Error creating plot: $e"
        return nothing, ""
    end
end

"""
    plot_battery_cost_relationship(battery_sizes::Vector{Float64}, battery_results::Dict, results_no_battery::Dict; output_dir::String="results/plots")

Create a plot showing the relationship between battery size and annual operating cost.

Arguments:
  battery_sizes: Vector of battery capacities tested (MW)
  battery_results: Dict mapping battery_mw → PCM results dict
  results_no_battery: PCM results dict for baseline (no battery)
  output_dir: Directory where plot will be saved

Returns tuple: (plot_object, plot_path)
"""
function plot_battery_cost_relationship(
    battery_sizes::Vector{Float64},
    battery_results::Dict,
    results_no_battery::Dict;
    output_dir::String = "results/plots",
)
    battery_mws, costs = extract_battery_cost_data(battery_sizes, battery_results, results_no_battery)

    if isempty(battery_mws)
        @warn "No valid cost data to plot"
        return nothing, ""
    end

    # Create trace
    trace = Dict{String, Any}(
        "type" => "scatter",
        "x" => battery_mws,
        "y" => costs,
        "mode" => "lines+markers",
        "marker" => Dict("size" => 8, "color" => "#1f77b4"),
        "line" => Dict("width" => 2),
        "name" => "Diesel \$5.00/gal",
        "hovertemplate" => "<b>Battery: %{x} MW</b><br>Annual Cost: \$%{y:,.0f}<extra></extra>",
    )

    # Build and save plot
    p, plot_path = build_battery_sensitivity_plot(
        [trace];
        output_dir = output_dir,
        output_file = "battery_cost_relationship.html",
    )

    return p, plot_path
end

"""
    diesel_io_curve(hr_curve, fuel_price_per_mbtu) -> PiecewiseLinearData

Linear input-output cost curve (MW → \$/h) from the rated point of a heat rate curve
[(MW, MBTU/MWh), ...]. The point (0, 0) is prepended so cost is zero at zero output.
"""
function diesel_io_curve(
    hr_curve            :: Vector{Tuple{Float64,Float64}},
    fuel_price_per_mbtu :: Float64,
) :: PSY.PiecewiseLinearData
    rated_mw, rated_hr = hr_curve[end]  # last point is rated output
    marginal_cost_per_mwh = rated_hr * fuel_price_per_mbtu
    return PSY.PiecewiseLinearData([(0.0, 0.0), (rated_mw, rated_mw * marginal_cost_per_mwh)])
end

"""
    add_battery_to_system!(sys::PSY.System, bus_name::String, rating_mw::Float64, duration_hours::Float64; battery_name::String="Battery")

Add a new EnergyReservoirStorage (battery) component to the system at a specified bus.

Arguments:
  sys: PowerSystems.System
  bus_name: Name of the bus to attach to
  rating_mw: Power rating in MW
  duration_hours: Duration of full discharge in hours (used to calculate energy capacity)
  battery_name: Name of the battery (default: "Battery")

Returns:
  The created EnergyReservoirStorage component, or nothing if creation failed
"""
function add_battery_to_system!(sys::PSY.System, bus_name::String, rating_mw::Float64, duration_hours::Float64; battery_name::String="Battery")
    bus = PSY.get_component(PSY.ACBus, sys, bus_name)
    if isnothing(bus)
        @warn "Bus $bus_name not found in system"
        return nothing
    end

    sys_base_power = PSY.get_base_power(sys)
    energy_mwh = rating_mw * duration_hours

    power_pu = rating_mw / sys_base_power
    energy_pu = energy_mwh / sys_base_power

    # Create battery using proper keyword argument constructor
    battery = PSY.EnergyReservoirStorage(
        name = battery_name,
        available = true,
        bus = bus,
        prime_mover_type = PSY.PrimeMovers.BA,
        storage_technology_type = PSY.StorageTech.LIB,
        storage_capacity = energy_pu,
        storage_level_limits = (min = 0.0, max = 1.0),
        initial_storage_capacity_level = 0.5,  # Start at 50% SOC to enable charging
        rating = power_pu,
        active_power = 0.0,
        input_active_power_limits = (min = 0.0, max = power_pu),
        output_active_power_limits = (min = 0.0, max = power_pu),
        efficiency = (in = settings().candidates.battery_efficiency, out = settings().candidates.battery_efficiency),
        reactive_power = 0.0,
        reactive_power_limits = (min = 0.0, max = 0.0),
        base_power = sys_base_power,
        input_basis = u"CU",
    )

    try
        PSY.add_component!(sys, battery)
        @info "Added battery: $battery_name ($rating_mw MW / $(round(energy_mwh; digits=1)) MWh) at $bus_name (initial SOC: 10%)"
        return battery
    catch e
        @warn "Failed to add battery $battery_name: $e"
        return nothing
    end
end

"""
    compare_cem_pcm_costs(cem_results::Dict, pcm_results::Dict) -> Dict

Compare CEM estimated operational cost vs PCM realized cost.

Returns summary metrics: cost delta, percent difference, cost distribution by fuel type.
"""
function compare_cem_pcm_costs(cem_results::Dict, pcm_results::Dict)
    cem_cost = get(cem_results, "objective_value", NaN)
    pcm_folder = pcm_results["results_dir"]

    # Read PCM results from disk
    # (Exact API depends on PowerSimulations version; placeholder below)
    pcm_results_path = joinpath(pcm_folder, "results.h5")
    if !isfile(pcm_results_path)
        @warn "PCM results file not found at $pcm_results_path"
        return Dict("cem_cost" => cem_cost, "pcm_cost" => NaN, "delta" => NaN)
    end

    # TODO: parse PCM cost from HDF5 results (requires IS.read_time_series and cost aggregation)
    pcm_cost = NaN  # placeholder

    delta = pcm_cost - cem_cost
    pct_diff = 100 * delta / cem_cost

    return Dict(
        "cem_cost" => cem_cost,
        "pcm_cost" => pcm_cost,
        "delta" => delta,
        "pct_difference" => pct_diff,
    )
end
