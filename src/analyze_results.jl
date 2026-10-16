# src/analyze_results.jl
#
# Post-processing and analysis of production cost simulation results.
#
# Outputs:
#   - Annual generation mix table
#   - Renewable energy fraction
#   - Diesel fuel consumption and cost
#   - Capacity factor by generator
#   - Reservoir storage trajectory
#   - Wind curtailment
#   - Comparison against published benchmarks from the case settings

# ---------------------------------------------------------------------------
# Result loading
# ---------------------------------------------------------------------------

"""
    load_pcm_results(results_dir, sim_name) -> Dict

Load simulation results from disk and return a named dictionary of DataFrames.
Each DataFrame has one row per hour (8760 rows) and one column per component.

Values are in natural units (MW for power, MWh for energy, \$ for cost)
when the system was built with `set_units_base_system!(sys, "NATURAL_UNITS")`.
"""
function load_pcm_results(
    results_dir :: String = joinpath(pwd(), "results"),
    sim_name    :: String = default_pcm_sim_name(),
) :: Dict{Symbol,Any}

    sim_path = joinpath(results_dir, sim_name)
    @info "Loading results from: $sim_path"

    sim_results = PSI.SimulationResults(sim_path)
    uc_results  = PSI.get_decision_problem_results(sim_results, "UC")

    return read_pcm_results(uc_results)
end

"""
    read_pcm_results(uc_results) -> Dict

Read dispatch, commitment, solver statistics, storage, and transformer flows from
the UC decision-problem results of a PCM simulation.
"""
function read_pcm_results(uc_results) :: Dict{Symbol,Any}

    # Dispatch (MW)
    hydro_p = try
        PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.HydroTurbine)
    catch
        try
            # Fallback to HydroDispatch if HydroTurbine not available
            PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.HydroDispatch)
        catch
            DataFrame()  # empty if hydro not in formulation
        end
    end

    wind_p = try
        PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.RenewableDispatch)
    catch
        # If wind uses FixedOutput model, ActivePowerVariable won't be available
        # Try reading as parameter or return empty
        try
            PSI.read_realized_parameter(uc_results, "ActivePowerTimeSeriesParameter__RenewableDispatch")
        catch
            DataFrame()  # empty if wind not in formulation or not available as variable/parameter
        end
    end
    diesel_p   = PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable,    PSY.ThermalStandard)

    # Unit commitment decisions (binary)
    commitment = PSI.read_realized_variable(uc_results, PSI.OnVariable,             PSY.ThermalStandard)

    # Optimizer stats per solve (one row per daily UC problem)
    stats      = PSI.read_optimizer_stats(uc_results)

    # Battery dispatch (MW) and storage level (MWh)
    battery_discharge = try
        PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.EnergyReservoirStorage)
    catch
        DataFrame()
    end

    battery_soc = try
        PSI.read_realized_variable(uc_results, PSI.EnergyVariable, PSY.EnergyReservoirStorage)
    catch
        DataFrame()
    end

    # Transformer flows (MW)
    transformer_flows = try
        PSI.read_realized_variable(uc_results, PSI.FlowActivePowerVariable, PSY.Transformer2W)
    catch
        DataFrame()
    end

    # Extract system from SimulationResults
    sys = try
        PSI.get_system(uc_results)
    catch
        nothing
    end

    return Dict(
        :hydro_power  => hydro_p,
        :wind_power   => wind_p,
        :diesel_power => diesel_p,
        :commitment   => commitment,
        :solver_stats => stats,
        :battery_power => battery_discharge,
        :battery_soc   => battery_soc,
        :transformer_flows => transformer_flows,
        :system => sys,
    )
end

# ---------------------------------------------------------------------------
# Battery diagnostics
# ---------------------------------------------------------------------------

