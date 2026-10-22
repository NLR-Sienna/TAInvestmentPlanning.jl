# Active case: settings from case.toml and functions from case.jl.
#
# A case directory contains
#   case.toml  run settings, candidate catalogs, scenario defaults (see load_planning_settings)
#   case.jl    Julia code that builds the PowerSystems system and defines the case functions below
#
# case.jl is included into its own module. The workflows call its functions through the
# wrappers in this file, so a case only needs to define them with the names listed here.

struct ActiveCase
    dir::String
    settings::NamedTuple
    mod::Module
end

const _ACTIVE_CASE = Ref{Union{Nothing, ActiveCase}}(nothing)

"""
    load_case!(case_dir) -> ActiveCase

Load the case in `case_dir` and make it the active case for all workflows.

Reads `case_dir/case.toml` and includes `case_dir/case.jl` into a new module. Loading a case
again replaces the previous one.
"""
function load_case!(case_dir::AbstractString)
    dir = abspath(case_dir)
    toml_path = joinpath(dir, "case.toml")
    code_path = joinpath(dir, "case.jl")
    isfile(toml_path) || error("Case settings not found: $toml_path")
    isfile(code_path) || error("Case code not found: $code_path")

    case_settings = load_planning_settings(toml_path)
    mod = Module(Symbol(titlecase(case_settings.name) * "Case"))
    Core.eval(mod, :(include(path::AbstractString) = Base.include($mod, path)))
    Core.eval(mod, :(eval(x) = Core.eval($mod, x)))
    Base.include(mod, code_path)

    case = ActiveCase(dir, case_settings, mod)
    _ACTIVE_CASE[] = case
    @info "Loaded case \"$(case_settings.name)\" from $dir"
    return case
end

"""
    set_candidate_overrides!(overrides = Dict())

Apply candidate changes for the next runs on top of the active case's case.toml, without
writing the file: `overrides` maps a candidate name to the fields to change, e.g.
`Dict("Diesel_Wartsila_4300kW_Airport" => Dict("tier" => 2, "capacity_mw" => 4.4))`. Each call
starts again from case.toml, so `set_candidate_overrides!()` restores the base settings.
"""
function set_candidate_overrides!(overrides::AbstractDict = Dict())
    case = active_case()
    _ACTIVE_CASE[] = ActiveCase(case.dir,
        load_planning_settings(joinpath(case.dir, "case.toml"); candidate_overrides = overrides), case.mod)
    isempty(overrides) || @info "Candidate overrides: $(join(["$n $(Dict(fields))" for (n, fields) in overrides], "; "))"
    return settings()
end

function active_case()
    case = _ACTIVE_CASE[]
    isnothing(case) && error("No case loaded. Call TAInvestmentPlanning.load_case!(case_dir) first.")
    return case
end

"""Settings parsed from the active case's case.toml."""
settings() = active_case().settings
case_dir() = active_case().dir
case_name() = settings().name

"Default PCM simulation name: `<case name>_annual`."
default_pcm_sim_name() = "$(case_name())_annual"

"Where the PCM workflow saves the base system: `<case name>_system.json` in the working directory."
case_system_json_path() = joinpath(pwd(), "$(case_name())_system.json")

# case.jl is loaded after the calling code was compiled, so the case bindings are looked up
# and called in the latest world.
function _invoke_case_function(name::Symbol, args...; kwargs...)
    case = active_case()
    isdefined(case.mod, name) || error("Case $(case.dir) does not define `$name` in case.jl")
    return getfield(case.mod, name)(args...; kwargs...)
end

_has_case_function(name::Symbol) = Base.invokelatest(isdefined, active_case().mod, name)

_call_case(name::Symbol, args...; kwargs...) = Base.invokelatest(_invoke_case_function, name, args...; kwargs...)

# ---------------------------------------------------------------------------
# Required case functions
# ---------------------------------------------------------------------------

"""
    build_case_system(; diesel_price, verbose) -> (PSY.System, Vector{DateTime})

Build the base system with hourly time series for the simulation year.
"""
build_case_system(; kwargs...) = _call_case(:build_case_system; kwargs...)

"Default diesel price in \$/gal."
case_default_diesel_price() = _call_case(:case_default_diesel_price)

"Diesel higher heating value in MBTU/gal."
case_fuel_hhv_mbtu_per_gal() = _call_case(:case_fuel_hhv_mbtu_per_gal)

"Base system peak load in MW, before load arrivals."
case_base_peak_load_mw() = _call_case(:case_base_peak_load_mw)

"Calendar year of the base time series."
case_simulation_year() = _call_case(:case_simulation_year)

"Name of the operating reserve (ConstantReserve{ReserveUp}) in the system."
case_operating_reserve_name() = _call_case(:case_operating_reserve_name)

"Existing hydro rating in MW, used for capacity factors in the PCM report."
case_hydro_rating_mw() = _call_case(:case_hydro_rating_mw)

"Existing wind rating in MW, used for capacity factors in the PCM report."
case_wind_rating_mw() = _call_case(:case_wind_rating_mw)

"Rated heat rate (MBTU/MWh) of an existing thermal unit, or `nothing` if unknown."
case_rated_heat_rate(unit_name::AbstractString) = _call_case(:case_rated_heat_rate, unit_name)

"Heat rate curve [(MW, MBTU/MWh), ...] for a candidate diesel unit of the given size."
case_candidate_heat_rate_curve(capacity_mw::Float64) = _call_case(:case_candidate_heat_rate_curve, capacity_mw)

# ---------------------------------------------------------------------------
# Optional case functions (defaults apply when case.jl does not define them)
# ---------------------------------------------------------------------------

"Multiplier on an existing renewable unit's CEM availability in `year` (default 1.0)."
case_existing_availability_multiplier(unit_name::AbstractString, year::Int) =
    _has_case_function(:case_existing_availability_multiplier) ?
    _call_case(:case_existing_availability_multiplier, unit_name, year) : 1.0

"Case-specific changes to the system used for CEM representative periods (default: none)."
adjust_planning_system!(sys, rep_years; verbose::Bool = false) =
    _has_case_function(:adjust_planning_system!) ?
    _call_case(:adjust_planning_system!, sys, rep_years; verbose = verbose) : sys

"Case-specific changes to the post-investment PCM system (default: none)."
adjust_pcm_system!(sys, timestamps) =
    _has_case_function(:adjust_pcm_system!) ? _call_case(:adjust_pcm_system!, sys, timestamps) : sys
