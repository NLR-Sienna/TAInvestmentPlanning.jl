# src/planning.jl
#
# Capacity expansion / system planning optimization.
#
# Uses PowerSystemsInvestmentsPortfolios.jl and PowerSystemsInvestments.jl
# (official Sienna investment packages).

# Slack switches for the CEM (set by the CLI or set_slack_options! before solve_planning)
const _SLACKS = (nodal = Ref(true), energy = Ref(true), reserve = Ref(true))

"""
    set_slack_options!(; nodal, energy, reserve)

Enable or disable the CEM power balance (`nodal`), energy feasibility (`energy`), and reserve
margin (`reserve`) slacks. All are enabled by default.
"""
function set_slack_options!(;
    nodal::Bool = _SLACKS.nodal[],
    energy::Bool = _SLACKS.energy[],
    reserve::Bool = _SLACKS.reserve[],
)
    _SLACKS.nodal[] = nodal
    _SLACKS.energy[] = energy
    _SLACKS.reserve[] = reserve
    # PowerSystemsInvestments reads the balance and energy switches from Main
    Core.eval(Main, :(ENABLE_NODAL_SLACK = $nodal))
    Core.eval(Main, :(ENABLE_ENERGY_SLACK = $energy))
    return (nodal = nodal, energy = energy, reserve = reserve)
end

# ============================================================================
# Multi-period capacity expansion with staged load arrivals
# ============================================================================

# Module-level storage for investment interval data
# (keyed by portfolio object id to avoid persistence across runs)
const _PORTFOLIO_INTERVAL_DATA = Dict{UInt, NamedTuple}()


"""
    load_custom_profile(csv_path::String, profile_length::Int) -> Vector{Float64}

Load a normalized load profile from a CSV file. The CSV should contain hourly values (0-1 scale).
Expects a single column or first column of numeric values. If profile doesn't match profile_length,
it's repeated or truncated cyclically to fill the required length.

Returns a vector of normalized values (0-1) that will be scaled by arrival.mw.
"""
function load_custom_profile(csv_path::String, profile_length::Int)::Vector{Float64}
    if !isfile(csv_path)
        @warn "Custom profile file not found: $csv_path, using flat profile instead"
        return fill(1.0, profile_length)  # Default to flat (peak = 1.0)
    end

    try
        # Read CSV file - handle both single column and multiple columns
        data = readdlm(csv_path, ',', Float64, skipstart=0)

        # Extract first column if matrix, or use as-is if vector
        profile = if ndims(data) == 2
            vec(data[:, 1])
        else
            vec(data)
        end

        # Filter out NaN/Inf values
        profile = filter(x -> !isnan(x) && !isinf(x), profile)

        if isempty(profile)
            @warn "Custom profile is empty after filtering: $csv_path, using flat profile"
            return fill(1.0, profile_length)
        end

        # Normalize to 0-1 range based on maximum value
        profile_max = maximum(profile)
        if profile_max > 0
            profile = profile ./ profile_max
        else
            @warn "Custom profile has max value ≤ 0: $csv_path, using flat profile"
            return fill(1.0, profile_length)
        end

        # Repeat or truncate cyclically to match required length
        if length(profile) == profile_length
            return profile
        elseif length(profile) < profile_length
            # Repeat the profile cyclically
            repeats = div(profile_length, length(profile)) + 1
            extended = repeat(profile, repeats)
            return extended[1:profile_length]
        else
            # Truncate cyclically (should rarely happen)
            return profile[1:profile_length]
        end
    catch e
        @warn "Error loading custom profile from $csv_path: $e, using flat profile"
        return fill(1.0, profile_length)
    end
end

"""
    is_technology_available(tech_name::String, year::Int, procurement_timelines::Dict) -> Bool

Check if a technology is available to be built in the given year based on procurement timelines.
Returns true if year is within [available_from_year, available_until_year] or if tech is not in timelines.
"""
function is_technology_available(tech_name::String, year::Int, procurement_timelines::Dict{String, Tuple{Int, Int}})::Bool
    if !haskey(procurement_timelines, tech_name)
        return true  # No timeline specified, technology is always available
    end
    available_from, available_until = procurement_timelines[tech_name]
    return available_from <= year <= available_until
end

"""
    print_procurement_timeline(procurement_timelines::Dict)

Print a summary of technology procurement timelines to the console.
"""
function print_procurement_timeline(procurement_timelines::Dict{String, Tuple{Int, Int}})
    if isempty(procurement_timelines)
        println("No procurement timelines defined.")
        return
    end

    println("\nProcurement Timeline Configuration")
    println("=" ^ 50)

    # Sort by available_from_year, then by name
    sorted_techs = sort(collect(procurement_timelines), by=x -> (x[2][1], x[1]))

    for (tech_name, (available_from, available_until)) in sorted_techs
        status = available_until >= 9999 ? "indefinite" : "$(available_until)"
        println("  $(tech_name): $(available_from) → $status")
    end
    println("=" ^ 50 * "\n")
end

"""
    merge_procurement_timelines(overrides::Dict{String, Tuple{Int, Int}}) -> Dict{String, Tuple{Int, Int}}

Merge custom procurement timeline overrides with the case default procurement timelines.

This helper allows you to override specific technology timelines while keeping defaults for others.

Arguments:
  - overrides::Dict: technology names → (available_from_year, available_until_year) tuples

Returns:
  - Merged Dict with defaults + overrides

Examples:
```julia
# Override Wind_new_1 to be available 2029-2032
custom = merge_procurement_timelines(Dict(
    "Wind_new_1" => (2029, 2032),
    "Diesel_Expansion_new" => (2028, 2035),  # Moved up to 2028, capped at 2035
))

# Build portfolio with custom timelines
portfolio = build_planning_portfolio(arrivals; procurement_timelines=custom)
```
"""
function merge_procurement_timelines(overrides::Dict{String, Tuple{Int, Int}}) :: Dict{String, Tuple{Int, Int}}
    # Start with defaults and merge in overrides
    merged = default_procurement_timelines()
    for (tech_name, timeline) in overrides
        merged[tech_name] = timeline
    end
    return merged
end

"""
    compute_investment_intervals(arrivals; base_year, horizon_end, base_load_mw)

Derive investment intervals and per-interval peak demand from a load arrival schedule.

Returns:
  - intervals: Vector{NTuple{2, Date}} for DiscountedCashFlow
  - peak_mws: Vector{Float64} — peak demand in each interval
  - rep_years: Vector{Int}  — representative year for time series in each interval
"""
function compute_investment_intervals(
    arrivals::Vector{LoadArrival} = default_arrivals();
    base_year::Int = settings().base_year,
    horizon_end::Int = maximum(a.year for a in arrivals; init=base_year),
    base_load_mw::Float64 = case_base_peak_load_mw(),
)
    # Boundary years: base_year, each arrival year, one past horizon
    boundaries = [base_year; sort([a.year for a in arrivals]); horizon_end + 1]

    intervals  = NTuple{2, Date}[]
    peak_mws   = Float64[]
    rep_years  = Int[]
    cumulative = base_load_mw

    for i in 1:length(boundaries) - 1
        yr_start = boundaries[i]
        yr_end   = boundaries[i+1] - 1
        yr_start > yr_end && continue          # skip zero-width gaps
        push!(intervals, (Date(yr_start, 1, 1), Date(yr_end, 12, 31)))
        push!(peak_mws,  cumulative)
        push!(rep_years, yr_start)
        # Add MW for load that arrives at start of next interval
        next_arrivals = [a.mw for a in arrivals if a.year == boundaries[i+1]]
        cumulative += sum(next_arrivals; init=0.0)
    end

    return intervals, peak_mws, rep_years
end

"""
    build_rep_period_timestamps(rep_year::Int) -> Vector{DateTime}

Generate 12 monthly representative periods (168 hours each) anchored to a given year.
"""
function build_rep_period_timestamps(rep_year::Int)
    all_ts = DateTime[]
    for m in 1:12
        day15 = DateTime(rep_year, m, 15, 0, 0, 0)
        append!(all_ts, collect(day15 : Hour(1) : day15 + Hour(167)))
    end
    return all_ts
end

function _add_transmission_technologies!(port::PSIP.Portfolio, sys::PSY.System, nodes::Dict{String, PSIP.Node}, fin_data::PSIP.TechnologyFinancialData)
    """Add transmission lines and transformers as NodalACTransportTechnology objects."""
    tech_id = 100  # Starting ID for transmission techs

    # Add lines (5 total)
    # Use large capacity limits (1000 MW) to not constrain optimization in planning stage
    # Real transmission constraints would be enforced in more detailed operational models
    MAX_LINE_CAPACITY = 1000.0  # MW

    for line in PSY.get_components(PSY.Line, sys)
        name = PSY.get_name(line)
        arc = PSY.get_arc(line)
        from_bus = PSY.get_name(PSY.get_from(arc))
        to_bus = PSY.get_name(PSY.get_to(arc))

        # Get nodes for this line
        start_node = nodes[from_bus]
        end_node = nodes[to_bus]

        # Create NodalACTransportTechnology (existing lines have zero capital cost)
        line_tech = PSIP.NodalACTransportTechnology{PSY.Line}(;
            name = name,
            start_node = start_node,
            end_node = end_node,
            available = true,
            capacity_limits = (min=-MAX_LINE_CAPACITY, max=MAX_LINE_CAPACITY),
            capital_costs = PSIP.LinearCurve(0.0),  # Existing assets, no investment
            power_systems_type = "Line",
            id = tech_id,
            financial_data = fin_data,
        )
        PSIP.add_technology!(port, line_tech)
        tech_id += 1
    end

    # Add transformers (2 total)
    for tf in PSY.get_components(PSY.Transformer2W, sys)
        name = PSY.get_name(tf)
        arc = PSY.get_arc(tf)
        from_bus = PSY.get_name(PSY.get_from(arc))
        to_bus = PSY.get_name(PSY.get_to(arc))

        # Get nodes for this transformer
        start_node = nodes[from_bus]
        end_node = nodes[to_bus]

        # Create NodalACTransportTechnology for transformer
        tf_tech = PSIP.NodalACTransportTechnology{PSY.Transformer2W}(;
            name = name,
            start_node = start_node,
            end_node = end_node,
            available = true,
            capacity_limits = (min=-MAX_LINE_CAPACITY, max=MAX_LINE_CAPACITY),
            capital_costs = PSIP.LinearCurve(0.0),  # Existing assets, no investment
            power_systems_type = "Transformer2W",
            id = tech_id,
            financial_data = fin_data,
        )
        PSIP.add_technology!(port, tf_tech)
        tech_id += 1
    end
end