"""
    diagnose_battery_operation(results) -> Dict

Analyze battery dispatch and state of charge to diagnose why battery may not be operating.
"""
function diagnose_battery_operation(results :: Dict{Symbol,Any}) :: Dict{Symbol,Any}
    battery_power = results[:battery_power]
    battery_soc = results[:battery_soc]

    if isempty(battery_power)
        return Dict(
            :has_battery => false,
            :total_discharge => 0.0,
            :total_charge => 0.0,
            :max_discharge_mw => 0.0,
            :issue => "No battery in system",
        )
    end

    # Sum discharge (positive = discharging to grid)
    total_discharge = sum(col -> eltype(col) <: Number ? sum(max.(skipmissing(col), 0.0)) : 0.0, eachcol(battery_power))

    # Sum charge (negative = charging from grid)
    total_charge = sum(col -> eltype(col) <: Number ? sum(abs.(min.(skipmissing(col), 0.0))) : 0.0, eachcol(battery_power))

    # Max discharge in any single hour
    max_discharge = 0.0
    for col in eachcol(battery_power)
        if eltype(col) <: Number
            col_max = maximum(skipmissing(col))
            if !isnan(col_max)
                max_discharge = max(max_discharge, col_max)
            end
        end
    end

    # Identify issue
    issue = ""
    if total_discharge < 0.1
        issue = "Battery never discharges (no benefit to system operation)"
    elseif total_charge < 0.1
        issue = "Battery never charges (may be starting too high or system doesn't need storage)"
    else
        issue = "Battery is operating normally"
    end

    return Dict(
        :has_battery => true,
        :total_discharge_mwh => total_discharge,
        :total_charge_mwh => total_charge,
        :max_discharge_mw => max_discharge,
        :cycles => total_discharge > 0 ? total_charge / (total_discharge + 1e-6) : 0.0,
        :issue => issue,
    )
end

# ---------------------------------------------------------------------------
# Annual summary
# ---------------------------------------------------------------------------

"""
    compute_annual_summary(results, diesel_price) -> Dict

Compute key annual metrics from simulation results.
Returns a Dict with scalar and DataFrame values for reporting.
"""
function compute_annual_summary(results :: Dict{Symbol,Any}, diesel_price::Float64=case_default_diesel_price()) :: Dict{Symbol,Any}

    hydro_p  = results[:hydro_power]
    wind_p   = results[:wind_power]
    diesel_p = results[:diesel_power]
    stats    = results[:solver_stats]

    # Annual generation (MWh) — sum over all hours (1h resolution)
    # Filter to numeric columns only (skip timestamp and any string columns)
    hydro_mwh  = isempty(hydro_p) ? 0.0 : sum(col -> eltype(col) <: Number ? sum(skipmissing(col)) : 0.0, eachcol(hydro_p))
    wind_mwh   = sum(col -> eltype(col) <: Number ? sum(skipmissing(col)) : 0.0, eachcol(wind_p))
    diesel_mwh = sum(col -> eltype(col) <: Number ? sum(skipmissing(col)) : 0.0, eachcol(diesel_p))
    total_mwh  = hydro_mwh + wind_mwh + diesel_mwh

    # Renewable fraction (hydro + wind)
    re_mwh      = hydro_mwh + wind_mwh
    re_fraction = re_mwh / total_mwh

    # Annual production cost (\$)
    total_cost = sum(stats.objective_value)

    # Average cost per MWh
    avg_cost_per_mwh = total_cost / total_mwh

    # Per-generator capacity factors
    hydro_cf  = hydro_mwh  / (case_hydro_rating_mw() * 8760)
    wind_cf   = wind_mwh   / (case_wind_rating_mw()  * 8760)

    # Diesel fuel consumption (MBTU)
    # Approximate using the case default heat rate
    diesel_avg_hr  = settings().default_heat_rate   # MBTU/MWh
    diesel_mbtu    = diesel_mwh * diesel_avg_hr
    diesel_gallons = diesel_mbtu / case_fuel_hhv_mbtu_per_gal()
    diesel_cost    = diesel_gallons * diesel_price

    return Dict(
        :hydro_mwh        => hydro_mwh,
        :wind_mwh         => wind_mwh,
        :diesel_mwh       => diesel_mwh,
        :total_mwh        => total_mwh,
        :re_mwh           => re_mwh,
        :re_fraction      => re_fraction,
        :total_cost       => total_cost,
        :avg_cost_mwh     => avg_cost_per_mwh,
        :hydro_cf         => hydro_cf,
        :wind_cf          => wind_cf,
        :diesel_mbtu      => diesel_mbtu,
        :diesel_gallons   => diesel_gallons,
        :diesel_fuel_cost => diesel_cost,
        :diesel_price_per_gal => diesel_price,
    )
