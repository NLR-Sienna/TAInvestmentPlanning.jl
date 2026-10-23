# Command-line workflows: PCM, CEM, CEM → PCM validation, battery comparison, and uncertainty.
#
# Usage (from a driver script that calls TAInvestmentPlanning.main(ARGS)):
#   pcm          Production cost simulation of the base system
#   cem          Capacity expansion model only
#   validate     CEM + post-investment PCM (default)
#   battery      CEM → PCM (no battery) → PCM (with battery)
#   uncertainty  CEM for every load arrival scenario
#
# Scenario inputs (--arrivals, --procurement-timelines, --exogenous-builds) are JSON files or
# JSON strings. Without --arrivals or --procurement-timelines the case defaults are used.

function _arg_settings()
    s = ArgParseSettings(description = "Capacity expansion and production cost workflows")

    @add_arg_table! s begin
        "mode"
            help = "Workflow: pcm, cem, validate, battery, or uncertainty"
            arg_type = String
            default = "validate"

        "--case"
            help = "Case directory containing case.toml and case.jl"
            default = ""
            arg_type = String

        "--arrivals"
            help = "JSON file or string with load arrival scenarios: {\"scenario_name\": [{\"year\": 2027, \"mw\": 1.0, \"conforming\": true, \"bus\": \"Bus_Name\"}, ...], ...} (default: the case's arrivals file)"
            default = ""
            arg_type = String

        "--scenario"
            help = "Load arrival scenario to run (default: the case's default scenario, or the only scenario in the arrivals input)"
            default = ""
            arg_type = String

        "--cem-results"
            help = "Path to prior CEM results JSON (skip CEM re-run)"
            default = ""
            arg_type = String

        "--test"
            help = "PCM: Single-day test solve (day 180)"
            action = :store_true

        "--day-start"
            help = "Start day for simulation (default: 1)"
            default = 1
            arg_type = Int

        "--day-end"
            help = "End day for simulation (default: 365)"
            default = 365
            arg_type = Int

        "--analyze-only"
            help = "PCM: Skip simulation, analyze existing results"
            action = :store_true

        "--mip-gap"
            help = "MILP optimality gap (default: 0.05 = 5%)"
            default = 0.05
            arg_type = Float64

        "--solver-time-limit"
            help = "CEM solver time limit in seconds (default: [solver] time_limit_s in case.toml)"
            arg_type = Float64

        "--solver"
            help = "MILP solver for the CEM and PCM: highs or xpress (needs Xpress.jl in the environment and an Xpress license)"
            default = "highs"
            arg_type = String

        "--run-name"
            help = "Name for this run's result folders and summaries (default: the load scenario name)"
            default = ""
            arg_type = String

        "--horizon-end"
            help = "Last planning year (default: the last load arrival year); exogenous build years start their own periods"
            arg_type = Int

        "--copper-plate"
            help = "PCM: Use CopperPlate model (faster, no transmission) instead of NFAPowerModel"
            action = :store_true

        "--battery-sizes"
            help = "Battery comparison: comma-separated MW sizes to test (default: 1,2,3,4)"
            default = "1,2,3,4"
            arg_type = String

        "--diesel-price"
            help = "Diesel fuel price in \$/gallon (default: the case's diesel price)"
            arg_type = Float64

        "--procurement-timelines"
            help = "JSON file or string with procurement timelines: {\"Tech_Name\": [start_year, end_year], ...}"
            default = ""
            arg_type = String

        "--nodal-cem"
            help = "Use the nodal network in the CEM (default: copper-plate)"
            action = :store_true

        "--disable-fuel-cap"
            help = "Disable the system diesel fuel cap in the CEM (limit and penalty are set in case.toml)"
            action = :store_true

        "--disable-tier2-hours"
            help = "Disable the per-unit Tier 2 operating hours limit in the CEM (set in case.toml)"
            action = :store_true

        "--exogenous-builds"
            help = "JSON file or string with fixed builds in MW per year: {\"Tech_Name\": {\"2030\": 4.0}, ...} (0 = do not build)"
            default = ""
            arg_type = String

        "--enable-nodal-slack"
            help = "Enable power balance slack variables (default: true)"
            action = :store_true
            default = true

        "--disable-nodal-slack"
            help = "Disable power balance slack variables"
            action = :store_false
            dest_name = "enable-nodal-slack"

        "--enable-energy-slack"
            help = "Enable energy feasibility slack variables (default: true)"
            action = :store_true
            default = true

        "--disable-energy-slack"
            help = "Disable energy feasibility slack variables"
            action = :store_false
            dest_name = "enable-energy-slack"

        "--enable-reserve-slack"
            help = "Enable reserve margin slack variables (default: true)"
            action = :store_true
            default = true

        "--disable-reserve-slack"
            help = "Disable reserve margin slack variables"
            action = :store_false
            dest_name = "enable-reserve-slack"
    end
    return s