"""
    build_planning_portfolio(arrivals; verbose, reserve_margin, diesel_price, procurement_timelines) -> Portfolio

Constructs a Portfolio for capacity expansion optimization with candidate technologies.

Creates multi-period investment intervals based on load arrivals, adds candidate wind/diesel/battery
technologies with capital costs, and attaches representative-period time series.

Arguments:
  - arrivals::Vector{LoadArrival}: load growth events (default: case default arrivals)
  - verbose::Bool: print interval summary (default: true)
  - reserve_margin::Float64: capacity planning margin (default: 0.35)
  - diesel_price::Float64: fuel price in USD/gal (default: 5.00)
  - procurement_timelines::Dict: tech availability by year (default: case default procurement timelines)

Returns:
  - Portfolio object ready for solve_planning()
"""
function build_planning_portfolio(
    arrivals::Vector{LoadArrival} = default_arrivals();
    verbose::Bool = true,
    reserve_margin::Float64 = settings().reserve_margin,
    diesel_price::Float64 = case_default_diesel_price(),
    procurement_timelines::Dict{String, Tuple{Int, Int}} = default_procurement_timelines(),
)
    # Compute investment intervals and per-interval peak demands from load arrivals
    intervals, peak_mws, rep_years = compute_investment_intervals(arrivals)

    # Build the underlying PowerSystems.System
    sys, _ = build_case_system(; diesel_price=diesel_price, verbose=false)
    adjust_planning_system!(sys, rep_years; verbose=verbose)
    for r in settings().planned_retirements
        isnothing(PSY.get_component(PSY.Generator, sys, r.unit)) &&
            @warn "Planned retirement of $(r.unit): no such unit in the system"
    end


    # Create Portfolio with the system and financial parameters
    # Use aggregation, system, base_year, discount_rate, inflation_rate, interest_rate
    port = PSIP.Portfolio(
        PowerSystems.Area,  # aggregation level
        sys,
        settings().base_year,
        settings().discount_rate,             # WACC
        settings().financial.inflation_rate,
        settings().financial.interest_rate,
    )

    # Create 8 nodes (one per bus) for nodal transmission-constrained model
    # Suppress "Node does not exist in validation configuration" warnings from InfrastructureSystems
    bus_names = [PSY.get_name(b) for b in PSY.get_components(PSY.ACBus, sys)]
    nodes = Dict{String, PSIP.Node}()
    with_logger(NullLogger()) do
        for (idx, bus_name) in enumerate(sort(bus_names))
            node = PSIP.Node(name=bus_name, id=idx)
            nodes[bus_name] = node
            PSIP.add_region!(port, node)
        end
    end

    # Create financial data (reused for all technologies)
    fin_data = PSIP.TechnologyFinancialData(;
        capital_recovery_period = settings().financial.capital_recovery_period,
        technology_base_year = settings().base_year,
        debt_fraction = settings().financial.debt_fraction,
        debt_rate = settings().financial.debt_rate,
        return_on_equity = settings().financial.return_on_equity,
        tax_rate = settings().financial.tax_rate,
    )

    # Store investment intervals and per-interval peak demands in module-level cache
    # (PortfolioMetadata is a struct and doesn't support arbitrary fields)
    # Note: NamedTuple constructor requires field names in order, all fields are required
    _PORTFOLIO_INTERVAL_DATA[objectid(port)] = (;
        intervals = intervals,
        peak_mws = peak_mws,
        rep_years = rep_years,
        arrivals = arrivals,
        actual_load_names = String[],  # Will be populated during load creation
        procurement_timelines = procurement_timelines,
    )
    port.metadata.reserve_margin = reserve_margin

    # Operational costs for renewable technologies (zero variable/fixed cost)
    renewable_op_cost = PowerSystems.RenewableGenerationCost(;
        variable = PowerSystems.CostCurve(PSIP.LinearCurve(0.0)),
        fixed = 0.0,
    )

    # Base demand at the case's primary load bus
    demand = PSIP.DemandRequirement{PowerSystems.PowerLoad}(;
        name = settings().base_demand.name,
        power_systems_type = "PowerLoad",
        peak_demand_mw = peak_mws[1],
        value_of_lost_load = settings().unserved_energy_per_mwh,
        id = 1,
        region = [nodes[settings().base_demand.bus]],
    )
    PSIP.add_technology!(port, demand)

    # Add exogenous loads from arrivals schedule, tracking actual load names
    actual_load_names = String[]
    for (i, arrival) in enumerate(arrivals)
        if !haskey(nodes, arrival.bus)
            @warn "Bus $(arrival.bus) not found in system, skipping load arrival $i"
            continue
        end
        node = nodes[arrival.bus]
        load_name = "Load_Arrival_$(arrival.year)_$(i)"
        const_load = PSIP.DemandRequirement{PowerSystems.PowerLoad}(;
            name = load_name,
            power_systems_type = "PowerLoad",
            peak_demand_mw = arrival.mw,
            value_of_lost_load = settings().unserved_energy_per_mwh,
            id = 1 + i,
            region = [node],
        )
        PSIP.add_technology!(port, const_load)
        push!(actual_load_names, load_name)
    end

    # Update the stored interval data with actual load names
    port_id = objectid(port)
    existing_data = _PORTFOLIO_INTERVAL_DATA[port_id]
    _PORTFOLIO_INTERVAL_DATA[port_id] = (;
        intervals = existing_data.intervals,
        peak_mws = existing_data.peak_mws,
        rep_years = existing_data.rep_years,
        arrivals = existing_data.arrivals,
        actual_load_names = actual_load_names,
        procurement_timelines = existing_data.procurement_timelines,
    )

    # Planned additions (forced builds, not optimized)
    for addition in settings().planned_additions
        addition.kind == "wind" || error("Unsupported planned addition kind: $(addition.kind)")
        PSIP.add_technology!(port, PSIP.SupplyTechnology{PowerSystems.RenewableDispatch}(;
            name = addition.name,
            power_systems_type = "RenewableDispatch",
            region = [nodes[addition.bus]],
            available = true,
            capacity_limits = (min=0.0, max=addition.capacity_mw),
            capital_costs = PSIP.LinearCurve(0.0),
            operation_costs = renewable_op_cost,
            unit_size = addition.capacity_mw,
            id = addition.id,
            financial_data = fin_data,
            prime_mover_type = PowerSystems.PrimeMovers.WT,
        ))
    end

    # Candidate wind (binary builds of one turbine each)
    for wind in settings().candidates.wind
        PSIP.add_technology!(port, PSIP.SupplyTechnology{PowerSystems.RenewableDispatch}(;
            name = wind.name,
            power_systems_type = "RenewableDispatch",
            region = [nodes[wind.bus]],
            available = true,
            capacity_limits = (min=0.0, max=wind.capacity_mw),
            capital_costs = PSIP.LinearCurve(wind.capital_cost_total),
            operation_costs = renewable_op_cost,
            unit_size = wind.capacity_mw,
            id = wind.id,
            financial_data = fin_data,
            prime_mover_type = PowerSystems.PrimeMovers.WT,
        ))
    end

    # Add candidate battery storage options (continuous investment, multiple configurations)
    # CEM chooses which to build and how much
    battery_op_cost = PSIP.StorageCost()
    battery_options = settings().candidates.battery
    battery_efficiency = settings().candidates.battery_efficiency
    power_cost_share = settings().candidates.battery_power_cost_share

    battery_id = 10
    for opt in battery_options
        battery = PSIP.StorageTechnology{PowerSystems.EnergyReservoirStorage}(;
            name = "Battery_$(opt.power_mw)MW_$(opt.energy_mwh)MWh",
            power_systems_type = "EnergyReservoirStorage",
            region = [nodes[opt.bus]],
            available = true,
            storage_tech = PowerSystems.StorageTech.LIB,
            prime_mover_type = PowerSystems.PrimeMovers.BA,
            lifetime = settings().candidates.battery_lifetime_years,
            capacity_limits_discharge = (min=0.0, max=opt.power_mw),
            capacity_limits_charge = (min=0.0, max=opt.power_mw),
            capacity_limits_energy = (min=0.0, max=opt.energy_mwh),
            duration_limits = (min=opt.energy_mwh / opt.power_mw, max=opt.energy_mwh / opt.power_mw),
            capital_costs_discharge = PSIP.LinearCurve(opt.capital_cost_total * power_cost_share / opt.power_mw),
            capital_costs_charge = PSIP.LinearCurve(0.0),  # power rating already costed via discharge
            capital_costs_energy = PSIP.LinearCurve(opt.capital_cost_total * (1 - power_cost_share) / opt.energy_mwh),
            efficiency = (in=battery_efficiency, out=battery_efficiency),
            operation_costs = battery_op_cost,
            id = battery_id,
            financial_data = fin_data,
        )
        PSIP.add_technology!(port, battery)
        battery_id += 1
    end

    # Add discrete diesel generator options (binary investment decisions)
    # Each unit is a specific real-world model that can be purchased (binary choice)
    # Capital cost is total cost per unit, not per MW
    diesel_id = 9

    for opt in settings().candidates.diesel
        diesel_op_cost = PowerSystems.ThermalGenerationCost(;
            variable = PowerSystems.CostCurve(PSIP.LinearCurve(settings().candidates.diesel_heat_rate_mbtu_per_mwh * diesel_price / case_fuel_hhv_mbtu_per_gal())),
            fixed = opt.fixed_om_per_h,
            start_up = settings().candidates.diesel_start_up_cost,
            shut_down = settings().candidates.diesel_shut_down_cost,
        )
        unit = PSIP.SupplyTechnology{PowerSystems.ThermalStandard}(;
            name = diesel_candidate_name(opt),
            power_systems_type = "ThermalStandard",
            region = [nodes[opt.bus]],
            available = true,
            capacity_limits = (min=0.0, max=opt.capacity_mw),
            capital_costs = PSIP.LinearCurve(opt.capital_cost_total),
            operation_costs = diesel_op_cost,
            unit_size = opt.capacity_mw,
            id = diesel_id,
            financial_data = fin_data,
            prime_mover_type = PowerSystems.PrimeMovers.IC,
        )
        PSIP.add_technology!(port, unit)
        diesel_id += 1
    end

    # Add transmission technologies (lines and transformers)
    _add_transmission_technologies!(port, sys, nodes, fin_data)

    # Attach capacity factor and load time series for operational dispatch
    # These are required for the dispatch constraints to access realistic values
    _attach_time_series_to_portfolio!(port, intervals, peak_mws, rep_years, procurement_timelines)

    if verbose
        n_techs = length(PSIP.get_technologies(PSIP.Technology, port))
        @info "Portfolio built: $n_techs technologies, $(length(intervals)) investment intervals, final peak=$(peak_mws[end]) MW"
        print_procurement_timeline(procurement_timelines)
    end

    return port
end

function _generate_full_horizon_timestamps(rep_years::Vector{Int})
    """Generate consistent hourly timestamps for entire investment horizon, filling gaps."""
    all_timestamps = DateTime[]
    min_year = first(rep_years)
    max_year = last(rep_years)

    # Generate hourly timestamps for all years from first to last rep_year
    for year in min_year:max_year
        start = DateTime(year, 1, 1, 0, 0, 0)
        # Check for leap year: divisible by 4, except centuries unless divisible by 400
        is_leap = (mod(year, 4) == 0) && (mod(year, 100) != 0 || mod(year, 400) == 0)
        days_in_year = is_leap ? 366 : 365
        hours_in_year = days_in_year * 24
        for hour in 0:(hours_in_year - 1)
            push!(all_timestamps, start + Hour(hour))
        end
    end
    return all_timestamps
end