end

# ---------------------------------------------------------------------------
# Transformer overload analysis
# ---------------------------------------------------------------------------

"""
    analyze_transformer_overloads(sys, transformer_flows) -> Dict

Analyze transformer flows against their ratings and identify overloads.

Returns a Dict with:
  - :overloads :: Vector of dicts, each containing:
    - :name (transformer name)
    - :rating_mw (transformer rating)
    - :max_flow_mw (maximum observed flow)
    - :overload_pct (percentage over rating)
    - :overload_hours (number of hours with overload)
    - :total_hours (total hours in study)
"""
function analyze_transformer_overloads(
    sys :: PSY.System,
    transformer_flows :: DataFrame,
) :: Dict{Symbol,Any}

    if isempty(transformer_flows)
        @warn "No transformer flow data available for analysis"
        return Dict(
            :overloads => [],
            :total_transformers => 0,
            :overloaded_count => 0,
        )
    end

    overloads = []
    transformers = get_components(PSY.Transformer2W, sys)
    total_hours = nrow(transformer_flows)

    for xfmr in transformers
        xfmr_name = PSY.get_name(xfmr)
        xfmr_rating_mw = get_rating(xfmr)

        # Get flow data for this transformer if it exists
        if xfmr_name in names(transformer_flows)
            flows = transformer_flows[!, xfmr_name]

            # Calculate statistics on absolute values (transformers conduct current both ways)
            abs_flows = abs.(flows)
            max_flow_mw = maximum(abs_flows)
            overload_pct = (max_flow_mw / xfmr_rating_mw - 1.0) * 100.0

            # Count hours with overload (flow > rating)
            overload_hours = count(>(xfmr_rating_mw), abs_flows)

            # Only add if there's an actual overload
            if overload_pct > 0.1  # More than 0.1% over rating
                push!(overloads, Dict(
                    :name => xfmr_name,
                    :rating_mw => xfmr_rating_mw,
                    :max_flow_mw => max_flow_mw,
                    :overload_pct => overload_pct,
                    :overload_hours => overload_hours,
                    :total_hours => total_hours,
                    :avg_overload_pct => if overload_hours > 0
                        mean((abs_flows[abs_flows .> xfmr_rating_mw] ./ xfmr_rating_mw .- 1.0) .* 100.0)
                    else
                        0.0
                    end,
                ))
            end
        else
            @warn "Transformer $xfmr_name not found in flow results"
        end
    end

    # Sort by overload percentage (worst first)
    sort!(overloads; by=x -> x[:overload_pct], rev=true)

    return Dict(
        :overloads => overloads,
        :total_transformers => length(transformers),
        :overloaded_count => length(overloads),
    )
end

"""
    print_transformer_overload_report(analysis)

Print a formatted report of transformer overloads to console.
"""
function print_transformer_overload_report(analysis :: Dict{Symbol,Any})
    overloads = analysis[:overloads]
    total_xfmrs = analysis[:total_transformers]
    overloaded_count = analysis[:overloaded_count]

    sep = "=" ^ 80

    println("\n$sep")
    println("  TRANSFORMER OVERLOAD ANALYSIS")
    println(sep)

    if overloaded_count == 0
        println("\n  ✓ No transformer overloads detected")
        @printf "  All %d transformers operating within ratings\n" total_xfmrs
        println("\n$sep\n")
        return
    end

    println("\n  SUMMARY")
    println("  " * "-"^76)
    @printf "  Transformers analyzed:  %d\n" total_xfmrs
    @printf "  Transformers overloaded: %d (%.1f%%)\n" overloaded_count (100.0 * overloaded_count / total_xfmrs)

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

    println("\n$sep\n")
end