end

"""
    parse_cmdline(args = ARGS) -> Dict{String, Any}

Parse workflow arguments. In the REPL, build the argument Dict for a workflow with e.g.
`run_cem_workflow(parse_cmdline(["cem", "--scenario=moderate"]))`.
"""
parse_cmdline(args::AbstractVector{<:AbstractString} = ARGS) = parse_args(collect(String, args), _arg_settings())

_diesel_price(args) = something(get(args, "diesel-price", nothing), case_default_diesel_price())
_solver_time_limit(args) = Float64(something(get(args, "solver-time-limit", nothing), settings().time_limit_s))

# Name for result folders and summaries: --run-name, else the load scenario name
function _run_label(args, scenario_name)
    name = get(args, "run-name", "")
    return isnothing(name) || isempty(name) ? scenario_name : name
end

_horizon_end(args, arrivals) =
    something(get(args, "horizon-end", nothing), maximum(a.year for a in arrivals; init = settings().base_year))

# Check exogenous builds against the case before building anything: known candidate, build year in
# the planning horizon and in the candidate's procurement window, whole units for diesel and wind, and
# at most max_units units of a diesel or battery candidate in all (repeated entries add up).
function _check_exogenous_builds(builds, procurement_timelines, horizon_end::Int)
    isnothing(builds) && return
    problems = String[]
    catalog = settings().catalog
    timelines = something(procurement_timelines, default_procurement_timelines())
    units_built = Dict{String, Float64}()  # diesel or battery candidate => units built in all
    for (tech, year_mw) in builds, year in sort(collect(keys(year_mw)))
        mw = year_mw[year]
        if !haskey(catalog, tech)
            push!(problems, "$tech is not a candidate technology")
            continue
        end
        settings().base_year <= year <= horizon_end ||
            push!(problems, "$tech $year is outside the planning horizon $(settings().base_year)-$horizon_end (set --horizon-end)")
        mw > 1e-6 || continue
        entry = catalog[tech]
        candidate = get(entry, :base_name, tech)
        first_year, last_year = get(timelines, tech, get(timelines, candidate, (typemin(Int), typemax(Int))))
        first_year <= year <= last_year ||
            push!(problems, "$tech $year is outside its procurement window $first_year-$last_year")
        if entry.kind == "Battery"
            units_built[candidate] = get(units_built, candidate, 0.0) + mw / entry.power_mw
        elseif entry.kind in ("Diesel", "Wind") && !(any(a -> a.name == tech, settings().planned_additions))
            n = mw / entry.capacity_mw
            if abs(n - round(n)) > 1e-6 || (entry.kind == "Wind" && round(n) > 1)
                push!(problems, "$tech $year builds $mw MW; a build is " *
                    (entry.kind == "Wind" ? "one $(entry.capacity_mw) MW unit (or 0)" : "a whole number of $(entry.capacity_mw) MW units"))
            elseif entry.kind == "Diesel"
                units_built[candidate] = get(units_built, candidate, 0.0) + round(n)
            end
        end
    end
    for (candidate, n) in units_built
        entry = catalog[candidate]
        n <= entry.max_units + 1e-6 || push!(problems, entry.kind == "Battery" ?
            "$candidate builds $(n * entry.power_mw) MW in all; at most $(entry.max_units) x $(entry.power_mw) MW (max_units = $(entry.max_units))" :
            "$candidate builds $(Int(n)) units; max_units is $(entry.max_units)")
    end
    isempty(problems) || error("Exogenous builds do not fit the case:\n  " * join(problems, "\n  "))
    return
end

function _apply_solver_arg!(args)
    solver = set_solver!(get(args, "solver", "highs"))
    println("Solver: $solver")
    return solver
end

function _apply_slack_args!(args)
    set_slack_options!(;
        nodal = get(args, "enable-nodal-slack", true),
        energy = get(args, "enable-energy-slack", true),
        reserve = get(args, "enable-reserve-slack", true),
    )
end

# Returns (scenario_name, all_scenarios, arrivals). Without --scenario: the case default scenario
# if the arrivals input has it, else the only scenario in the input.
function _select_arrivals(args)
    all_scenarios = parse_arrivals_scenarios(get(args, "arrivals", ""))
    scenario_name = get(args, "scenario", "")
    if isempty(scenario_name)
        if haskey(all_scenarios, settings().default_scenario)
            scenario_name = settings().default_scenario
        elseif length(all_scenarios) == 1
            scenario_name = only(keys(all_scenarios))
        else
            error("Choose a scenario with --scenario. Available scenarios: $(join(sort(collect(keys(all_scenarios))), ", "))")
        end
    end
    return scenario_name, all_scenarios, get_arrivals_for_scenario(all_scenarios, scenario_name)
end

