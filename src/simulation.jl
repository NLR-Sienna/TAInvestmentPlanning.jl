# src/simulation.jl
#
# Annual production cost simulation.
#
# Formulation:
#   Single-stage rolling-horizon unit commitment (UC)
#   - Horizon:     24 hours (day-ahead look-ahead)
#   - Resolution:  1 hour
#   - Steps:       364 (one UC solve per day)
#   - Chronology:  InterProblemChronology (terminal state → next step initial conditions)
#
# Network model: CopperPlatePowerModel (no transmission constraints, single bus)
#   Appropriate for an isolated island system with a single aggregated bus.
#
# Device formulations:
#   ThermalStandard        → ThermalStandardUnitCommitment
#     Binary on/off, start/stop, ramp rates, min up/down times
#   RenewableDispatch      → RenewableFullDispatch
#     Curtailable; optimizer can reduce below available CF if needed
#   HydroDispatch          → HydroDispatch
#     Hydro generation unit (coupled with HydroReservoir via inflow)
#   HydroReservoir         → HydroDispatchReservoirStorage
#     Tracks reservoir MWh level each hour; enforces storage limits
#   EnergyReservoirStorage → EnergyReservoirStorageDispatch
#     Battery storage: tracks SOC, enforces energy limits, efficiency losses
#   PowerLoad              → StaticPowerLoad
#     Fixed inelastic demand (no demand response)
#
# Solver: HiGHS (open-source MILP) by default; see set_solver!
#   Commercial solvers (Gurobi, CPLEX) can be substituted for speed.

# ---------------------------------------------------------------------------
# Problem template
# ---------------------------------------------------------------------------

"""
    build_uc_template(; copper_plate::Bool=false) -> ProblemTemplate

Create the unit commitment problem template.

Parameters:
  copper_plate: If true, use CopperPlate model (single aggregated bus, fastest)
                If false, use NFAPowerModel (nodal network with transmission, slower but detailed)
"""
function build_uc_template(; copper_plate::Bool=false) :: ProblemTemplate

    # Choose network model: CopperPlate is much faster, NFAPowerModel is more detailed
    if copper_plate
        template = ProblemTemplate(NetworkModel(CopperPlatePowerModel, use_slacks=true))
    else
        # Network flow approximation: nodal balance with transmission limits
        template = ProblemTemplate(NetworkModel(NFAPowerModel, use_slacks=true))
    end

    # Diesel: full binary unit commitment (on/off/start/stop decisions)
    PSI.set_device_model!(template, PSY.ThermalStandard, PSI.ThermalStandardUnitCommitment)

    # Wind: curtailable (optimizer may reduce below available capacity)
    PSI.set_device_model!(template, PSY.RenewableDispatch, PSI.FixedOutput)

    # Hydro: reservoir (storage) and turbine (generation) components
    PSI.set_device_model!(template, PSY.HydroTurbine, HPS.HydroTurbineEnergyDispatch)
    reservoir_model = PSI.DeviceModel(
        PSY.HydroReservoir,
        HPS.HydroEnergyModelReservoir;
        attributes = Dict{String, Any}(
            "energy_target" => false,
            "hydro_budget" => false,
        ),
    )
    PSI.set_device_model!(template, reservoir_model)

    # Battery: energy reservoir storage with dispatch and state-of-charge tracking
    PSI.set_device_model!(template, PSY.EnergyReservoirStorage, SSS.StorageDispatchWithReserves)

    # Load: fixed (no demand response or load shedding)
    PSI.set_device_model!(template, PSY.PowerLoad, PSI.StaticPowerLoad)

    PSI.set_device_model!(template, PSY.Line, PSI.StaticBranchBounds)
    PSI.set_device_model!(template, PSI.DeviceModel(PSY.Transformer2W, PSI.StaticBranch, use_slacks=true))#PSI.StaticBranchUnbounded)

    # Reserve service: ReserveUp (spinning reserve requirement)
    PSI.set_service_model!(template, PSI.ServiceModel(PSY.ConstantReserve{PSY.ReserveUp}, PSI.RangeReserve, use_slacks = true))

    return template
end

# ---------------------------------------------------------------------------
# Simulation builder
# ---------------------------------------------------------------------------