function _attach_time_series_to_portfolio!(
    port::PSIP.Portfolio,
    intervals::Vector{NTuple{2, Date}},
    peak_mws::Vector{Float64},
    rep_years::Vector{Int},
    procurement_timelines::Dict{String, Tuple{Int, Int}} = default_procurement_timelines(),
)
    # Attach hourly capacity factor time series to renewable and demand technologies.
    # Generates 12 representative periods per investment interval (one per month),
    # each tagged with (year=rep_year, rep_day=month_num) so PSI2 routes them correctly.
    # Technologies are only available in intervals where their procurement timeline allows.

    # Pre-generate full-horizon timestamps for consistency
    full_horizon_timestamps = _generate_full_horizon_timestamps(rep_years)

    # Hourly profiles come from the base system: candidate and planned wind use the reference wind
    # unit's capacity factors, and the base demand is the system's actual load, for the same hours.
    base_system = PSIP.get_base_system(port)
    reference_wind = PSY.get_component(PSY.RenewableDispatch, base_system, settings().pcm.reference_wind_unit)
    isnothing(reference_wind) &&
        @warn "Reference wind unit $(settings().pcm.reference_wind_unit) not found; candidate wind uses a synthetic capacity factor"
    base_loads = collect(PSY.get_components(PSY.PowerLoad, base_system))
    base_load_ratings = PSY.with_units_base(() -> PSY.get_max_active_power.(base_loads), base_system, PSY.UnitSystem.NATURAL_UNITS)
    custom_profiles = Dict{String, Vector{Float64}}()

    for (interval_idx, (interval, peak_mw, rep_year)) in enumerate(zip(intervals, peak_mws, rep_years))
        year_str = string(rep_year)
        # Generate 12 monthly representative periods for this interval
        rep_timestamps = build_rep_period_timestamps(rep_year)

        # Get arrival years to check which loads are active in this interval
        port_id = objectid(port)
        arrivals_in_port = if haskey(_PORTFOLIO_INTERVAL_DATA, port_id)
            _PORTFOLIO_INTERVAL_DATA[port_id].arrivals
        else
            LoadArrival[]
        end

        for month_num in 1:12
            # Extract the 168-h window for this month (15th of the month + 7 days)
            rep_day_stamps = rep_timestamps[(month_num-1)*168+1 : month_num*168]

            # Wind capacity factors for these hours
            wind_cf_hourly = if isnothing(reference_wind)
                [settings().synthetic_wind_capacity_factor * (0.95 + 0.10*rand()) for _ in 1:length(rep_day_stamps)]
            else
                _hourly_profile(reference_wind, rep_day_stamps)
            end

            # Base demand: the system's actual load (MW) in these hours. Load arrivals are separate demands.
            load_profile_hourly = sum(_hourly_profile(load, rep_day_stamps) .* rating
                                      for (load, rating) in zip(base_loads, base_load_ratings))

            # Attach wind to candidate technologies
            # Attach wind CF to all wind turbine expansion options regardless of procurement availability
            # (procurement timeline prevents building but doesn't prevent needing time series data)
            for wind in settings().candidates.wind
                wind_tech = PSIP.get_technology(PSIP.SupplyTechnology{PowerSystems.RenewableDispatch}, port, wind.name)
                !isnothing(wind_tech) && _add_single_time_series!(port, wind_tech, "ops_variable_cap_factor",
                                                                  rep_day_stamps, wind_cf_hourly, month_num, year_str)
            end

            # Planned wind additions use the same capacity factor profile
            for addition in settings().planned_additions
                wind_exo_tech = PSIP.get_technology(PSIP.SupplyTechnology{PowerSystems.RenewableDispatch}, port, addition.name)
                isnothing(wind_exo_tech) && continue
                _add_single_time_series!(port, wind_exo_tech, "ops_variable_cap_factor",
                                        rep_day_stamps, wind_cf_hourly, month_num, year_str)
                # Also attach max_active_power for when the technology is deployed as a RenewableDispatch component
                _add_single_time_series!(port, wind_exo_tech, "max_active_power",
                                        rep_day_stamps, wind_cf_hourly, month_num, year_str)
            end

            # Demand technology
            demand_tech = PSIP.get_technology(PSIP.DemandRequirement{PowerSystems.PowerLoad}, port, settings().base_demand.name)
            if !isnothing(demand_tech)
                _add_single_time_series!(port, demand_tech, "ops_peak_load",
                                        rep_day_stamps, load_profile_hourly, month_num, year_str)
                # Also attach max_active_power for when the load is deployed as a PowerLoad component
                _add_single_time_series!(port, demand_tech, "max_active_power",
                                        rep_day_stamps, load_profile_hourly, month_num, year_str)
            end

            # Arrival-based loads (conforming vs flat)
            # Attach time series only for loads that have arrived by this interval
            for (i, arrival) in enumerate(arrivals_in_port)
                load_name = "Load_Arrival_$(arrival.year)_$(i)"
                load_tech = PSIP.get_technology(PSIP.DemandRequirement{PowerSystems.PowerLoad}, port, load_name)
                if !isnothing(load_tech)
                    scaled_profile = arrival.year <= rep_year ?
                        _arrival_profile(arrival, rep_day_stamps, load_profile_hourly, custom_profiles) :
                        zeros(length(rep_day_stamps))  # not arrived yet
                    _add_single_time_series!(port, load_tech, "ops_peak_load",
                                           rep_day_stamps, scaled_profile, month_num, year_str)
                    # Also attach max_active_power for when the load is deployed as a PowerLoad component
                    _add_single_time_series!(port, load_tech, "max_active_power",
                                           rep_day_stamps, scaled_profile, month_num, year_str)
                end
            end
        end
    end

    # Planned additions: full-horizon capacity factor. Their builds are fixed in solve_planning
    # (_planned_addition_builds) rather than through a planned_addition time series.
    min_year = first(rep_years)
    max_year = last(rep_years)
    for addition in settings().planned_additions
        exo_wind = PSIP.get_technology(PSIP.SupplyTechnology{PowerSystems.RenewableDispatch}, port, addition.name)
        isnothing(exo_wind) && continue

        # Full-horizon capacity factor (skipped if the representative-period loop already added it)
        try
            wind_cf_full_horizon = Float64[]
            for year in min_year:max_year
                hours_in_year = (Dates.isleapyear(year) ? 366 : 365) * 24
                append!(wind_cf_full_horizon, fill(settings().synthetic_wind_capacity_factor, hours_in_year))
            end
            ta_cf = TimeSeries.TimeArray(full_horizon_timestamps, wind_cf_full_horizon)
            PSIP.add_time_series!(port, exo_wind, PowerSystems.SingleTimeSeries("ops_variable_cap_factor", ta_cf))
        catch e
            contains(string(e), "duplicate") || rethrow(e)
        end
    end
end

# Hourly MW of a load arrival for the given hours. Conforming arrivals follow the base load shape
# (base_load_mw for the same hours) scaled so the base peak maps to the arrival MW; non-conforming
# arrivals use their custom normalized profile by hour of the year, or are flat.
function _arrival_profile(arrival, timestamps, base_load_mw, custom_profiles::Dict{String, Vector{Float64}})
    arrival.conforming && return base_load_mw .* (arrival.mw / case_base_peak_load_mw())
    if !isnothing(arrival.custom_profile_path) && !isempty(arrival.custom_profile_path)
        profile = get!(() -> load_custom_profile(arrival.custom_profile_path, 8760), custom_profiles, arrival.custom_profile_path)
        return [profile[mod1((Dates.dayofyear(ts) - 1) * 24 + Dates.hour(ts) + 1, length(profile))] for ts in timestamps] .* arrival.mw
    end
    return fill(Float64(arrival.mw), length(timestamps))
end

# System load (MW) of the base-system loads for the given consecutive hours
function _base_load_mw(sys::PSY.System, timestamps)
    loads = collect(PSY.get_components(PSY.PowerLoad, sys))
    ratings = PSY.with_units_base(() -> PSY.get_max_active_power.(loads), sys, PSY.UnitSystem.NATURAL_UNITS)
    return sum(_hourly_profile(load, timestamps) .* rating for (load, rating) in zip(loads, ratings))
end

"""
    _net_load_capacity_credits(portfolio, year) -> Dict{String, Float64}

Capacity credits of wind and solar resources from their mean capacity factor over the
`[capacity_credit] top_hours` hours of highest net load in `year`: system load plus the load
arrivals present that year, minus the output of the existing wind and solar units still in
service. Existing units use their own profiles; candidate and planned wind use the reference wind
unit's profile.
"""
function _net_load_capacity_credits(portfolio::PSIP.Portfolio, year::Int)
    sys = PSIP.get_base_system(portfolio)
    stamps = collect(DateTime(year, 1, 1) : Hour(1) : DateTime(year, 12, 31, 23))
    base_load = _base_load_mw(sys, stamps)
    load = copy(base_load)
    custom_profiles = Dict{String, Vector{Float64}}()
    for arrival in _PORTFOLIO_INTERVAL_DATA[objectid(portfolio)].arrivals
        arrival.year <= year && (load .+= _arrival_profile(arrival, stamps, base_load, custom_profiles))
    end

    vre = [g for g in PSY.get_components(PSY.RenewableDispatch, sys)
           if PSY.get_prime_mover_type(g) in (PSY.PrimeMovers.WT, PSY.PrimeMovers.PVe)]
    profiles = Dict(PSY.get_name(g) => _hourly_profile(g, stamps) for g in vre)
    in_service = PSY.with_units_base(sys, PSY.UnitSystem.NATURAL_UNITS) do
        Dict(PSY.get_name(g) => _in_service_mw(g, year) for g in vre)
    end
    net_load = load .- sum((profiles[n] .* in_service[n] for n in keys(profiles)); init = zeros(length(stamps)))
    top = partialsortperm(net_load, 1:min(settings().capacity_credit.top_hours, length(net_load)); rev = true)

    credits = Dict{String, Float64}(n => mean(p[top]) for (n, p) in profiles)
    reference = get(profiles, settings().pcm.reference_wind_unit, nothing)
    if !isnothing(reference)
        for tech in PSIP.get_technologies(PSIP.SupplyTechnology{PSY.RenewableDispatch}, portfolio)
            PSIP.get_prime_mover_type(tech) == PSY.PrimeMovers.WT && (credits[PSIP.get_name(tech)] = mean(reference[top]))
        end
    end
    @info "Capacity credits from the top $(length(top)) net-load hours of $year (peak net load $(round(net_load[top[1]], digits=1)) MW): " *
          join(["$n=$(round(c, digits=3))" for (n, c) in sort(collect(credits))], ", ")
    return credits
end

# Unscaled max_active_power values of a base-system component for the given consecutive hours
_hourly_profile(component, timestamps) = PSY.get_time_series_values(
    PSY.SingleTimeSeries, component, "max_active_power";
    start_time = first(timestamps), len = length(timestamps), ignore_scaling_factors = true,
)

function _add_single_time_series!(port, tech, ts_name, timestamps, values, rep_day, year_str)
    # Add a single-day time series to a technology with year/rep_day metadata tags
    ta = TimeSeries.TimeArray(timestamps, values)
    ts = PowerSystems.SingleTimeSeries(ts_name, ta)
    PSIP.add_time_series!(port, tech, ts; year=year_str, rep_day=rep_day)
end

function _add_single_time_series_to_device!(system::PSY.System, device::PSY.Component, ts_name::String,
                                           timestamps, values, rep_day, year_str, scaling_fn::Union{Nothing, Function}=nothing)
    # Add a single-day time series to a base_system device
    # If scaling_fn provided, it's used as the multiplier function (e.g., get_max_active_power for capacity factors)
    ta = TimeSeries.TimeArray(timestamps, values)
    if !isnothing(scaling_fn)
        ts = PowerSystems.SingleTimeSeries(ts_name, ta; scaling_factor_multiplier=scaling_fn)
    else
        ts = PowerSystems.SingleTimeSeries(ts_name, ta)
    end
    try
        PSY.add_time_series!(system, device, ts)
    catch e
        if !contains(string(e), "duplicate")
            rethrow(e)
        end
        # Time series already exists, skip
    end
end