function _print_arrivals(scenario_name, all_scenarios, arrivals)
    println("Load scenario: $scenario_name")
    println("Available scenarios: $(join(sort(collect(keys(all_scenarios))), ", "))")
    println("Load arrivals:")
    cumulative = case_base_peak_load_mw()
    for arr in arrivals
        cumulative += arr.mw
        conforming_str = arr.conforming ? "conforming" : "flat"
        if arr.custom_profile_path !== nothing
            println("  $(arr.year): +$(arr.mw) MW ($conforming_str) at $(arr.bus) at: ($(arr.custom_profile_path)) → $(cumulative) MW peak")
        else
            println("  $(arr.year): +$(arr.mw) MW ($conforming_str) at $(arr.bus) → $(cumulative) MW peak")
        end
    end
    println()
end

function _print_procurement_timelines(procurement_timelines)
    isnothing(procurement_timelines) && return
    println("Custom procurement timelines provided:")
    for (tech, (start_yr, end_yr)) in procurement_timelines
        println("  $tech: $(start_yr)-$(end_yr)")
    end
    println()
end

function _build_portfolio(arrivals, procurement_timelines, diesel_price; verbose::Bool = true,
                          horizon_end = nothing, exogenous_builds = nothing)
    extra_years = isnothing(exogenous_builds) ? Int[] :
        [year for year_mw in values(exogenous_builds) for (year, mw) in year_mw if mw > 1e-6]
    if isnothing(procurement_timelines)
        return build_planning_portfolio(arrivals; verbose = verbose, diesel_price = diesel_price,
                                        horizon_end = horizon_end, extra_years = extra_years)
    end
    return build_planning_portfolio(arrivals; verbose = verbose, procurement_timelines = procurement_timelines,
                                    diesel_price = diesel_price, horizon_end = horizon_end, extra_years = extra_years)
end

# ============================================================================
# Production Cost Simulation (PCM) Workflow
# ============================================================================

function run_pcm_workflow(args::Dict{String, Any})
    println("\n" * "="^70)
    println("PRODUCTION COST SIMULATION (Base System)")
    println("="^70 * "\n")

    _apply_solver_arg!(args)
    TEST_MODE = args["test"]
    SKIP_SIM = args["analyze-only"]
    MIP_GAP = args["mip-gap"]
    DIESEL_PRICE = _diesel_price(args)

    # Parse day range from arguments
    day_start = args["day-start"]
    day_end = args["day-end"]

    RESULTS_DIR = joinpath(pwd(), "results")
    SIM_NAME = default_pcm_sim_name()
    SYS_JSON = case_system_json_path()
    pcm_results = nothing

    if TEST_MODE
        println("Mode: SINGLE-DAY TEST (day 180 of 364)\n")
    elseif SKIP_SIM
        println("Mode: ANALYZE EXISTING RESULTS\n")
    else
        if day_start > 1 || day_end < 365
            println("Mode: PARTIAL WINDOW SIMULATION (days $(day_start)-$(day_end))\n")
        else
            println("Mode: FULL ANNUAL SIMULATION (364 days)\n")
        end
    end

    # Build or reload system
    if SKIP_SIM && isfile(SYS_JSON)
        @info "Reloading system from $SYS_JSON..."
        sys = PSY.System(SYS_JSON)
    else
        sys, _ = build_case_system(; verbose = true, diesel_price = DIESEL_PRICE)
        PSY.to_json(sys, SYS_JSON, force = true)
        @info "System saved → $SYS_JSON"
    end

    # Transform time series to match 48-hour horizon with 24-hour steps.
    PSY.transform_single_time_series!(sys, Hour(48), Hour(24))

    thermal = collect(PSY.get_components(PSY.ThermalStandard, sys))
    thermal_mw = PSY.with_units_base(sys, PSY.UnitSystem.NATURAL_UNITS) do
        sum(PSY.get_max_active_power, thermal; init = 0.0)
    end
    println("\n" * "="^70)
    println("System Summary:")
    println("="^70)
    @info "Generators: $(length(collect(PSY.get_components(PSY.Generator, sys))))"
    @info "Hydro:   $(case_hydro_rating_mw()) MW"
    @info "Wind:    $(case_wind_rating_mw()) MW"
    @info "Thermal: $(round(thermal_mw, digits = 1)) MW ($(length(thermal)) units)"
    @info "Load:    $(case_base_peak_load_mw()) MW peak"
    println("="^70 * "\n")

    # Run simulation or test
    if !SKIP_SIM
        if TEST_MODE
            println("Running single-day test solve (day 180)...")
            run_single_day_test(sys; day_of_year = 180)
            @info "Test complete. Results: results/test_day180/"
        else
            use_copper_plate = args["copper-plate"]
            network_model = use_copper_plate ? "CopperPlate (single aggregated bus)" : "NFAPowerModel (nodal network)"
            if day_start > 1 || day_end < 365
                println("Building and running partial window simulation (days $(day_start)-$(day_end))...")
            else
                println("Building and running annual simulation...")
            end
            println("Network model: $network_model\n")
            sim = build_pcm_simulation(
                sys;
                results_dir = RESULTS_DIR,
                sim_name = SIM_NAME,
                mip_gap = MIP_GAP,
                copper_plate = use_copper_plate,
                day_start = day_start,
                day_end = day_end,
            )
            run_simulation!(sim)

            # Report PCM results using standard reporting format
            pcm_results = Dict(
                "system" => sys,
                "simulation" => sim,
                "scenario" => :existing,
                "results_dir" => joinpath(RESULTS_DIR, SIM_NAME),
            )
            report_pcm_results(pcm_results)

            # Generate plots
            println("\nGenerating plots...")
            plot_dir = joinpath(RESULTS_DIR, "plots")
            plot_pcm_results(pcm_results; output_dir = plot_dir)

            # Also generate monthly summary CSV
            println("\nGenerating monthly summary...")
            all_results = analyze_results(; results_dir = RESULTS_DIR, sim_name = SIM_NAME, system = sys, diesel_price = DIESEL_PRICE)
            monthly_csv = joinpath(RESULTS_DIR, "monthly_generation.csv")
            CSV.write(monthly_csv, all_results[:monthly])
            @info "Monthly generation table → $monthly_csv"
        end
    end

    if TEST_MODE
        return
    end

    # Analyze results (if skipping simulation, just analyze existing)
    if SKIP_SIM
        println("\nAnalyzing existing results...")
        all_results = analyze_results(; results_dir = RESULTS_DIR, sim_name = SIM_NAME, diesel_price = DIESEL_PRICE)
        monthly_csv = joinpath(RESULTS_DIR, "monthly_generation.csv")
        CSV.write(monthly_csv, all_results[:monthly])
        @info "Monthly generation table → $monthly_csv"
    end

    println("\n✓ PCM workflow complete\n")
    return pcm_results
