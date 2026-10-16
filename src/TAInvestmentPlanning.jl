"""
    TAInvestmentPlanning

Capacity expansion (CEM) and production cost (PCM) workflows built on the Sienna packages.
Case data and case-specific code live outside the package in a case directory; see
[`load_case!`](@ref).
"""
module TAInvestmentPlanning

# Sienna
using PowerSystems
using PowerSystems: PrimeMovers
using PowerSimulations
using HydroPowerSimulations
using StorageSystemsSimulations
using PowerSystemsInvestments
using PowerSystemsInvestmentsPortfolios
using PowerAnalytics
using PowerGraphics
using InfrastructureSystems

# Optimization
using JuMP
using HiGHS

# Data and I/O
using DataFrames
using CSV
using JSON
using TimeSeries
using DelimitedFiles
import TOML

# Plotting
using Plots
using PlotlyJS
using PlotlyLight

using ArgParse
using Dates
using Statistics
using Printf
using Logging

const PSY = PowerSystems
const PSI = PowerSimulations
const HPS = HydroPowerSimulations
const SSS = StorageSystemsSimulations
const PSI2 = PowerSystemsInvestments
const PSIP = PowerSystemsInvestmentsPortfolios
const PA = PowerAnalytics
const PG = PowerGraphics
const IS = InfrastructureSystems

include("case_config.jl")
include("case.jl")
include("scenarios.jl")
include("simulation.jl")
include("analyze_results.jl")
include("plotting.jl")
include("planning.jl")
include("pcm_integration.jl")
include("load_analytics.jl")
include("cli.jl")

# Case setup
export load_case!, active_case, settings, case_dir, case_name

# Scenario inputs
export LoadArrival, parse_arrivals_scenarios, get_arrivals_for_scenario, default_arrivals
export parse_procurement_timelines, default_procurement_timelines, merge_procurement_timelines
export parse_exogenous_builds

# Capacity expansion
export build_planning_portfolio, solve_planning, report_planning_results, last_capacity_plot
export set_slack_options!

# Production cost
export build_uc_template, build_pcm_simulation, run_simulation!, run_single_day_test
export build_post_investment_system, add_battery_to_system!, run_postoptimal_pcm
export report_pcm_results, report_tier2_fuel_pcm
export load_pcm_results, analyze_results, write_pcm_summary, compare_pcm_costs
export plot_pcm_results, plot_pcm_comparison, plot_battery_cost_relationship
export extract_battery_cost_data, build_battery_sensitivity_plot, compare_cem_pcm_costs

# Load data
export get_load_data_with_multipliers, sum_load_data

# Command-line workflows
export parse_cmdline, run_pcm_workflow, run_cem_workflow, run_validation_workflow
export run_battery_comparison_workflow, run_uncertainty_workflow

function __init__()
    # PowerGraphics plots render through the Plots PlotlyJS backend
    Plots.plotlyjs()
    return
end

end