"""
    build_planning_template(intervals, rep_years, portfolio; procurement_timelines, verbose) -> InvestmentModelTemplate

Constructs the optimization template with technology models and investment constraints.

Arguments:
  - intervals::Vector{NTuple{2, Date}}: investment periods as (start_date, end_date) tuples
  - rep_years::Vector{Int}: representative year for each interval (actual calendar years, not delays)
  - port::PSIP.Portfolio: portfolio object from build_planning_portfolio()
  - procurement_timelines::Dict: technology availability by (year_from, year_until) for each technology
    - Uses actual calendar years (e.g., 2028, 9999 for indefinite availability)
    - Maps technology name to (start_year, end_year) tuple
  - verbose::Bool: enable debug output (default: false)

Returns:
  - InvestmentModelTemplate object ready for solve_planning()
"""
function build_planning_template(
    intervals::Vector{NTuple{2, Date}},
    rep_years::Vector{Int},
    port::PSIP.Portfolio;
    procurement_timelines::Dict{String, Tuple{Int, Int}} = Dict{String, Tuple{Int, Int}}(),
    day_start::Int = 1,
    day_end::Int = 365,
    copper_plate::Bool = true,
    verbose=false
)
    # Note: procurement_timelines uses actual calendar years (not delay years).
    # Technologies can only be built in years within [year_from, year_until] inclusive.
    # This data is stored in the template for potential future use in investment constraints.

    # Generate 12 representative periods per investment interval (168h each, days 15-21)
    # Each interval's periods are tagged with that interval's representative year
    rep_periods_all = Vector{DateTime}[]
    for rep_year in rep_years
        ts = build_rep_period_timestamps(rep_year)
        # Take 168-h windows for each month (12 periods × 168h = 2016h per interval)
        for m in 1:12
            period_start_day = (m - 1) * 30 + 1  # Approximate day of month
            period_end_day = min(m * 30 + 6, 365)  # Approximate end day
            # Include period if it overlaps with [day_start, day_end]
            if !(period_end_day < day_start || period_start_day > day_end)
                push!(rep_periods_all, ts[(m-1)*168+1 : m*168])
            end
        end
    end

    if isempty(rep_periods_all)
        @warn "Day range [$day_start, $day_end] filtered out all representative periods. Using all periods."
        rep_periods_all = Vector{DateTime}[]
        for rep_year in rep_years
            ts = build_rep_period_timestamps(rep_year)
            for m in 1:12
                push!(rep_periods_all, ts[(m-1)*168+1 : m*168])
            end
        end
    end

    # Weights: equal across all representative periods
    weights = ones(length(rep_periods_all)) ./ length(rep_periods_all)
    operation_model = PSI2.OperationalRepresentativeDays(rep_periods_all, weights)

    # Template: DiscountedCashFlow (multiple intervals) + OperationalRepresentativeDays + EnergyLowerBound + NodalBalanceModel
    # Power balance slacks (use_slacks=true) should allow violations when necessary
    template = PSI2.InvestmentModelTemplate(
        PSI2.DiscountedCashFlow(settings().discount_rate, Year(settings().base_year), intervals),
        operation_model,
        PSI2.EnergyLowerBound(),
        copper_plate ? PSI2.TransportModel(PSI2.SingleRegionBalanceModel; use_slacks=true) :
                       PSI2.TransportModel(PSI2.NodalBalanceModel; use_slacks=true),
    )

    # Debug: check feasibility model
    feas = PSI2.get_feasibility_model(template)
    verbose && @info "Template feasibility model: $(typeof(feas))"
    if isa(feas, PSI2.RepresentativePeriods)
        verbose && @info "  Sample periods: $(length(feas.sample_periods))"
    end

    # Register candidate technologies (those explicitly added with _new suffix)
    # Portfolio technologies are investment-capable; base system devices dispatch-only

    # Candidate Renewables: investment + dispatch with capacity factors
    all_candidate_renewables = [w.name for w in settings().candidates.wind if w.in_template]

    # Filter renewable candidates by procurement availability
    candidate_renewables = filter(all_candidate_renewables) do tech_name
        avail_from, avail_until = get(procurement_timelines, tech_name, (2020, 9999))
        any(avail_from <= year <= avail_until for year in rep_years)
    end

    # Planned additions are built exactly once, in their year (fixed in solve_planning)
    append!(candidate_renewables, [a.name for a in settings().planned_additions])

    if !isempty(candidate_renewables)
        PSI2.set_technology_model!(template, candidate_renewables,
            PSI2.TechnologyModel(
                PSIP.SupplyTechnology{PowerSystems.RenewableDispatch},
                PSI2.BinaryInvestment, PSI2.BasicDispatch, PSI2.BasicDispatchFeasibility))
    end

    # Candidate Diesel: discrete units (binary investment per unit, not continuous)
    # All diesel options are now optional candidates with capital costs (no forced/exogenous builds)
    all_diesel_names = ["Diesel_$(d.unit_name)_$(d.site)" for d in settings().candidates.diesel]

    # Filter diesel candidates by procurement availability in at least one investment period
    diesel_names = filter(all_diesel_names) do tech_name
        avail_from, avail_until = get(procurement_timelines, tech_name, (2020, 9999))
        # Tech is available if any rep_year falls within [avail_from, avail_until]
        any(avail_from <= year <= avail_until for year in rep_years)
    end

    if !isempty(diesel_names)
        PSI2.set_technology_model!(template, diesel_names,
            PSI2.TechnologyModel(
                PSIP.SupplyTechnology{PowerSystems.ThermalStandard},
                PSI2.BinaryInvestment, PSI2.BasicDispatch, PSI2.BasicDispatchFeasibility))
    end


    # Candidate demand: static load (main demand requirement + arrival-based loads)
    demand_names = [settings().base_demand.name]
    port_id = objectid(port)
    if haskey(_PORTFOLIO_INTERVAL_DATA, port_id)
        # Use actual load names that were successfully added to the portfolio
        actual_load_names = _PORTFOLIO_INTERVAL_DATA[port_id].actual_load_names
        append!(demand_names, actual_load_names)
    end
    PSI2.set_technology_model!(template, demand_names,
        PSI2.TechnologyModel(
            PSIP.DemandRequirement{PowerSystems.PowerLoad},
            PSI2.StaticLoadInvestment, PSI2.NoDispatch, PSI2.BasicDispatchFeasibility))

    # Transmission: DISABLED for CEM to avoid transmission bottleneck infeasibility
    # CEM focuses on generation/storage investments; transmission is assumed sufficient
    # or relaxed through nodal power balance slacks
    # NOTE: This removes transmission flow limit constraints from the model
    # Users can add transmission investment constraints post-hoc if needed

    # Storage: candidate investment with continuous capacity (multiple options to choose from)
    # Each battery option can be built with continuous scaling up to max capacity
    all_battery_names = ["Battery_$(b.power_mw)MW_$(b.energy_mwh)MWh" for b in settings().candidates.battery]

    # Filter battery candidates by procurement availability
    @info "Battery filtering: rep_years=$rep_years, procurement_timelines keys=$(collect(keys(procurement_timelines)))"
    battery_names = filter(all_battery_names) do tech_name
        avail_from, avail_until = get(procurement_timelines, tech_name, (2020, 9999))
        is_available = any(avail_from <= year <= avail_until for year in rep_years)
        @debug "  Battery $tech_name: available [$avail_from, $avail_until], passes_filter=$is_available"
        is_available
    end

    @info "Battery candidates after filtering: $battery_names"

    if !isempty(battery_names)
        @info "Registering $(length(battery_names)) battery technologies in template"
        PSI2.set_technology_model!(template, battery_names,
            PSI2.TechnologyModel(
                PSIP.StorageTechnology{PowerSystems.EnergyReservoirStorage},
                PSI2.ContinuousInvestment, PSI2.CyclicalStorageDispatch, PSI2.BasicDispatchFeasibility))
    else
        @warn "NO BATTERIES PASSED THE FILTER!"
    end

    # Add device models for base_system generators (existing capacity)
    PSI2.set_device_model!(template, PSY.Generator, PSI2.BasicDispatch)

    # Debug: print what's in the template
    @info "Template technology_models contents:"
    for (model, names) in template.technology_models
        @info "  $(typeof(model).name.name): $names"
    end
    @info "Template device_models contents:"
    for (device_type, model) in template.device_models
        @info "  $(typeof(model).name.name) for $(device_type)"
    end

    return template
end

"""
    solve_planning(portfolio, timestamps; results_dir, reserve_margin) -> OptimizationProblemResults

Solves the investment optimization problem with capacity adequacy constraint.

Arguments:
  - portfolio: Portfolio object from build_planning_portfolio()
  - timestamps: Extended timestamps (2023-2035) used to build the portfolio
  - results_dir: Path to write results (default: results/planning)
  - reserve_margin: Planning reserve margin (default: 0.15 = 15%)

Returns:
  - OptimizationProblemResults with investment decisions
"""
function _add_energy_balance_slack!(model::PSI2.InvestmentModel)
    """Placeholder - slacks are now accumulated in _accumulate_all_slack_penalties!"""
    # This function is kept for backwards compatibility but does nothing
    # All slack penalties are now accumulated and set together
end

# Rated MW of an existing unit still in service in `year` (all of it when year is nothing)
_in_service_mw(gen, year) =
    max(PSY.get_max_active_power(gen) - (isnothing(year) ? 0.0 : retired_capacity_mw(PSY.get_name(gen), year)), 0.0)

function _existing_capacity_mw(portfolio; year = nothing)
    sys = PSIP.get_base_system(portfolio)
    isnothing(sys) && return 0.0
    return sum(_in_service_mw(gen, year) for gen in PSY.get_components(PSY.Generator, sys); init=0.0)
end

function _credit_for_build_variable(var_name::AbstractString, credits::Dict{String, Float64})
    best = nothing
    for tech_name in keys(credits)
        if contains(var_name, tech_name) && (isnothing(best) || length(tech_name) > length(best))
            best = tech_name
        end
    end
    return isnothing(best) ? nothing : credits[best]
end

function _existing_effective_capacity_mw(portfolio, credits::Dict{String, Float64}; year = nothing)
    sys = PSIP.get_base_system(portfolio)
    isnothing(sys) && return 0.0
    return sum(
        _in_service_mw(gen, year) * get(credits, PSY.get_name(gen), 0.0)
        for gen in PSY.get_components(PSY.Generator, sys);
        init=0.0,
    )
end

function _add_reserve_margin_slack!(model::PSI2.InvestmentModel, portfolio)
    """Add soft slack constraints with accumulated penalties for ALL slack types.

    Combines nodal balance slacks, energy feasibility slacks, and reserve margin slacks
    into ONE objective to avoid overwriting penalties.
    """
    jm = model.internal.container.JuMPmodel

    # Accumulate all slack penalties
    slack_penalties_expr = 0.0

    # Nodal balance slack penalties: $5k/MWh (pos and neg)
    # Reduced from $1M to avoid numerical issues while still heavily penalizing load shedding
    @debug "Checking for nodal slack variables: ENABLE=$(_SLACKS.nodal[]), haskey=$(haskey(jm.ext, :nodal_balance_slack_pos))"
    if _SLACKS.nodal[] && haskey(jm.ext, :nodal_balance_slack_pos)
        slack_pos = jm.ext[:nodal_balance_slack_pos]
        slack_neg = jm.ext[:nodal_balance_slack_neg]
        nodal_penalty = (sum(slack_pos) + sum(slack_neg)) * settings().unserved_energy_per_mwh
        slack_penalties_expr = slack_penalties_expr + nodal_penalty
    else
        @warn "Nodal slack variables NOT found in jm.ext (ENABLE=$_SLACKS.nodal[], haskey=$(haskey(jm.ext, :nodal_balance_slack_pos)))"
    end

    if _SLACKS.energy[] && haskey(jm.ext, :energy_feasibility_slack)
        energy_slack = jm.ext[:energy_feasibility_slack]
        energy_penalty = sum(energy_slack) * settings().unserved_energy_per_mwh
        slack_penalties_expr = slack_penalties_expr + energy_penalty
    end
    reserve_margin = portfolio.metadata.reserve_margin

    # Get final peak demand from investment intervals (accounts for load arrivals)
    port_id = objectid(portfolio)
    peak_load = case_base_peak_load_mw()
    if haskey(_PORTFOLIO_INTERVAL_DATA, port_id)
        interval_data = _PORTFOLIO_INTERVAL_DATA[port_id]
        if !isempty(interval_data.peak_mws)
            peak_load = interval_data.peak_mws[end]  # Final peak after all arrivals
        end
    end

    required_capacity = peak_load * (1.0 + reserve_margin)

    if !_SLACKS.reserve[]
        return nothing
    end

    # Annual shortfall cost, converted to present value over the years the final-period
    # shortfall persists, to match the discounted per-period objective coefficients
    annual_penalty_per_mw = settings().reserve_margin_per_mw_yr
    discount_rate = settings().discount_rate
    base_year = settings().base_year
    final_rep_year = _PORTFOLIO_INTERVAL_DATA[objectid(portfolio)].rep_years[end]
    horizon_end = Dates.year(_PORTFOLIO_INTERVAL_DATA[objectid(portfolio)].intervals[end][2])
    penalty_per_mw = annual_penalty_per_mw * sum(
        (1 / (1 + discount_rate))^(y - base_year) for y in final_rep_year:horizon_end
    )
    @info "Reserve shortfall penalty: \$$(round(penalty_per_mw, digits=0))/MW (PV of \$$(round(Int, annual_penalty_per_mw/1000))k/MW-yr over $(final_rep_year)-$(horizon_end))"

    slack_reserve_margin = @variable(jm, slack_reserve_margin >= 0)

    # Builds are per-period increments; storage uses BuildPowerCapacity rather than BuildCapacity
    credits = PSI2.get_capacity_credits(portfolio, PSIP.get_base_system(portfolio))
    if settings().capacity_credit.method == "net_load"
        merge!(credits, _net_load_capacity_credits(portfolio, final_rep_year))
    end
    jm.ext[:capacity_credits] = credits
    existing_capacity = _existing_effective_capacity_mw(portfolio, credits; year = final_rep_year)
    build_cap_expr = JuMP.AffExpr(0.0)
    n_build_vars = 0
    n_unmatched = 0
    for var in JuMP.all_variables(jm)
        var_name = name(var)
        if (contains(var_name, "BuildCapacity") || contains(var_name, "BuildPowerCapacity")) && !JuMP.is_binary(var)
            credit = _credit_for_build_variable(var_name, credits)
            if isnothing(credit)
                n_unmatched += 1
                continue
            end
            JuMP.add_to_expression!(build_cap_expr, credit, var)
            n_build_vars += 1
        end
    end
    n_unmatched > 0 && @warn "Reserve margin: $n_unmatched build variables had no matching technology credit and were excluded"
    @info "Reserve margin: $n_build_vars build variables, credited existing capacity $(round(existing_capacity, digits=2)) MW, required $(round(required_capacity, digits=2)) MW"

    @constraint(jm, existing_capacity + build_cap_expr >= required_capacity - slack_reserve_margin)

    reserve_penalty = penalty_per_mw * slack_reserve_margin
    slack_penalties_expr = slack_penalties_expr + reserve_penalty

    # SET OBJECTIVE ONCE WITH ALL ACCUMULATED SLACK PENALTIES
    # This ensures nodal, energy, and reserve penalties all get included
    current_obj = objective_function(jm)
    final_obj = current_obj + slack_penalties_expr
    @objective(jm, Min, final_obj)

    return slack_reserve_margin