end

# ============================================================================
# Capacity Expansion Model (CEM) Workflow
# ============================================================================

function run_cem_workflow(args::Dict{String, Any})
    println("\n" * "="^70)
    println("CAPACITY EXPANSION MODEL (Multi-Period Planning Optimization)")
    println("="^70 * "\n")

    _apply_solver_arg!(args)
    slacks = _apply_slack_args!(args)
    diesel_price = _diesel_price(args)

    println("Diesel price: \$$(diesel_price)/gal")
    println()
    println("Slack Configuration:")
    println("  Nodal power balance slack: $(slacks.nodal)")
    println("  Energy feasibility slack: $(slacks.energy)")
    println("  Reserve margin slack: $(slacks.reserve)")
    println()

    scenario_name, all_scenarios, arrivals = _select_arrivals(args)
    label = _run_label(args, scenario_name)
    _print_arrivals(scenario_name, all_scenarios, arrivals)

    procurement_timelines = parse_procurement_timelines(args["procurement-timelines"])
    _print_procurement_timelines(procurement_timelines)
    horizon_end = _horizon_end(args, arrivals)
    exogenous_builds = parse_exogenous_builds(args["exogenous-builds"])
    _check_exogenous_builds(exogenous_builds, procurement_timelines, horizon_end)

    println("Building multi-period nodal portfolio...")
    port = _build_portfolio(arrivals, procurement_timelines, diesel_price;
                            horizon_end = horizon_end, exogenous_builds = exogenous_builds)

    println("\nSolving capacity expansion optimization...")
    println("(This may take 60-180 seconds for multi-period co-optimization...)\n")
    results_dir = joinpath("results", "planning", label)
    res = solve_planning(port; results_dir = results_dir, day_start = args["day-start"], day_end = args["day-end"],
                         mip_gap = args["mip-gap"], solver_time_limit = _solver_time_limit(args),
                         exogenous_builds = exogenous_builds,
                         fuel_cap = !args["disable-fuel-cap"],
                         tier2_hours = !get(args, "disable-tier2-hours", false), copper_plate = !args["nodal-cem"])

    println("\nReporting investment results...")
    report_planning_results(res, port)
    _write_planning_summary(res, port, joinpath(results_dir, "summary.json"))

    println("="^70)
    println("✓ CEM multi-period optimization complete")
    println("Results saved to: $results_dir/")
    println("="^70 * "\n")
    return res
end

# ============================================================================
# Battery Comparison Workflow: CEM → PCM (no battery) → PCM (with battery)
# ============================================================================