# ---------------------------------------------------------------------------
# Console report
# ---------------------------------------------------------------------------

"""
    print_annual_report(summary)

Print a formatted annual summary to the console, with a comparison to the
published values in the case's `[report.benchmarks]` when given.
"""
function print_annual_report(summary :: Dict{Symbol,Any})
    s = summary

    sep = "=" ^ 64

    println("\n$sep")
    println("  ANNUAL PRODUCTION COST SIMULATION")
    println("  $(settings().title) | Sienna (PowerSimulations.jl)")
    println(sep)

    println("\n  GENERATION MIX")
    println("  " * "-"^46)
    @printf "  %-26s %8.0f MWh  (%5.1f%%)\n" "Hydro:"                 s[:hydro_mwh]   100s[:hydro_mwh]/s[:total_mwh]
    @printf "  %-26s %8.0f MWh  (%5.1f%%)\n" "Wind:"                   s[:wind_mwh]    100s[:wind_mwh]/s[:total_mwh]
    @printf "  %-26s %8.0f MWh  (%5.1f%%)\n" "Diesel:"                 s[:diesel_mwh]  100s[:diesel_mwh]/s[:total_mwh]
    println("  " * "-"^46)
    @printf "  %-26s %8.0f MWh\n"             "Total served:"           s[:total_mwh]

    println("\n  RENEWABLE ENERGY")
    @printf "  Renewable generation:    %8.0f MWh  (%5.1f%%)\n" s[:re_mwh]  100s[:re_fraction]

    println("\n  CAPACITY FACTORS")
    @printf "  Hydro:                   %8.3f\n" s[:hydro_cf]
    @printf "  Wind:                    %8.3f\n" s[:wind_cf]

    println("\n  DIESEL FUEL & COST")
    @printf "  Diesel generation:       %8.0f MWh/year\n"   s[:diesel_mwh]
    @printf "  Fuel consumption:        %8.0f MBTU/year\n"  s[:diesel_mbtu]
    @printf "  Fuel volume:             %8.0f gallons/year\n" s[:diesel_gallons]
    @printf "  Estimated fuel cost:     \$%7.0f/year  (@ \$%.2f/gal)\n" s[:diesel_fuel_cost] s[:diesel_price_per_gal]

    println("\n  PRODUCTION COST")
    @printf "  Total annual cost:       \$%7.0f\n"           s[:total_cost]
    @printf "  Average cost:            \$%7.2f/MWh\n"       s[:avg_cost_mwh]
    println("  (Includes variable fuel, fixed O&M, and start-up costs)")

    b = settings().report_benchmarks
    if !isnothing(b)
        println("\n  BENCHMARK COMPARISON ($(b.source))")
        @printf "  %-26s %8s  vs simulated %8.0f MWh\n" "Hydro generation:" b.hydro_mwh s[:hydro_mwh]
        @printf "  %-26s %8s  vs simulated %8.0f MWh\n" "Wind generation:"  b.wind_mwh  s[:wind_mwh]
        @printf "  %-26s %8s%%  vs simulated %8.1f%%\n"  "Renewable share:"  b.renewable_share_pct 100s[:re_fraction]
    end

    println("\n$sep\n")
end

# ---------------------------------------------------------------------------
# Monthly breakdown
# ---------------------------------------------------------------------------

"""
    monthly_generation_table(results) -> DataFrame

Return a DataFrame with monthly generation totals (MWh) by fuel type.
Useful for comparing against EIA Form 923 monthly data.
"""
function monthly_generation_table(::Dict{Symbol,Any}) :: DataFrame
    # TODO: Implement monthly breakdown (requires proper timestamp handling)
    # For now, return empty DataFrame
    return DataFrame()
end

# ---------------------------------------------------------------------------
# Main analysis entry point
# ---------------------------------------------------------------------------