end

function solve_planning(
    portfolio;
    results_dir::String = joinpath("results", "planning"),
    day_start::Int = 1,
    day_end::Int = 365,
    mip_gap::Float64 = settings().mip_gap,
    solver_time_limit::Float64 = settings().time_limit_s,
    exogenous_builds::Union{Nothing, Dict{String, Dict{Int, Float64}}} = nothing,
    fuel_cap::Bool = true,
    tier2_hours::Bool = true,
    copper_plate::Bool = true,
)
    # Convert to absolute path to ensure serialized files go to correct location
    results_dir = abspath(results_dir)
    mkpath(results_dir)

    # Retrieve investment intervals and procurement constraints from module-level cache
    port_id = objectid(portfolio)
    if !haskey(_PORTFOLIO_INTERVAL_DATA, port_id)
        error("Portfolio interval data not found. Was build_planning_portfolio called?")
    end

    interval_data = _PORTFOLIO_INTERVAL_DATA[port_id]
    intervals = interval_data.intervals
    rep_years = interval_data.rep_years
    procurement_timelines = interval_data.procurement_timelines  # (year_from, year_until) for each technology

    template = build_planning_template(intervals, rep_years, portfolio; procurement_timelines=procurement_timelines, day_start=day_start, day_end=day_end, copper_plate=copper_plate)

    model = PSI2.InvestmentModel(
        template,
        PSI2.SingleInstanceSolve,
        portfolio;
        optimizer = optimizer_with_attributes(
            HiGHS.Optimizer,
            "mip_rel_gap"  => mip_gap,
            "time_limit"   => solver_time_limit,
            "output_flag"  => false,
            "log_to_console" => false,
        ),
        store_variable_names = true,
        portfolio_to_file = false,
        output_dir = results_dir,
    )

    # Build model
    build_status = PSI2.build!(model; output_dir=results_dir)

    # Check build status before continuing
    if build_status == PSI2.ModelBuildStatus.BUILT
        @info "Model built successfully"


        # Add slacks to make infeasible problems technically solvable
        try
            _add_energy_balance_slack!(model)
            @info "Added energy balance slack (penalty: very high to signal infeasibility)"
        catch e
            @debug "Could not add energy balance slack: $e"
        end

        try
            _add_reserve_margin_slack!(model, portfolio)
            @info "Added reserve margin slack constraint (penalty: \$$(round(Int, settings().reserve_margin_per_mw_yr / 1000))k/MW-yr for capacity shortfall)"
        catch e
            @warn "Failed to add reserve margin slack: $e"
        end

        try
            _enforce_procurement_timelines!(model, portfolio, procurement_timelines, rep_years)
            @info "Applied procurement timeline constraints to forbid building in unavailable periods"
        catch e
            @warn "Failed to apply procurement timeline constraints: $e"
        end

        # Planned additions are built in their year; user exogenous builds override them per technology
        builds = merge(_planned_addition_builds(), something(exogenous_builds, Dict{String, Dict{Int, Float64}}()))
        if !isempty(builds)
            _fix_exogenous_builds!(model, portfolio, builds)
        end

        _apply_existing_availability!(model, portfolio)

        if fuel_cap
            _apply_diesel_fuel_cap!(model, portfolio)
        end

        if tier2_hours
            _apply_tier2_hours_limit!(model, portfolio)
        end

        # Write model after solve to include all constraints
        # PSI2.write_to_file(model.internal.container.JuMPmodel, joinpath(results_dir, "model.lp"))
        #@info "lp file written to: $(joinpath(results_dir, "model.lp"))"
        PSI2.solve!(model; output_dir=results_dir, console_level = Logging.Debug)
        res = PSI2.OptimizationProblemResults(model)
        try
            _LAST_CAPACITY_PLOT[] = _plot_capacity_by_type(res, portfolio, intervals, joinpath(results_dir, "capacity_by_type.html"))
        catch e
            @warn "Capacity by type plot not saved: $e"
        end
        return res
    else
        return error("Model build failed with status: $build_status")
    end
end

function _enforce_procurement_timelines!(
    model::PSI2.InvestmentModel,
    portfolio::PSIP.Portfolio,
    procurement_timelines::Dict{String, Tuple{Int, Int}},
    rep_years::Vector{Int},
)
    """Enforce procurement timeline constraints by zeroing out BuildCapacity in unavailable periods."""

    # Get the JuMP model and container
    jm = model.internal.container.JuMPmodel
    container = model.internal.container

    num_constraints_added = 0
    planned_names = Set(a.name for a in settings().planned_additions)

    # Try to access BuildCapacity variables through PSI2's standard access pattern
    try
        # Get variable keys for all BuildCapacity types
        var_keys = [
            PSI2.VariableKey{PSI2.BuildCapacity, PSIP.SupplyTechnology{PSY.ThermalStandard}}(),
            PSI2.VariableKey{PSI2.BuildCapacity, PSIP.SupplyTechnology{PSY.RenewableDispatch}}(),
            PSI2.VariableKey{PSI2.BuildPowerCapacity, PSIP.StorageTechnology{PSY.EnergyReservoirStorage}}(),
        ]

        for var_key in var_keys
            try
                var_container = PSI2.get_variable(container, var_key)
                if isempty(var_container)
                    continue
                end

                # var_container should be indexed as [tech_name, period_index]
                # Get the axes to understand the indexing
                axes_data = var_container.axes
                if length(axes_data) < 2
                    continue
                end

                tech_names = axes_data[1]
                period_indices = axes_data[2]

                @debug "Processing $(var_key): $(length(tech_names)) techs, $(length(period_indices)) periods"

                # For each technology-period pair
                for (period_pos, period_idx) in enumerate(period_indices)
                    # Match period position to rep_years
                    if period_pos <= length(rep_years)
                        period_year = rep_years[period_pos]

                        for tech_name in tech_names
                            # Planned additions are fixed to their year; timelines do not apply
                            string(tech_name) in planned_names && continue
                            # Check if technology is available in this period
                            avail_from, avail_until = get(procurement_timelines, string(tech_name), (2020, 9999))

                            if !(avail_from <= period_year <= avail_until)
                                # Technology not available in this period - force BuildCapacity to 0
                                try
                                    JuMP.@constraint(jm, var_container[tech_name, period_idx] == 0)
                                    num_constraints_added += 1
                                    @debug "Forcing BuildCapacity[$tech_name, $period_idx] = 0 (year $period_year outside [$avail_from, $avail_until])"
                                catch e
                                    @debug "Could not add constraint for $tech_name period $period_idx: $e"
                                end
                            end
                        end
                    end
                end
            catch e
                @debug "Could not process BuildCapacity variable: $e"
                continue
            end
        end
    catch e
        @warn "Error enforcing procurement timelines: $e"
    end

    @info "Added $num_constraints_added procurement timeline constraints"
    return
end


# Thermal dispatch variables in the CEM: existing ThermalStandard units in the base system and the
# diesel candidates. Returns (unit, time step, variable) and the sampled-hour scaling to a year.
function _thermal_dispatch(jm::JuMP.Model, portfolio::PSIP.Portfolio)
    sys = PSIP.get_base_system(portfolio)
    thermal_units = Set{String}(PSY.get_name.(PSY.get_components(PSY.ThermalStandard, sys)))
    for (tech_name, entry) in settings().catalog
        entry.kind == "Diesel" && push!(thermal_units, tech_name)
    end

    dispatch = Tuple{String, Int, JuMP.VariableRef}[]
    for v in JuMP.all_variables(jm)
        vn = name(v)
        contains(vn, "ActivePowerVariable") || continue
        m = match(r"_\{([^{}]+), (\d+)\}$", vn)
        (isnothing(m) || !(m.captures[1] in thermal_units)) && continue
        push!(dispatch, (String(m.captures[1]), parse(Int, m.captures[2]), v))
    end
    isempty(dispatch) && return dispatch, 0, 0.0

    n_intervals = length(_PORTFOLIO_INTERVAL_DATA[objectid(portfolio)].intervals)
    hours_per_interval = maximum(t for (_, t, _) in dispatch) ÷ n_intervals
    return dispatch, hours_per_interval, 8760.0 / hours_per_interval
end

# Rated capacity (MW) of a thermal unit: base system rating for existing units, catalog size for candidates
function _thermal_capacity_mw(unit::AbstractString, sys::PSY.System)
    entry = get(settings().catalog, unit, nothing)
    !isnothing(entry) && return Float64(entry.capacity_mw)
    gen = PSY.get_component(PSY.ThermalStandard, sys, unit)
    return PSY.with_units_base(() -> PSY.get_max_active_power(gen), sys, PSY.UnitSystem.NATURAL_UNITS)
end

# System-wide fuel cap on all thermal units, per investment interval (soft, penalized per gallon)
function _apply_diesel_fuel_cap!(model::PSI2.InvestmentModel, portfolio::PSIP.Portfolio)
    jm = model.internal.container.JuMPmodel
    n_intervals = length(_PORTFOLIO_INTERVAL_DATA[objectid(portfolio)].intervals)
    dispatch, hours_per_interval, annual_scale = _thermal_dispatch(jm, portfolio)
    if isempty(dispatch)
        @warn "No diesel dispatch variables found; fuel cap not applied"
        return
    end

    fuel = [JuMP.AffExpr(0.0) for _ in 1:n_intervals]
    for (unit, t, v) in dispatch
        interval = div(t - 1, hours_per_interval) + 1
        heat_rate = something(case_rated_heat_rate(unit), settings().default_heat_rate)
        gal_per_mwh = heat_rate / case_fuel_hhv_mbtu_per_gal()
        JuMP.add_to_expression!(fuel[interval], gal_per_mwh, v)
    end

    slack = JuMP.@variable(jm, tier2_fuel_slack[1:n_intervals] >= 0)
    sample_limit = settings().tier2_fuel_limit_gal / annual_scale
    JuMP.@constraint(jm, fuel_cap[i = 1:n_intervals], fuel[i] <= sample_limit + slack[i])
    jm.ext[:tier2_fuel_slack] = slack
    jm.ext[:tier2_fuel_expr] = fuel
    jm.ext[:tier2_annual_scale] = annual_scale

    current_obj = JuMP.objective_function(jm)
    JuMP.@objective(jm, Min, current_obj + settings().tier2_penalty_per_gal * sum(slack))
    @info "System diesel fuel cap: $(Int(settings().tier2_fuel_limit_gal)) gal/yr per interval, \$$(Int(settings().tier2_penalty_per_gal))/gal penalty, $(length(dispatch)) diesel dispatch variables"
    return
end

# Operating limit for each Tier 2 unit, per investment interval. The CEM has no commitment
# variables, so hours are full-load equivalent: energy <= hours_per_yr × rated MW (soft, penalized per MWh).
function _apply_tier2_hours_limit!(model::PSI2.InvestmentModel, portfolio::PSIP.Portfolio)
    jm = model.internal.container.JuMPmodel
    sys = PSIP.get_base_system(portfolio)
    n_intervals = length(_PORTFOLIO_INTERVAL_DATA[objectid(portfolio)].intervals)
    dispatch, hours_per_interval, annual_scale = _thermal_dispatch(jm, portfolio)
    filter!(d -> unit_tier(d[1]) == 2, dispatch)
    if isempty(dispatch)
        @warn "No Tier 2 dispatch variables found; Tier 2 hours limit not applied"
        return
    end

    units = sort(unique(first.(dispatch)))
    energy = Dict((u, i) => JuMP.AffExpr(0.0) for u in units, i in 1:n_intervals)
    for (unit, t, v) in dispatch
        JuMP.add_to_expression!(energy[(unit, div(t - 1, hours_per_interval) + 1)], 1.0, v)
    end
    capacity = Dict(u => _thermal_capacity_mw(u, sys) for u in units)

    slack = JuMP.@variable(jm, tier2_hours_slack[units, 1:n_intervals] >= 0)
    hours = settings().tier2_hours_per_yr
    JuMP.@constraint(jm, tier2_hours[u = units, i = 1:n_intervals],
        energy[(u, i)] <= hours * capacity[u] / annual_scale + slack[u, i])
    jm.ext[:tier2_hours] = (energy = energy, slack = slack, capacity = capacity, annual_scale = annual_scale,
                            units = units, n_intervals = n_intervals)

    current_obj = JuMP.objective_function(jm)
    JuMP.@objective(jm, Min, current_obj + settings().tier2_hours_penalty_per_mwh * sum(slack))
    @info "Tier 2 hours limit: $(hours) h/yr full-load equivalent for $(length(units)) units, \$$(settings().tier2_hours_penalty_per_mwh)/MWh penalty above the limit"
    return