function run_battery_comparison_workflow(args::Dict{String, Any})
    println("\n" * "="^70)
    println("BATTERY COMPARISON: CEM → PCM (baseline) → PCM (multiple battery sizes)")
    println("="^70 * "\n")

    _apply_solver_arg!(args)
    _apply_slack_args!(args)
    mip_gap = args["mip-gap"]
    diesel_price = _diesel_price(args)
    scenario_name, all_scenarios, arrivals = _select_arrivals(args)

    println("Scenario: $scenario_name")
    println("PCM Optimality Gap: $(mip_gap*100)%")
    println("Diesel Price: \$$(diesel_price)/gal\n")

    # Parse battery sizes from argument (default: 1,2,3,4 MW)
    battery_sizes_str = get(args, "battery-sizes", "1,2,3,4")
    battery_sizes = parse.(Float64, split(battery_sizes_str, ","))
    println("Battery sizes to test: $(join(battery_sizes, ", ")) MW\n")

    # Step 1: Run CEM to get post-investment system
    @info "Step 1: Running CEM to determine optimal investments..."
    _print_arrivals(scenario_name, all_scenarios, arrivals)

    portfolio = build_planning_portfolio(arrivals; verbose = true, diesel_price = diesel_price)
    cem_results_obj = solve_planning(portfolio;
                                     results_dir = joinpath("results", "planning", scenario_name),
                                     day_start = args["day-start"], day_end = args["day-end"], mip_gap = mip_gap,
                                     solver_time_limit = _solver_time_limit(args))
    inv_results = _extract_investment_results(cem_results_obj)
    println("Investment results: $inv_results")
    println("\nReporting investment results...")
    report_planning_results(cem_results_obj, portfolio)

    if isempty(inv_results)
        println("\n⚠ No investments found in CEM results. Skipping battery comparison.")
        println("="^70 * "\n")
        return
    end

    println("\nCEM Results:")
    for (tech_name, cap) in sort(inv_results)
        if cap > 0.1
            println("  ✓ $tech_name: $(round(cap, digits=2)) MW")
        end
    end

    # Step 2: Build post-investment system and run PCM without battery (baseline)
    use_copper_plate = args["copper-plate"]
    network_model = use_copper_plate ? "CopperPlate (fast)" : "NFAPowerModel (detailed)"

    @info "\nStep 2: Running baseline PCM on post-investment system (NO battery) [$network_model]..."
    sys_no_battery = build_post_investment_system(inv_results; arrivals = arrivals, diesel_price = diesel_price)
    PSY.transform_single_time_series!(sys_no_battery, Hour(48), Hour(24))

    # Create sim_name with diesel price
    diesel_price_str = replace(string(round(diesel_price; digits=2)), "." => "_")
    baseline_sim_name = "no_battery_diesel$(diesel_price_str)"
    comparison_dir = joinpath("results", "battery_comparison")

    sim_no_battery = build_pcm_simulation(
        sys_no_battery;
        results_dir = comparison_dir,
        sim_name = baseline_sim_name,
        mip_gap = mip_gap,
        copper_plate = use_copper_plate,
    )
    run_simulation!(sim_no_battery)

    pcm_results_no_battery = Dict(
        "system" => sys_no_battery,
        "simulation" => sim_no_battery,
        "scenario" => :no_battery,
        "results_dir" => joinpath(comparison_dir, baseline_sim_name),
    )

    # Generate comparison plots
    println("\n" * "="^70)
    println("Generating comparison plots...")
    println("="^70)
    plot_dir = joinpath(comparison_dir, "no_battery", "plots")
    plot_pcm_results(pcm_results_no_battery; output_dir = plot_dir)

    all_results = analyze_results(; results_dir = comparison_dir, sim_name = baseline_sim_name, system = sys_no_battery, diesel_price = diesel_price)
    monthly_csv = joinpath(comparison_dir, baseline_sim_name, "monthly_generation.csv")
    CSV.write(monthly_csv, all_results[:monthly])
    @info "Monthly generation table → $monthly_csv"

    @info "PCM (no battery) complete"

    # Step 3: Run PCM for each battery size
    battery_bus = settings().pcm.default_bus
    battery_results = Dict()
    for battery_mw in battery_sizes
        @info "\nStep 3: Running PCM with $battery_mw MW battery [$network_model]..."
        sys_with_battery = build_post_investment_system(inv_results; arrivals = arrivals, diesel_price = diesel_price)

        if battery_mw > 0.0
            # Add a 4-hour battery at the case's default PCM bus
            battery_duration = 4.0
            battery_energy_mwh = battery_mw * battery_duration
            println("Adding battery: $battery_mw MW / $battery_energy_mwh MWh (4 hours) at $battery_bus")
            battery = add_battery_to_system!(sys_with_battery, battery_bus, battery_mw, battery_duration;
                                             battery_name = "Battery_$(Int(battery_mw))MW")
            if isnothing(battery)
                @warn "Failed to add $battery_mw MW battery; skipping"
                continue
            end
        else
            println("No battery configuration (baseline for comparison)")
        end

        PSY.transform_single_time_series!(sys_with_battery, Hour(48), Hour(24))

        sim_name = battery_mw == 0.0 ? "battery_0mw_diesel$(diesel_price_str)" : "battery_$(Int(battery_mw))mw_diesel$(diesel_price_str)"
        sim_with_battery = build_pcm_simulation(
            sys_with_battery;
            results_dir = comparison_dir,
            sim_name = sim_name,
            mip_gap = mip_gap,
            copper_plate = use_copper_plate,
        )
        run_simulation!(sim_with_battery)

        battery_results[battery_mw] = Dict(
            "system" => sys_with_battery,
            "simulation" => sim_with_battery,
            "scenario" => Symbol("battery_$(battery_mw)mw"),
            "results_dir" => joinpath(comparison_dir, sim_name),
        )

        # Generate comparison plots
        println("\n" * "="^70)
        println("Generating comparison plots...")
        println("="^70)
        plot_dir = joinpath(comparison_dir, sim_name, "plots")
        println("plot_dir: $plot_dir")
        plot_pcm_results(battery_results[battery_mw]; output_dir = plot_dir)

        analyze_results(; results_dir = comparison_dir, sim_name = sim_name, system = sys_with_battery, diesel_price = diesel_price)

        @info "PCM (battery: $battery_mw MW) complete"
    end

    # Step 4: Report and compare results
    report_battery_comparison_analysis(inv_results, pcm_results_no_battery, battery_results, battery_sizes)

    return (inv_results, pcm_results_no_battery, battery_results, battery_sizes)