"""
    compare_pcm_costs(results_without, results_with; scenario_labels) -> Dict

Compare production costs between two PCM scenarios (e.g., with/without battery).

Arguments:
  results_without: PCM results dict for baseline scenario (e.g., no battery)
  results_with:    PCM results dict for comparison scenario (e.g., with battery)
  scenario_labels: Dict with :without and :with keys for display names

Returns:
  Dict with cost metrics and comparison results
"""
function compare_pcm_costs(
    results_without :: Union{Dict{Symbol,Any}, Dict{String,Any}},
    results_with    :: Union{Dict{Symbol,Any}, Dict{String,Any}};
    scenario_labels :: Dict{Symbol,String} = Dict(:without => "Without Battery", :with => "With Battery"),
    diesel_price :: Float64 = case_default_diesel_price(),
) :: Dict{Symbol,Any}

    # Handle both Symbol and String keys
    get_key(d::Dict, k::Symbol) = get(d, k, get(d, String(k), nothing))

    # Extract costs from solver stats
    cost_without = sum(get_key(results_without, :solver_stats).objective_value)
    cost_with    = sum(get_key(results_with, :solver_stats).objective_value)

    # Compute difference and percentage change
    cost_delta      = cost_with - cost_without
    cost_pct_change = (cost_delta / cost_without) * 100.0

    # Extract energy metrics
    summary_without = compute_annual_summary(results_without, diesel_price)
    summary_with    = compute_annual_summary(results_with, diesel_price)

    diesel_delta = get_key(summary_with, :diesel_mwh) - get_key(summary_without, :diesel_mwh)
    renewable_delta = get_key(summary_with, :re_fraction) - get_key(summary_without, :re_fraction)

    # Print comparison report
    sep = "=" ^ 64

    println("\n$sep")
    println("  PRODUCTION COST COMPARISON: BATTERY SCENARIOS")
    println(sep)

    println("\n  ANNUAL PRODUCTION COST")
    println("  " * "-"^46)
    @printf "  %-26s \$%10.0f\n" scenario_labels[:without] cost_without
    @printf "  %-26s \$%10.0f\n" scenario_labels[:with]    cost_with
    println("  " * "-"^46)
    if cost_delta < 0
        @printf "  %-26s \$%10.0f  (savings %.1f%%)\n" "Cost reduction:" abs(cost_delta) abs(cost_pct_change)
    else
        @printf "  %-26s \$%10.0f  (increase %.1f%%)\n" "Cost increase:" cost_delta cost_pct_change
    end

    println("\n  GENERATION IMPACTS")
    println("  " * "-"^46)
    @printf "  %-26s %8.0f → %8.0f MWh (Δ %+.0f)\n" "Diesel generation:" get_key(summary_without, :diesel_mwh) get_key(summary_with, :diesel_mwh) diesel_delta
    @printf "  %-26s %8.1f%% → %8.1f%% (Δ %+.1f pp)\n" "Renewable fraction:" 100*get_key(summary_without, :re_fraction) 100*get_key(summary_with, :re_fraction) 100*renewable_delta

    println("\n  BATTERY OPERATION (WITH-BATTERY SCENARIO)")
    println("  " * "-"^46)
    battery_diag = diagnose_battery_operation(results_with)
    if battery_diag[:has_battery]
        @printf "  Total discharge:     %8.1f MWh\n" battery_diag[:total_discharge_mwh]
        @printf "  Total charge:        %8.1f MWh\n" battery_diag[:total_charge_mwh]
        @printf "  Max power:           %8.1f MW\n"  battery_diag[:max_discharge_mw]
        @printf "  Charge/discharge:    %8.2f (ratio)\n" battery_diag[:cycles]
        println("  Status: " * battery_diag[:issue])
    else
        println("  ⚠ No battery found in with-battery scenario")
    end

    println("\n  ANNUAL COST SUMMARY")
    println("  " * "-"^46)
    @printf "  %-26s \$%10.2f/MWh\n" "Avg cost (without):" get_key(summary_without, :avg_cost_mwh)
    @printf "  %-26s \$%10.2f/MWh\n" "Avg cost (with):"    get_key(summary_with, :avg_cost_mwh)
    println("\n$sep\n")

    return Dict(
        :cost_without       => cost_without,
        :cost_with          => cost_with,
        :cost_delta         => cost_delta,
        :cost_pct_change    => cost_pct_change,
        :diesel_delta       => diesel_delta,
        :renewable_delta    => renewable_delta,
        :summary_without    => summary_without,
        :summary_with       => summary_with,
    )