end

function _write_planning_summary(res::PSI2.OptimizationProblemResults, port::PSIP.Portfolio, path::String)
    container = PSI2.get_optimization_container(res.model)
    jm = PSI2.get_jump_model(container)
    t2 = _tier2_fuel_by_interval(res)
    hours = _tier2_hours_by_interval(res)
    summary = Dict(
        "objective" => JuMP.objective_value(jm),
        "investments_mw" => _extract_investment_results(res),
        "tier2_gallons_per_interval" => isnothing(t2) ? nothing : t2.gallons,
        "tier2_slack_gallons_per_interval" => isnothing(t2) ? nothing : t2.slack,
        "tier2_hours_excess_mwh_per_interval" => isnothing(hours) ? nothing :
            [sum(hours.excess_mwh[(u, i)] for u in hours.units) for i in 1:hours.n_intervals],
    )
    open(path, "w") do io
        JSON.print(io, summary, 2)
    end
    return path
end

function _tier2_fuel_by_interval(res::PSI2.OptimizationProblemResults)
    container = PSI2.get_optimization_container(res.model)
    isnothing(container) && return nothing
    jm = PSI2.get_jump_model(container)
    haskey(jm.ext, :tier2_fuel_expr) || return nothing
    scale = jm.ext[:tier2_annual_scale]
    return (
        gallons = [JuMP.value(e) * scale for e in jm.ext[:tier2_fuel_expr]],
        slack = [JuMP.value(v) * scale for v in jm.ext[:tier2_fuel_slack]],
        limit = settings().tier2_fuel_limit_gal,
        penalty = settings().tier2_penalty_per_gal,
    )
end

# Annualized full-load-equivalent hours and energy above the limit for each Tier 2 unit and interval
function _tier2_hours_by_interval(res::PSI2.OptimizationProblemResults)
    container = PSI2.get_optimization_container(res.model)
    isnothing(container) && return nothing
    jm = PSI2.get_jump_model(container)
    haskey(jm.ext, :tier2_hours) || return nothing
    h = jm.ext[:tier2_hours]
    keys_ = [(u, i) for u in h.units, i in 1:h.n_intervals]
    return (
        units = h.units,
        n_intervals = h.n_intervals,
        capacity = h.capacity,
        hours = Dict(k => JuMP.value(h.energy[k]) * h.annual_scale / h.capacity[k[1]] for k in keys_),
        excess_mwh = Dict(k => JuMP.value(h.slack[k...]) * h.annual_scale for k in keys_),
        limit = settings().tier2_hours_per_yr,
        penalty = settings().tier2_hours_penalty_per_mwh,
    )
end

# PowerGraphics palette category for each capacity type
const CAPACITY_PLOT_PALETTE_CATEGORY = Dict(
    "Hydro" => "Hydropower",
    "Wind" => "Wind",
    "Solar" => "Solar",
    "Diesel" => "Petroleum",
    "Battery" => "Battery",
    "Other" => "Other",
)

# Most recent capacity-by-type plot from solve_planning
const _LAST_CAPACITY_PLOT = Ref{Any}(nothing)
last_capacity_plot() = _LAST_CAPACITY_PLOT[]

function _capacity_plot_rank(category::AbstractString)
    default_palette = PG.get_default_palette(PG.PALETTE)
    i = findfirst(p -> p.category == category, default_palette)
    !isnothing(i) && return i
    j = findfirst(p -> p.category == category, PG.PALETTE)
    return isnothing(j) ? typemax(Int) : length(default_palette) + PG.PALETTE[j].order
end

function _capacity_type(name::AbstractString)
    kind = technology_kind(name)
    return isnothing(kind) ? "Diesel" : kind
end

function _existing_capacity_by_type(port::PSIP.Portfolio, year = nothing)
    totals = Dict{String, Float64}()
    sys = PSIP.get_base_system(port)
    isnothing(sys) && return totals
    for gen in PSY.get_components(PSY.Generator, sys)
        pm = try PSY.get_prime_mover_type(gen) catch; nothing end
        t = gen isa PSY.ThermalStandard ? "Diesel" :
            gen isa PSY.EnergyReservoirStorage ? "Battery" :
            pm == PSY.PrimeMovers.HY ? "Hydro" :
            pm == PSY.PrimeMovers.WT ? "Wind" :
            pm == PSY.PrimeMovers.PVe ? "Solar" :
            pm == PSY.PrimeMovers.BA ? "Battery" : "Other"
        totals[t] = get(totals, t, 0.0) + _in_service_mw(gen, year)
    end
    return totals
end

function _built_capacity_by_type(res::PSI2.OptimizationProblemResults, n_intervals::Int)
    built = Dict{String, Vector{Float64}}()
    for var_key in [
        PSI2.VariableKey{PSI2.BuildCapacity, PSIP.SupplyTechnology{PSY.RenewableDispatch}}(),
        PSI2.VariableKey{PSI2.BuildCapacity, PSIP.SupplyTechnology{PSY.ThermalStandard}}(),
        PSI2.VariableKey{PSI2.BuildPowerCapacity, PSIP.StorageTechnology{PSY.EnergyReservoirStorage}}(),
    ]
        build_df = PSI2.read_variable(res, var_key)
        isempty(build_df) && continue
        for row in eachrow(build_df)
            ismissing(row.time_period_idx) && continue
            v = get!(built, _capacity_type(String(row.technology)), zeros(n_intervals))
            v[row.time_period_idx] += row.value
        end
    end
    return built
end

function _plot_capacity_by_type(
    res::PSI2.OptimizationProblemResults,
    port::PSIP.Portfolio,
    intervals::Vector{NTuple{2, Date}},
    output_path::String,
)
    n = length(intervals)
    labels = ["$(year(s))–$(year(e))" for (s, e) in intervals]
    rep_years = _PORTFOLIO_INTERVAL_DATA[objectid(port)].rep_years
    existing = [_existing_capacity_by_type(port, y) for y in rep_years]  # after planned retirements
    built = _built_capacity_by_type(res, n)
    types = sort(
        collect(union(keys.(existing)..., keys(built)));
        by = t -> _capacity_plot_rank(get(CAPACITY_PLOT_PALETTE_CATEGORY, t, t)),
    )
    traces = Dict{String, Any}[]
    for t in types
        base = [get(existing[i], t, 0.0) for i in 1:n]
        cum = cumsum(get(built, t, zeros(n)))
        category = get(CAPACITY_PLOT_PALETTE_CATEGORY, t, t)
        palette_rgb = [p.RGB for p in PG.PALETTE if p.category == category]
        push!(traces, Dict{String, Any}(
            "type" => "bar",
            "name" => t,
            "x" => labels,
            "y" => base .+ cum,
            "marker" => Dict("color" => isempty(palette_rgb) ? "gray" : first(palette_rgb)),
        ))
    end
    layout = Dict{String, Any}(
        "title" => "Total system capacity by type (nameplate MW)",
        "barmode" => "stack",
        "xaxis" => Dict("title" => "Investment interval"),
        "yaxis" => Dict("title" => "MW"),
    )
    plot = PlotlyLight.Plot(traces, layout)
    PlotlyLight.save(plot, output_path)
    display(plot)
    return plot
end

# Planned additions from case.toml as exogenous builds: capacity in the addition year, nothing otherwise
_planned_addition_builds() =
    Dict{String, Dict{Int, Float64}}(a.name => Dict(a.year => Float64(a.capacity_mw)) for a in settings().planned_additions)

# Scale the CEM dispatch limits of existing base-system units for each investment interval's
# representative year: by the share still in service after planned retirements and by
# case_existing_availability_multiplier. Scales the dispatch variable upper bound (rated MW) and,
# where present, the capacity-factor limit constraint.
function _apply_existing_availability!(model::PSI2.InvestmentModel, portfolio::PSIP.Portfolio)
    container = model.internal.container
    rep_years = _PORTFOLIO_INTERVAL_DATA[objectid(portfolio)].rep_years
    sys = PSIP.get_base_system(portfolio)
    rated = PSY.with_units_base(sys, PSY.UnitSystem.NATURAL_UNITS) do
        Dict(PSY.get_name(g) => PSY.get_max_active_power(g) for g in PSY.get_components(PSY.Generator, sys))
    end
    existing = Set(keys(rated))
    function multiplier(name, t, n_steps)
        year = rep_years[div(t - 1, n_steps ÷ length(rep_years)) + 1]
        in_service = rated[name] > 0 ? max(rated[name] - retired_capacity_mw(name, year), 0.0) / rated[name] : 1.0
        return in_service * case_existing_availability_multiplier(name, year)
    end

    n_scaled = 0
    for (store, kind) in ((PSI2.get_variables(container), "ActivePowerVariable"),
                          (PSI2.get_constraints(container), "ActivePowerLimitsConstraint"))
        for (key, arr) in store
            contains(string(key), kind) || continue
            arr isa JuMP.Containers.DenseAxisArray || continue
            names_, steps = axes(arr)
            for name in names_
                name in existing || continue
                for t in steps
                    m = multiplier(name, t, length(steps))
                    m == 1.0 && continue
                    x = arr[name, t]
                    if x isa JuMP.VariableRef && JuMP.has_upper_bound(x)
                        JuMP.set_upper_bound(x, m * JuMP.upper_bound(x))
                    elseif x isa JuMP.ConstraintRef
                        JuMP.set_normalized_rhs(x, m * JuMP.normalized_rhs(x))
                    else
                        continue
                    end
                    n_scaled += 1
                end
            end
        end
    end
    n_scaled > 0 && @info "Scaled $n_scaled existing-unit dispatch limits by case availability multipliers"
    return
end

function _investment_period_for_year(intervals::Vector{NTuple{2, Date}}, year::Int)::Union{Int, Nothing}
    return findfirst(iv -> Dates.year(iv[1]) <= year <= Dates.year(iv[2]), intervals)
end

function _fix_exogenous_builds!(
    model::PSI2.InvestmentModel,
    portfolio::PSIP.Portfolio,
    builds::Dict{String, Dict{Int, Float64}},
)
    interval_data = _PORTFOLIO_INTERVAL_DATA[objectid(portfolio)]
    intervals = interval_data.intervals
    jm = model.internal.container.JuMPmodel

    period_builds = Dict{String, Dict{Int, Float64}}()
    for (tech, year_mw) in builds
        period_builds[tech] = Dict{Int, Float64}()
        for (year, mw) in year_mw
            period = _investment_period_for_year(intervals, year)
            if isnothing(period)
                @warn "Exogenous build for $tech in $year is outside the planning horizon and is ignored"
                continue
            end
            period_builds[tech][period] = get(period_builds[tech], period, 0.0) + mw
        end
    end

    ratings = Dict{String, Float64}()
    thermal = Set{String}()
    for tech in PSIP.get_technologies(PSIP.SupplyTechnology, portfolio)
        name = PSIP.get_name(tech)
        ratings[name] = PSIP.get_capacity_limits(tech).max
        tech isa PSIP.SupplyTechnology{PSY.ThermalStandard} && push!(thermal, name)
    end

    matched = Set{String}()
    n_fixed = 0
    for v in JuMP.all_variables(jm)
        vn = name(v)
        (contains(vn, "BuildCapacity") || contains(vn, "BuildPowerCapacity")) || continue
        m = match(r"_\{([^{}]+), (\d+)\}$", vn)
        isnothing(m) && continue
        tech = String(m.captures[1])
        period = parse(Int, m.captures[2])
        haskey(period_builds, tech) || continue
        push!(matched, tech)

        target = get(period_builds[tech], period, 0.0)
        if tech in thermal && target > 1e-6 && abs(target - ratings[tech]) > 1e-6
            error("Exogenous build for $tech must be 0 or one unit ($(ratings[tech]) MW) per interval; got $target MW")
        end
        # Binary investments also have a 0/1 build decision (BuildCapacity_binary) next to the MW build
        JuMP.fix(v, JuMP.is_binary(v) ? (target > 1e-6 ? 1.0 : 0.0) : target; force=true)
        n_fixed += 1
    end

    unmatched = setdiff(keys(period_builds), matched)
    isempty(unmatched) || @warn "Exogenous builds with no matching build variable (technology not in the model): $(sort(collect(unmatched)))"
    @info "Fixed $n_fixed build variables from exogenous build inputs for $(length(matched)) technologies"
    return