end

# ============================================================================
# Battery Comparison Analysis Reporting
# ============================================================================

"""
    report_battery_comparison_analysis(inv_results, pcm_results_no_battery, battery_results, battery_sizes)

Generate comprehensive analysis and comparison of battery sensitivity scenarios.

Arguments:
  inv_results: Dict of CEM investment decisions (tech_name → MW)
  pcm_results_no_battery: PCM results dict for baseline (no battery)
  battery_results: Dict mapping battery_mw → PCM results dict
  battery_sizes: Array of battery sizes tested (MW)

Outputs comparison tables, fuel cost reductions, and renewable fraction improvements.
"""
function report_battery_comparison_analysis(
    inv_results::Dict,
    pcm_results_no_battery::Dict,
    battery_results::Dict,
    battery_sizes::Vector{Float64},
)
    println("\n" * "="^70)
    println("COMPARISON RESULTS")
    println("="^70)

    println("\nPost-Investment System (from CEM):")
    for (tech_name, cap) in sort(inv_results)
        if cap > 0.1
            println("  ✓ $tech_name: $(round(cap, digits=2)) MW")
        end
    end

    println("\nPCM Results (Baseline - No Battery):")
    report_pcm_results(pcm_results_no_battery)

    # Compare each battery configuration against baseline
    println("\n" * "="^70)
    println("Battery Sensitivity Analysis")
    println("="^70)

    for battery_mw in battery_sizes
        if !haskey(battery_results, battery_mw)
            continue
        end

        pcm_results_with_battery = battery_results[battery_mw]

        println("\nPCM Results (Battery: $battery_mw MW / $(battery_mw*4) MWh):")
        report_pcm_results(pcm_results_with_battery)

        # Try to compare costs if full results are available
        try
            compare_pcm_costs(pcm_results_no_battery, pcm_results_with_battery;
                scenario_labels=Dict(
                    :without => "Without Battery (baseline)",
                    :with => "With Battery ($battery_mw MW / $(battery_mw*4) MWh)"
                ))
        catch e
            @debug "Could not compare costs: $e"
        end
    end

    # Create plot of battery size vs operating cost
    println("\n" * "="^70)
    println("Generating battery cost relationship plot...")
    println("="^70)
    plot_obj, plot_path = plot_battery_cost_relationship(
        battery_sizes,
        battery_results,
        pcm_results_no_battery;
        output_dir = "results/battery_comparison"
    )
    if !isempty(plot_path)
        println("Plot saved to: $plot_path")
    end

    println("\n" * "="^70)
    println("✓ Battery comparison workflow complete")
    println("Results saved to: results/battery_comparison/")
    println("="^70 * "\n")
end

# ============================================================================
# Validation Workflow: CEM → PCM
# ============================================================================