end

# ---------------------------------------------------------------------------
# Main analysis entry point
# ---------------------------------------------------------------------------

"""
    analyze_results(pcm_results::Dict; diesel_price) -> Dict
    analyze_results(; results_dir, sim_name, system, diesel_price) -> Dict

Load results, compute metrics, print report, and return result dict.

Can be called with:
  pcm_results: Dict from run_validation_workflow containing system and simulation
  results_dir: Results directory path
  sim_name: Simulation results name
  system: Optional PowerSystems.System object
  diesel_price: Diesel fuel price in dollars per gallon
"""
function write_pcm_summary(results::Dict, path::AbstractString)
    keys_to_write = (:total_cost, :hydro_mwh, :wind_mwh, :diesel_mwh, :total_mwh, :diesel_gallons)
    summary = Dict(String(k) => results[k] for k in keys_to_write)
    mkpath(dirname(path))
    open(io -> JSON.print(io, summary, 2), path, "w")
    return path
end

function analyze_results(pcm_results::Dict; diesel_price::Float64=case_default_diesel_price()) :: Dict{Symbol,Any}
    # Extract components from pcm_results dict
    sim = get(pcm_results, "simulation", nothing)
    sys = get(pcm_results, "system", nothing)
    results_dir = get(pcm_results, "results_dir", joinpath(pwd(), "results"))

    if isnothing(sim)
        error("pcm_results dict missing 'simulation' key")
    end

    # Load results from simulation
    sim_path = results_dir
    if !isdir(sim_path)
        error("Results directory not found: $sim_path")
    end

    sim_results = PSI.SimulationResults(sim)
    uc_results = PSI.get_decision_problem_results(sim_results, "UC")

    results = read_pcm_results(uc_results)
    isnothing(sys) || (results[:system] = sys)

    # Compute and report
    summary = compute_annual_summary(results, diesel_price)
    print_annual_report(summary)

    # Transformer analysis
    if !isnothing(sys)
        try
            transformer_analysis = analyze_transformer_overloads(sys, results[:transformer_flows])
            print_transformer_overload_report(transformer_analysis)
            results = merge(results, Dict(:transformer_analysis => transformer_analysis))
        catch e
            @debug "Could not analyze transformers: $e"
        end
    end

    monthly = monthly_generation_table(results)
    println("  Monthly generation (MWh):")
    show(stdout, monthly, allrows=true)
    println()

    return merge(results, summary, Dict(:monthly => monthly))
end

function analyze_results(;
    results_dir :: String = joinpath(pwd(), "results"),
    sim_name    :: String = default_pcm_sim_name(),
    system      :: Union{PSY.System, Nothing} = nothing,
    diesel_price :: Float64 = case_default_diesel_price(),
) :: Dict{Symbol,Any}

    results = load_pcm_results(results_dir, sim_name)
    summary = compute_annual_summary(results, diesel_price)
    print_annual_report(summary)

    # Analyze transformer overloads if system is available
    sys = system
    if isnothing(sys)
        # Try to get system from results first
        sys = get(results, :system, nothing)
    end
    if isnothing(sys)
        # Fallback to loading from JSON if not in results
        sys_json = case_system_json_path()
        if isfile(sys_json)
            try
                sys = PSY.System(sys_json)
            catch e
                @debug "Could not load system from JSON: $e"
            end
        end
    end

    if !isnothing(sys)
        try
            transformer_analysis = analyze_transformer_overloads(sys, results[:transformer_flows])
            print_transformer_overload_report(transformer_analysis)
            results = merge(results, Dict(:transformer_analysis => transformer_analysis))
        catch e
            @debug "Could not analyze transformers: $e"
        end
    end

    monthly = monthly_generation_table(results)
    println("  Monthly generation (MWh):")
    show(stdout, monthly, allrows=true)
    println()

    return merge(results, summary, Dict(:monthly => monthly))
end