"""
    build_pcm_simulation(sys; results_dir, sim_name, mip_gap, solver_time_limit, copper_plate)
                            -> Simulation

Build the annual rolling-horizon UC simulation.

Uses 48-hour lookahead horizon with 24-hour rolling intervals (one problem per day).

Parameters:
  sys               PowerSystems.System built by the case's build_case_system()
  results_dir       Directory where results will be written
  sim_name          Subdirectory name for this simulation run
  mip_gap           MILP relative optimality gap (0.05 = 5%)
  solver_time_limit Maximum seconds per UC solve (30s)
  copper_plate      Use CopperPlate model (fast, no transmission) instead of NFAPowerModel (default: false)
"""
function build_pcm_simulation(
    sys              :: PSY.System;
    results_dir      :: String  = joinpath(pwd(), "results"),
    sim_name         :: String  = default_pcm_sim_name(),
    mip_gap          :: Float64 = 0.05,
    solver_time_limit :: Float64 = 30.0,
    copper_plate     :: Bool    = false,
    day_start        :: Int     = 1,
    day_end          :: Int     = 365,
    sim_year         :: Int     = case_simulation_year(),
) :: PSI.Simulation

    template = build_uc_template(copper_plate=copper_plate)

    # DecisionModel: 48h UC problem solved per day (rolling 24h intervals)
    uc_model = DecisionModel(
        template,
        sys;
        name      = "UC",
        optimizer = _optimizer(; mip_gap = mip_gap, time_limit = solver_time_limit),
        horizon    = Hour(48),
        resolution = Hour(1),
        warm_start = true,
    )

    models = SimulationModels(decision_models = [uc_model])

    # InterProblemChronology: passes terminal conditions (storage level,
    # commitment status) from the last hour of each UC solve to the
    # initial conditions of the next UC solve.
    sequence = SimulationSequence(
        models                = models,
        ini_cond_chronology   = InterProblemChronology(),
    )

    mkpath(results_dir)

    # Calculate steps and initial time from day range
    num_steps = day_end - day_start + 1
    initial_time = DateTime(sim_year, 1, 1) + Day(day_start - 1)

    sim = Simulation(;
        name              = sim_name,
        steps             = num_steps,
        models            = models,
        sequence          = sequence,
        simulation_folder = results_dir,
        initial_time      = initial_time,
    )

    return sim
end

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

"""
    run_simulation!(sim; serialize) -> Simulation

Build and execute the annual production cost simulation.
Solves 364 rolling-horizon UC problems, each with 48-hour lookahead
and 24-hour rolling intervals.

Runtime is typically 10–60 minutes on a modern laptop, depending
on the MILP gap tolerance and the number of diesel starts.

With serialize=true, results are written to disk and can be reloaded
without re-running via SimulationResults(path).
"""
function run_simulation!(sim :: PSI.Simulation; serialize :: Bool = false)
    @info "Building simulation model..."
    status = PSI.build!(sim)

    @info "Executing annual simulation: 364 daily UC problems, each with 24h horizon."
    @info "Estimated runtime: 10–60 minutes (solver: $(solver_name()))"

    PSI.execute!(sim; enable_progress_bar = true)

    @info "Simulation complete. Results in: $(sim.simulation_folder)"
    return sim
end

# ---------------------------------------------------------------------------
# Optional: quick single-day test (for development/debugging)
# ---------------------------------------------------------------------------

"""
    run_single_day_test(sys; day_of_year) -> DecisionModel

Solve a single 24h UC problem for testing without running the full simulation.
Useful for verifying model setup and debugging infeasibilities.

  day_of_year : 1-based index of the day to solve (1 = Jan 1, 364 = Dec 31)
"""
function run_single_day_test(
    sys         :: PSY.System;
    day_of_year :: Int = 1,
)
    @info "Running single-day test (day $day_of_year of 364)..."

    template = build_uc_template()

    model = DecisionModel(
        template,
        sys;
        name      = "UC_test",
        optimizer = _optimizer(; mip_gap = 0.01, silent = false),
        horizon    = Hour(24),
        resolution = Hour(1),
    )

    output_dir = joinpath(pwd(), "results", "test_day$(day_of_year)")
    mkpath(output_dir)
    PSI.build!(model; output_dir = output_dir)
    PSI.solve!(model)
    results = PSI.OptimizationProblemResults(model)

    @info "Single-day solve complete."
    return results
end