end

function _extract_investment_results(res::PSI2.OptimizationProblemResults)
    results = Dict{String, Float64}()

    # Aggregate BuildCapacity across all investment periods (sum for each technology)
    for var_key in [
        PSI2.VariableKey{PSI2.BuildCapacity, PSIP.SupplyTechnology{PSY.RenewableDispatch}}(),
        PSI2.VariableKey{PSI2.BuildCapacity, PSIP.SupplyTechnology{PSY.ThermalStandard}}(),
        PSI2.VariableKey{PSI2.BuildPowerCapacity, PSIP.StorageTechnology{PSY.EnergyReservoirStorage}}(),
    ]
        build_df = PSI2.read_variable(res, var_key)
        if !isempty(build_df)
            # Group by technology and sum across all time periods
            for tech in unique(build_df.technology)
                tech_rows = build_df[build_df.technology .== tech, :]
                total_val = sum(tech_rows.value)
                results[tech] = total_val
            end
        end
    end

    return results
end


"""
    _extract_investment_by_interval(res::PSI2.OptimizationProblemResults, intervals, rep_years)

Extract capacity built in each investment interval with years when investments are made.

Returns Dict{String, Vector{Tuple{Int, Float64}}} where each tech maps to vector of (year, capacity) tuples.
"""
function _extract_investment_by_interval(
    res::PSI2.OptimizationProblemResults,
    intervals::Vector{NTuple{2, Date}},
    rep_years::Vector{Int},
)
    by_interval = Dict{String, Vector{Tuple{Int, Float64}}}()

    try
        # Extract BuildCapacity using read_variable() which now maps indices to time periods
        investment_builds = Dict{Tuple{String, Int}, Float64}()

        # Extract for all technology types via read_variable() (now returns native time_period mapping)
        for var_key in [
            PSI2.VariableKey{PSI2.BuildCapacity, PSIP.SupplyTechnology{PSY.RenewableDispatch}}(),
            PSI2.VariableKey{PSI2.BuildCapacity, PSIP.SupplyTechnology{PSY.ThermalStandard}}(),
            PSI2.VariableKey{PSI2.BuildPowerCapacity, PSIP.StorageTechnology{PSY.EnergyReservoirStorage}}(),
        ]
            build_df = PSI2.read_variable(res, var_key)
            if !isempty(build_df)
                # read_variable() now returns columns: technology, time_period_idx, time_period, value
                # where time_period_idx is the integer index (1, 2, 3, 4)
                # and time_period is the native mapped date range (e.g., "2032-01-01 to 2035-12-31")
                for row in eachrow(build_df)
                    if !ismissing(row.time_period_idx)  # Only consider rows with time/interval information
                        investment_builds[(row.technology, row.time_period_idx)] = row.value
                    end
                end
            end
        end

        # Process builds: if capacity > 0.01 in an interval, record the build year
        for ((tech_name, interval_idx), capacity) in investment_builds
            if capacity > 0.01 && interval_idx <= length(rep_years)
                if !haskey(by_interval, tech_name)
                    by_interval[tech_name] = Tuple{Int, Float64}[]
                end
                year = rep_years[interval_idx]
                push!(by_interval[tech_name], (year, capacity))
            end
        end

    catch e
        @warn "Error extracting investment data: $e"
    end

    return by_interval
end