function run_validation_workflow(args::Dict{String, Any})
    println("\n" * "="^70)
    println("VALIDATION WORKFLOW: Capacity Expansion → Production Cost Simulation")
    println("="^70 * "\n")

    _apply_solver_arg!(args)
    _apply_slack_args!(args)
    mip_gap = args["mip-gap"]
    diesel_price = _diesel_price(args)
    use_copper_plate = args["copper-plate"]

    # Arrivals are needed for the PCM regardless of where the CEM results come from
    scenario_name, all_scenarios, arrivals = _select_arrivals(args)
    label = _run_label(args, scenario_name)
    scenario = Symbol(label)
    horizon_end = _horizon_end(args, arrivals)

    println("Run: $label (load scenario: $scenario_name, horizon through $horizon_end)")
    println("PCM Optimality Gap: $(mip_gap*100)%")
    println("Diesel Price: \$$(diesel_price)/gal")
    println("PCM network model: $(use_copper_plate ? "CopperPlate" : "NFAPowerModel")\n")

    _print_arrivals(scenario_name, all_scenarios, arrivals)

    # Step 1: Get investment results
    cem_results_obj = nothing
    portfolio = nothing
    inv_results = Dict()

    if !isempty(args["cem-results"]) && isfile(args["cem-results"])
        @info "Loading CEM results from $(args["cem-results"])"
        try
            cem_json = JSON.parsefile(args["cem-results"])
            inv_results = Dict{String, Float64}(k => Float64(v) for (k, v) in get(cem_json, "investment_decisions", Dict()))
        catch e
            @warn "Could not load CEM results: $e"
            inv_results = Dict()
        end
    else
        @info "Running CEM first..."

        procurement_timelines = parse_procurement_timelines(args["procurement-timelines"])
        _print_procurement_timelines(procurement_timelines)
        exogenous_builds = parse_exogenous_builds(args["exogenous-builds"])
        _check_exogenous_builds(exogenous_builds, procurement_timelines, horizon_end)

        portfolio = _build_portfolio(arrivals, procurement_timelines, diesel_price;
                                     horizon_end = horizon_end, exogenous_builds = exogenous_builds)
        planning_dir = joinpath("results", "planning", label)
        cem_results_obj = solve_planning(portfolio;
                                         results_dir = planning_dir,
                                         day_start = args["day-start"], day_end = args["day-end"], mip_gap = mip_gap,
                                         solver_time_limit = _solver_time_limit(args),
                                         exogenous_builds = exogenous_builds,
                                         fuel_cap = !args["disable-fuel-cap"],
                         tier2_hours = !get(args, "disable-tier2-hours", false), copper_plate = !args["nodal-cem"])
        inv_results = _extract_investment_results(cem_results_obj)
        _write_planning_summary(cem_results_obj, portfolio, joinpath(planning_dir, "summary.json"))

        # Save CEM results
        cem_json_path = joinpath(planning_dir, "cem_results.json")
        mkpath(dirname(cem_json_path))
        open(cem_json_path, "w") do f
            JSON.print(f, Dict("scenario" => scenario, "investment_decisions" => inv_results))
        end
        @info "CEM results saved → $cem_json_path"
    end
    cem_results = Dict("scenario" => scenario, "investment_decisions" => inv_results)

    if isempty(inv_results)
        println("\n⚠ No investments found in CEM results. Skipping PCM.")
        println("="^70 * "\n")
        return
    end

    # Step 2: Report CEM results
    println("\nStep 1: CEM Results")
    println("="^70)
    if !isnothing(cem_results_obj) && !isnothing(portfolio)
        report_planning_results(cem_results_obj, portfolio, scenario)
    else
        println("Candidate technologies built:")
        for (tech_name, cap) in sort(inv_results)
            if cap > 0.1
                println("  ✓ $tech_name: $(round(cap, digits=2)) MW")
            end
        end
    end

    # Step 3: Run PCM on post-investment system
    println("\nStep 2: Post-Investment System PCM")
    println("="^70)
    println("  Candidate technologies built:")
    for (tech_name, cap) in sort(inv_results)
        if cap > 0.1
            println("    ✓ $tech_name: $(round(cap, digits=2)) MW")
        end
    end

    pcm_results = run_postoptimal_pcm(
        inv_results;
        scenario = scenario,
        results_dir = joinpath("results", "pcm"),
        mip_gap = mip_gap,
        copper_plate = use_copper_plate,
        arrivals = arrivals,
        diesel_price = diesel_price,
        day_start = args["day-start"],
        day_end = args["day-end"],
        year = horizon_end,
    )

    # Step 4: Report PCM results
    println("\nStep 3: PCM Simulation Results")
    println("="^70)
    report_pcm_results(pcm_results)

    # Step 5: Generate plots
    println("\nStep 4: Generating plots...")
    println("="^70)
    plot_dir = joinpath("results", "plots", "validation_$(scenario)")
    plot_pcm_results(pcm_results; output_dir = plot_dir)
    # Print PCM results to terminal
    all_results = analyze_results(pcm_results; diesel_price = diesel_price)
    write_pcm_summary(all_results, joinpath("results", "pcm", "pcm_summary_$(scenario).json"))

    println("="^70)
    println("✓ Validation workflow complete")
    println("CEM results:  results/planning/$(scenario)/")
    println("PCM results:  $(pcm_results["results_dir"])/")
    println("Plots saved:  $plot_dir")
    println("="^70 * "\n")
    return (cem_results, pcm_results)