"""
    report_planning_results(res, scenario)

Display investment optimization results.

Arguments:
  - res: OptimizationProblemResults from solve_planning()
  - scenario: Symbol for scenario name
"""
function report_planning_results(
    res      :: Union{Nothing, PSI2.OptimizationProblemResults},
    port     :: PSIP.Portfolio,
    scenario :: Symbol = :multi_period,
)
    if isnothing(res)
        println("\n" * "="^70)
        println("Capacity Expansion: $(settings().title) (scenario: $scenario)")
        println("="^70 * "\n")
        println("Portfolio Structure:")
        techs = PSIP.get_technologies(PSIP.Technology, port)
        for tech in techs
            name = PSIP.get_name(tech)
            try
                if tech isa PSIP.StorageTechnology
                    cap_lim = PSIP.get_capacity_limits_discharge(tech)
                    println("  - $name (discharge: $(cap_lim.max) MW)")
                else
                    cap_lim = PSIP.get_capacity_limits(tech)
                    println("  - $name (max: $(cap_lim.max) MW)")
                end
            catch
                println("  - $name")
            end
        end
        println("\nOptimization Results: No solution available")
        println("="^70 * "\n")
    else
        try
            inv_results = _extract_investment_results(res)

            println("\n" * "="^70)
            println("Capacity Expansion: $(settings().title) (scenario: $scenario)")
            println("="^70 * "\n")

            if !isempty(inv_results)
                # Try to extract per-interval investment data if available
                port_id = objectid(port)
                by_interval = nothing
                intervals = nothing
                rep_years = nothing

                if haskey(_PORTFOLIO_INTERVAL_DATA, port_id)
                    interval_data = _PORTFOLIO_INTERVAL_DATA[port_id]
                    intervals = interval_data.intervals
                    rep_years = interval_data.rep_years
                    by_interval = _extract_investment_by_interval(res, intervals, rep_years)
                end

                println("Investment Decisions (Build Capacity):")

                # Categorize investment results
                renewable_results = filter(p -> technology_kind(p[1]) in ("Wind", "Solar"), inv_results)
                diesel_results = filter(p -> technology_kind(p[1]) == "Diesel", inv_results)
                battery_results = filter(p -> technology_kind(p[1]) == "Battery", inv_results)

                if !isnothing(by_interval) && !isempty(by_interval)
                    # Print with actual year investments are made

                    # Renewables
                    if !isempty(renewable_results)
                        println("\n  Renewables:")
                        for (tech_name, capacity) in sort(renewable_results)
                            if capacity > 0.01
                                println("    ✓ $tech_name: $(round(capacity, digits=2)) MW")
                                if haskey(by_interval, tech_name) && !isempty(by_interval[tech_name])
                                    for (year, cap) in by_interval[tech_name]
                                        if cap > 0.01
                                            println("        ├─ Year $year: +$(round(cap, digits=2)) MW")
                                        end
                                    end
                                end
                            else
                                println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                            end
                        end
                    end

                    # Diesel
                    if !isempty(diesel_results)
                        println("\n  Diesel Generation:")
                        for (tech_name, capacity) in sort(diesel_results)
                            if capacity > 0.01
                                println("    ✓ $tech_name: $(round(capacity, digits=2)) MW")
                                if haskey(by_interval, tech_name) && !isempty(by_interval[tech_name])
                                    for (year, cap) in by_interval[tech_name]
                                        if cap > 0.01
                                            println("        ├─ Year $year: +$(round(cap, digits=2)) MW")
                                        end
                                    end
                                end
                            else
                                println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                            end
                        end
                    end

                    # Battery Storage - always show all battery options
                    println("\n  Energy Storage (Batteries):")
                    if !isempty(battery_results)
                        for (tech_name, capacity) in sort(battery_results)
                            if capacity > 0.01
                                entry = settings().catalog[tech_name]
                                energy_total = entry.energy_mwh * capacity / entry.power_mw
                                println("    ✓ $tech_name: $(round(capacity, digits=2)) MW, $(round(energy_total, digits=1)) MWh total")
                                if haskey(by_interval, tech_name) && !isempty(by_interval[tech_name])
                                    for (year, cap) in by_interval[tech_name]
                                        if cap > 0.01
                                            println("        ├─ Year $year: +$(round(cap, digits=2)) MW")
                                        end
                                    end
                                end
                            else
                                println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                            end
                        end
                    else
                        # No batteries in results - show all available options as not built
                        for b in settings().candidates.battery
                            println("    ✗ $(battery_candidate_name(b)): 0.0 MW (not built)")
                        end
                    end
                elseif !isnothing(intervals) && !isnothing(rep_years)
                    # Fallback: show planning horizon when per-interval data unavailable

                    # Renewables
                    if !isempty(renewable_results)
                        println("\n  Renewables:")
                        for (tech_name, capacity) in sort(renewable_results)
                            if capacity > 0.01
                                println("    ✓ $tech_name: $(round(capacity, digits=2)) MW")
                            else
                                println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                            end
                        end
                    end

                    # Diesel
                    if !isempty(diesel_results)
                        println("\n  Diesel Generation:")
                        for (tech_name, capacity) in sort(diesel_results)
                            if capacity > 0.01
                                println("    ✓ $tech_name: $(round(capacity, digits=2)) MW")
                            else
                                println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                            end
                        end
                    end

                    # Battery Storage - always show all battery options
                    println("\n  Energy Storage (Batteries):")
                    if !isempty(battery_results)
                        for (tech_name, capacity) in sort(battery_results)
                            if capacity > 0.01
                                parts = split(tech_name, "_")
                                energy_str = endswith(parts[end], "MWh") ? parts[end][1:end-3] : ""
                                energy_val = isempty(energy_str) ? 0.0 : tryparse(Float64, energy_str)
                                energy_total = isnothing(energy_val) ? 0 : energy_val * capacity / tryparse(Float64, parts[2][1:end-2])
                                println("    ✓ $tech_name: $(round(capacity, digits=2)) MW, $(round(energy_total, digits=1)) MWh total")
                            else
                                println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                            end
                        end
                    else
                        for b in settings().candidates.battery
                            println("    ✗ $(battery_candidate_name(b)): 0.0 MW (not built)")
                        end
                    end
                else
                    # Final fallback: just show totals (all technologies)
                    println("\n  Renewables:")
                    for (tech_name, capacity) in sort(renewable_results)
                        if capacity > 0.01
                            println("    ✓ $tech_name: $(round(capacity, digits=2)) MW")
                        else
                            println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                        end
                    end

                    println("\n  Diesel Generation:")
                    for (tech_name, capacity) in sort(diesel_results)
                        if capacity > 0.01
                            println("    ✓ $tech_name: $(round(capacity, digits=2)) MW")
                        else
                            println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                        end
                    end

                    println("\n  Energy Storage (Batteries):")
                    if !isempty(battery_results)
                        for (tech_name, capacity) in sort(battery_results)
                            if capacity > 0.01
                                parts = split(tech_name, "_")
                                energy_str = endswith(parts[end], "MWh") ? parts[end][1:end-3] : ""
                                energy_val = isempty(energy_str) ? 0.0 : tryparse(Float64, energy_str)
                                energy_total = isnothing(energy_val) ? 0 : energy_val * capacity / tryparse(Float64, parts[2][1:end-2])
                                println("    ✓ $tech_name: $(round(capacity, digits=2)) MW, $(round(energy_total, digits=1)) MWh total")
                            else
                                println("    ✗ $tech_name: $(round(capacity, digits=4)) MW (not built)")
                            end
                        end
                    else
                        for b in settings().candidates.battery
                            println("    ✗ $(battery_candidate_name(b)): 0.0 MW (not built)")
                        end
                    end
                end

                total_capacity_built = 0.0
                total_investment_cost = 0.0

                for (tech_name, capacity) in sort(inv_results)
                    if capacity > 0.01
                        # Get technology and its capital cost
                        try
                            tech = PSIP.get_technology(PSIP.Technology, port, tech_name)
                            if !isnothing(tech)
                                cap_cost = PSIP.get_capital_costs(tech)
                                # Capital cost is typically in $/kW, convert to total cost
                                if !isnothing(cap_cost) && capacity > 0.01
                                    # LinearCurve provides a constant cost per MW
                                    annual_cost = try
                                        val = cap_cost.m  # LinearCurve has field m
                                        val * capacity / 1000  # Convert $/kW to total $/year
                                    catch
                                        0.0
                                    end
                                    total_investment_cost += annual_cost
                                end
                                total_capacity_built += capacity
                            end
                        catch
                            total_capacity_built += capacity
                        end
                    end
                end

                println("\nCapacity Summary:")

                # Existing capacity from the base system, after planned retirements by the final interval
                final_year = isnothing(rep_years) ? nothing : rep_years[end]
                existing_capacity = _existing_capacity_mw(port; year = final_year)

                total_final_capacity = existing_capacity + total_capacity_built

                for r in settings().planned_retirements
                    println("  Planned retirement: $(r.unit) -$(r.capacity_mw) MW from $(r.year)")
                end
                println("  Existing generation capacity$(isnothing(final_year) ? "" : " in $final_year"): $(round(existing_capacity, digits=2)) MW")
                credit_jm = PSI2.get_jump_model(PSI2.get_optimization_container(res.model))
                if haskey(credit_jm.ext, :capacity_credits)
                    renewable = [n for n in keys(credit_jm.ext[:capacity_credits])
                                 if technology_kind(n) == "Wind" || n == settings().pcm.reference_wind_unit ||
                                    occursin(r"(?i)wind|solar|pv", n)]
                    method = settings().capacity_credit.method == "net_load" ?
                        "mean CF over the top $(settings().capacity_credit.top_hours) net-load hours" : "fixed by technology type"
                    println("  Wind/solar capacity credits ($method): " *
                            join(["$n $(round(credit_jm.ext[:capacity_credits][n], digits=3))" for n in sort(renewable)], ", "))
                end
                println("  New capacity being built: $(round(total_capacity_built, digits=2)) MW")
                println("  Final total capacity: $(round(total_final_capacity, digits=2)) MW")

                # Show investment timeline by interval if available
                if !isnothing(intervals) && !isnothing(rep_years)
                    println("\nInvestment Timeline:")
                    for i in 1:length(intervals)
                        int_start, int_end = intervals[i]
                        peak_mw = i <= length(_PORTFOLIO_INTERVAL_DATA[port_id].peak_mws) ?
                                  _PORTFOLIO_INTERVAL_DATA[port_id].peak_mws[i] : 0.0
                        line = "  Interval $(i): $(year(int_start))–$(year(int_end)) (Peak demand: $(round(peak_mw, digits=2)) MW)"
                        t2_now = _tier2_fuel_by_interval(res)
                        if !isnothing(t2_now) && i <= length(t2_now.gallons)
                            gal = t2_now.gallons[i]
                            status = t2_now.slack[i] > 1e-6 ? "EXCEEDS by $(round(t2_now.slack[i], digits=0)) gal" : "within limit"
                            line *= " | Diesel fuel: $(round(gal, digits=0)) gal/yr ($status)"
                        end
                        hours_now = _tier2_hours_by_interval(res)
                        if !isnothing(hours_now) && i <= hours_now.n_intervals
                            over = [u for u in hours_now.units if hours_now.excess_mwh[(u, i)] > 1e-3]
                            line *= isempty(over) ? " | Tier 2 hours: all within $(Int(hours_now.limit)) h" :
                                    " | Tier 2 hours: $(length(over)) of $(length(hours_now.units)) units over $(Int(hours_now.limit)) h"
                        end
                        println(line)
                    end
                end

                # Calculate and report capital cost breakdown by technology
                println("\nCapital Cost Summary:")
                total_capital_cost = 0.0
                for (tech_name, capacity) in sort(inv_results)
                    if capacity > 0.01
                        try
                            tech = PSIP.get_technology(PSIP.Technology, port, tech_name)
                            if !isnothing(tech)
                                cap_cost = PSIP.get_capital_costs(tech)
                                if !isnothing(cap_cost)
                                    # Capital cost in $/kW, capacity in MW
                                    try
                                        # LinearCurve stores slope in function_data.proportional_term ($/kW)
                                        unit_cost = cap_cost.function_data.proportional_term
                                        total_cost = unit_cost * capacity * 1000  # Convert MW to kW, result in $
                                        total_capital_cost += total_cost

                                        # Get recovery period for annualization
                                        fin_data = PSIP.get_financial_data(tech)
                                        recovery_period = 25  # default years
                                        if !isnothing(fin_data)
                                            try
                                                recovery_period = PSIP.get_capital_recovery_period(fin_data)
                                            catch
                                            end
                                        end

                                        # Simple annualization: total_cost / recovery_period
                                        annual_cost = total_cost / recovery_period
                                        println("  • $tech_name: \$$(round(total_cost, digits=0)) total (\$$(round(annual_cost, digits=0))/year over $recovery_period years)")
                                    catch e
                                        @debug "Error extracting capital cost for $tech_name: $e"
                                    end
                                end
                            end
                        catch
                        end
                    end
                end
                println("  Total capital cost (at completion): \$$(round(total_capital_cost, digits=0))")
                println("  Total annualized capital cost: \$$(round(total_capital_cost / 25, digits=0))/year")

                # Get reserve margin from portfolio metadata and peak demand from intervals
                try
                    reserve_margin = port.metadata.reserve_margin

                    # Get final peak demand from investment intervals (accounts for load arrivals)
                    port_id = objectid(port)
                    peak_load = case_base_peak_load_mw()
                    if haskey(_PORTFOLIO_INTERVAL_DATA, port_id)
                        interval_data = _PORTFOLIO_INTERVAL_DATA[port_id]
                        if !isempty(interval_data.peak_mws)
                            peak_load = interval_data.peak_mws[end]  # Final peak after all arrivals
                        end
                    end

                    required_capacity = peak_load * (1.0 + reserve_margin)
                    println("\nReserve Margin Analysis:")
                    println("  Planning reserve margin: $(round(reserve_margin * 100, digits=1))%")
                    println("  Peak demand (final period): $(round(peak_load, digits=1)) MW")
                    println("  Required capacity (with reserve): $(round(required_capacity, digits=1)) MW")

                    # Extract unmet reserve margin slack from results
                    try
                        jm = PSI2.get_jump_model(PSI2.get_optimization_container(res.model))
                        unmet_reserve = 0.0
                        for var in JuMP.all_variables(jm)
                            var_name = name(var)
                            if contains(var_name, "slack_reserve_margin")
                                unmet_reserve = JuMP.value(var)
                                break
                            end
                        end

                        actual_capacity = total_final_capacity
                        println("  Actual capacity (existing + new): $(round(actual_capacity, digits=1)) MW")

                        # Calculate reserve margin deficit directly from capacity vs requirement
                        margin_deficit = required_capacity - actual_capacity

                        # Try to extract slack variable (fallback to calculated deficit if not found)
                        if unmet_reserve <= 0.01 && margin_deficit > 0.01
                            unmet_reserve = margin_deficit
                        end

                        if unmet_reserve > 0.01 || margin_deficit > 0.01
                            actual_unmet = max(unmet_reserve, margin_deficit)
                            println("  ⚠ Unmet planning reserve margin: $(round(actual_unmet, digits=2)) MW")
                            println("    (Capacity shortfall: required $(round(required_capacity, digits=1)) MW, have $(round(actual_capacity, digits=1)) MW)")
                            println("    (Reserve margin constraint relaxed with \$100k/MW penalty)")
                        else
                            println("  ✓ Planning reserve margin satisfied")
                        end
                    catch e
                        @debug "Could not extract reserve margin slack: $e"
                    end
                catch
                end
            else
                println("Portfolio Structure:")
                techs = PSIP.get_technologies(PSIP.Technology, port)
                for tech in techs
                    name = PSIP.get_name(tech)
                    try
                        if tech isa PSIP.StorageTechnology
                            cap_lim = PSIP.get_capacity_limits_discharge(tech)
                            println("  - $name (discharge: $(cap_lim.max) MW)")
                        else
                            cap_lim = PSIP.get_capacity_limits(tech)
                            println("  - $name (max: $(cap_lim.max) MW)")
                        end
                    catch
                        println("  - $name")
                    end
                end
                println("\nOptimization Results: Problem solved but no investments found")
            end

            # Try to get objective value and cost breakdown from results
            t2 = _tier2_fuel_by_interval(res)
            if !isnothing(t2)
                println("\nDiesel Fuel (all thermal units, per investment interval):")
                println("  Limit: $(Int(t2.limit)) gal/yr, penalty: \$$(Int(t2.penalty))/gal above limit")
                for (i, (gal, sl)) in enumerate(zip(t2.gallons, t2.slack))
                    status = sl > 1e-6 ? "EXCEEDS by $(round(sl, digits=0)) gal" : "within limit"
                    println("  Interval $i: $(round(gal, digits=0)) gal/yr ($status)")
                end
                println("  Penalty cost: \$$(round(t2.penalty * sum(t2.slack), digits=0))/yr")
            end
            hours = _tier2_hours_by_interval(res)
            if !isnothing(hours)
                println("\nTier 2 Unit Operation (full-load equivalent hours/yr, per investment interval):")
                println("  Limit: $(Int(hours.limit)) h/yr per unit, penalty: \$$(hours.penalty)/MWh above limit")
                println("  " * rpad("Unit", 32) * join([lpad("Int $i", 10) for i in 1:hours.n_intervals]))
                for u in hours.units
                    cells = [lpad(string(round(Int, hours.hours[(u, i)])) * (hours.excess_mwh[(u, i)] > 1e-3 ? "*" : ""), 10)
                             for i in 1:hours.n_intervals]
                    println("  " * rpad("$u ($(round(hours.capacity[u], digits=2)) MW)", 32) * join(cells))
                end
                total_excess = sum(values(hours.excess_mwh))
                println("  * over the limit. Energy above limits: $(round(total_excess, digits=0)) MWh/yr, penalty cost: \$$(round(hours.penalty * total_excess, digits=0))/yr")
            end

            try
                container = PSI2.get_optimization_container(res.model)
                if !isnothing(container)
                    jump_model = PSI2.get_jump_model(container)
                    if !isnothing(jump_model)
                        obj_val = JuMP.objective_value(jump_model)
                        println("\nFinancial Summary:")
                        println("  Total annualized system cost: \$$(round(obj_val, digits=0))/year")

                        # Break down by cost type
                        # Capital costs = annualized investment costs
                        # Operating costs = fuel + O&M for generation
                        try
                            cap_cost_expr = PSI2.read_expression(res, PSI2.CapitalCost())
                            if !isempty(cap_cost_expr)
                                total_capital = sum(skipmissing(cap_cost_expr.value))
                                println("    ├─ Capital (annualized): \$$(round(total_capital, digits=0))/year")
                            end
                        catch
                        end

                        try
                            var_cost_expr = PSI2.read_expression(res, PSI2.VariableOMCost())
                            if !isempty(var_cost_expr)
                                total_var_om = sum(skipmissing(var_cost_expr.value))
                                println("    ├─ Variable O&M: \$$(round(total_var_om, digits=0))/year")
                            end
                        catch
                        end

                        try
                            fixed_cost_expr = PSI2.read_expression(res, PSI2.FixedOperationModelCost())
                            if !isempty(fixed_cost_expr)
                                total_fixed = sum(skipmissing(fixed_cost_expr.value))
                                println("    └─ Fixed O&M: \$$(round(total_fixed, digits=0))/year")
                            end
                        catch
                        end
                    end
                end
            catch
            end

            println("="^70 * "\n")
        catch e
            println("\n" * "="^70)
            println("Capacity Expansion: $(settings().title) (scenario: $scenario)")
            println("="^70 * "\n")
            println("Optimization completed but results extraction encountered an issue: $e")
            println("\nPortfolio Structure:")
            techs = PSIP.get_technologies(PSIP.Technology, port)
            for tech in techs
                name = PSIP.get_name(tech)
                try
                    if tech isa PSIP.StorageTechnology
                        cap_lim = PSIP.get_capacity_limits_discharge(tech)
                        println("  - $name (discharge: $(cap_lim.max) MW)")
                    else
                        cap_lim = PSIP.get_capacity_limits(tech)
                        println("  - $name (max: $(cap_lim.max) MW)")
                    end
                catch
                    println("  - $name")
                end
            end
            println("="^70 * "\n")
        end
    end
end