end

# ============================================================================
# Uncertainty Analysis Workflow
# ============================================================================

function run_uncertainty_workflow(args::Dict{String, Any})
    println("\n" * "="^70)
    println("UNCERTAINTY ANALYSIS: Multi-Scenario Sensitivity")
    println("="^70 * "\n")

    @info "Running CEM for multi-period load arrival scenarios..."
    _apply_solver_arg!(args)
    _apply_slack_args!(args)

    # All scenarios in the arrivals input, or only the one given with --scenario
    scenarios_dict = parse_arrivals_scenarios(args["arrivals"])
    scenario_filter = args["scenario"]
    if !isempty(scenario_filter) && haskey(scenarios_dict, scenario_filter)
        scenarios_dict = Dict(scenario_filter => scenarios_dict[scenario_filter])
    end

    all_results = Dict{String, Dict}()
    all_timing = Dict{String, Dict}()  # Store investment timing by year
    mip_gap = args["mip-gap"]

    for (scenario_name, arrivals) in scenarios_dict
        println("\n  Running scenario: $scenario_name...")
        portfolio = build_planning_portfolio(arrivals; verbose = false, diesel_price = _diesel_price(args))
        results = solve_planning(portfolio;
                                results_dir = joinpath("results", "planning", string(scenario_name)),
                                day_start = args["day-start"], day_end = args["day-end"], mip_gap = mip_gap,
                                solver_time_limit = _solver_time_limit(args))
        all_results[scenario_name] = _extract_investment_results(results)

        # Extract investment timing information
        port_id = objectid(portfolio)
        if haskey(_PORTFOLIO_INTERVAL_DATA, port_id)
            interval_data = _PORTFOLIO_INTERVAL_DATA[port_id]
            intervals = interval_data.intervals
            rep_years = interval_data.rep_years
            all_timing[scenario_name] = _extract_investment_by_interval(results, intervals, rep_years)
        end
    end

    # Identify robust investments (appear in all scenarios)
    println("\n" * "="^70)
    println("Robust Investment Analysis")
    println("="^70)

    all_techs = Set()
    for results in values(all_results)
        union!(all_techs, keys(results))
    end

    scenario_names = collect(keys(all_results))

    println("\nRobust Investments (appear in all scenarios):")
    robust_count = 0
    for tech in sort(collect(all_techs))
        capacities = [get(all_results[s], tech, 0.0) for s in scenario_names]
        if all(c > 0.1 for c in capacities)
            robust_count += 1
            println("  ✓ $tech: $(round(mean(capacities), digits=2)) MW (avg)")
        end
    end

    if robust_count == 0
        println("  (None)")
    end

    println("\nDetailed Investments by Scenario:")
    for scenario in scenario_names
        println("  ◦ $scenario:")
        scenario_results = all_results[scenario]
        scenario_timing = get(all_timing, scenario, Dict())
        for (tech, capacity) in sort(scenario_results)
            if capacity > 0.01
                if !isempty(scenario_timing) && haskey(scenario_timing, tech)
                    # Show investment timeline
                    years = scenario_timing[tech]
                    year_str = join(["Year $year: +$(round(cap, digits=2)) MW" for (year, cap) in years], "; ")
                    println("      ├─ $tech: $(round(capacity, digits=2)) MW total ($year_str)")
                else
                    println("      ├─ $tech: $(round(capacity, digits=2)) MW")
                end
            end
        end
    end

    println("\n" * "="^70)
    println("✓ Uncertainty analysis complete")
    println("Results saved to: results/planning/")
    println("="^70 * "\n")
end

# ============================================================================
# Main Entry Point
# ============================================================================

const WORKFLOWS = Dict(
    "pcm" => run_pcm_workflow,
    "cem" => run_cem_workflow,
    "validate" => run_validation_workflow,
    "battery" => run_battery_comparison_workflow,
    "uncertainty" => run_uncertainty_workflow,
)

"""
    main(args = ARGS; case_dir = nothing)

Run a workflow from command-line arguments. The case comes from `--case`, then `case_dir`,
then the case already loaded with [`load_case!`](@ref).
"""
function main(args::AbstractVector{<:AbstractString} = ARGS; case_dir::Union{Nothing, AbstractString} = nothing)
    start_time = time()
    parsed = parse_cmdline(args)
    dir = isempty(parsed["case"]) ? case_dir : parsed["case"]
    isnothing(dir) || load_case!(dir)

    mode = parsed["mode"]
    workflow = get(WORKFLOWS, mode, nothing)
    if isnothing(workflow)
        println("Unknown mode: $mode")
        println("Valid modes: $(join(sort(collect(keys(WORKFLOWS))), ", "))")
        return nothing
    end
    result = workflow(parsed)
    println("Total script runtime: $((time() - start_time) / 60) minutes")
    return result
end
