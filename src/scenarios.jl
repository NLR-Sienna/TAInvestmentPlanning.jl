# Scenario inputs: load arrivals, procurement timelines, and exogenous builds.
# Each input is a JSON file path or a JSON string. Empty input means "use the case default".

@kwdef struct LoadArrival
    year::Int                                   # first year this load is present
    mw::Float64                                 # MW of new demand
    conforming::Bool                            # true = follows system load shape, false = custom/flat
    bus::String                                 # bus name where load is connected
    custom_profile_path::Union{String, Nothing} = nothing  # normalized (0-1) hourly profile for non-conforming loads
end

# JSON object that rejects repeated keys (JSON.parse would otherwise keep only the last one)
struct _UniqueKeyDict <: AbstractDict{String, Any}
    d::Dict{String, Any}
end
_UniqueKeyDict() = _UniqueKeyDict(Dict{String, Any}())
function Base.setindex!(u::_UniqueKeyDict, v, k::AbstractString)
    haskey(u.d, k) && throw(ArgumentError("duplicate key \"$k\""))
    u.d[k] = v
    return u
end
Base.getindex(u::_UniqueKeyDict, k) = u.d[k]
Base.get(u::_UniqueKeyDict, k, default) = get(u.d, k, default)
Base.haskey(u::_UniqueKeyDict, k) = haskey(u.d, k)
Base.length(u::_UniqueKeyDict) = length(u.d)
Base.iterate(u::_UniqueKeyDict, state...) = iterate(u.d, state...)

_plain_json(x) = x
_plain_json(x::_UniqueKeyDict) = Dict{String, Any}(k => _plain_json(v) for (k, v) in x.d)
_plain_json(x::AbstractVector) = Any[_plain_json(v) for v in x]

function _parse_json_unique(text::AbstractString, description::AbstractString)
    try
        return _plain_json(JSON.parse(text; dicttype = _UniqueKeyDict))
    catch e
        e isa ArgumentError && startswith(e.msg, "duplicate key") &&
            error("$(uppercasefirst(description)) input has a $(e.msg); each key may appear once")
        rethrow()
    end
end

function _read_json_input(input::AbstractString, description::AbstractString)
    if isfile(input)
        @info "Loaded $description from file: $input"
        return _parse_json_unique(read(input, String), "$description ($input)")
    end
    endswith(lowercase(strip(input)), ".json") && error("$(uppercasefirst(description)) file not found: $(abspath(input))")
    return _parse_json_unique(input, description)
end

function _parse_arrival(item)
    haskey(item, "bus") || error("Load arrival is missing a bus: $item")
    return LoadArrival(;
        year = item["year"],
        mw = item["mw"],
        conforming = get(item, "conforming", true),
        bus = item["bus"],
        custom_profile_path = get(item, "custom_profile_path", nothing),
    )
end

function parse_arrivals_scenarios(arrivals_input::AbstractString)::Dict{String, Vector{LoadArrival}}
    isempty(arrivals_input) && return parse_arrivals_scenarios(settings().default_arrivals_path)
    data = _read_json_input(arrivals_input, "arrivals")
    scenarios = if data isa AbstractDict
        Dict{String, Vector{LoadArrival}}(String(name) => [_parse_arrival(item) for item in items] for (name, items) in data)
    elseif data isa AbstractVector
        Dict{String, Vector{LoadArrival}}("default" => [_parse_arrival(item) for item in data])
    else
        error("Arrivals input must be a JSON object of scenarios or a list of arrivals")
    end
    isempty(scenarios) && error("Arrivals input contains no scenarios")
    return scenarios
end

function get_arrivals_for_scenario(scenarios::Dict{String, Vector{LoadArrival}}, scenario_name::AbstractString)::Vector{LoadArrival}
    haskey(scenarios, scenario_name) && return scenarios[scenario_name]
    error("Scenario \"$scenario_name\" not found. Available scenarios: $(join(sort(collect(keys(scenarios))), ", "))")
end

"Arrivals for the case's default scenario (`[scenarios] default_scenario` in case.toml)."
default_arrivals()::Vector{LoadArrival} =
    get_arrivals_for_scenario(parse_arrivals_scenarios(settings().default_arrivals_path), settings().default_scenario)

function parse_procurement_timelines(timelines_input::AbstractString)::Union{Dict{String, Tuple{Int, Int}}, Nothing}
    isempty(timelines_input) && return nothing
    data = _read_json_input(timelines_input, "procurement timelines")
    data isa AbstractDict || error("Procurement timelines must be a JSON object of technology => [first_year, last_year]")
    timelines = Dict{String, Tuple{Int, Int}}()
    for (tech_name, window) in data
        (window isa AbstractVector && length(window) == 2) ||
            error("Invalid procurement window for $tech_name: $window (expected [first_year, last_year])")
        timelines[String(tech_name)] = (Int(window[1]), Int(window[2]))
    end
    return isempty(timelines) ? nothing : timelines
end

default_procurement_timelines()::Dict{String, Tuple{Int, Int}} =
    parse_procurement_timelines(settings().default_procurement_timelines_path)

function parse_exogenous_builds(builds_input::AbstractString)::Union{Dict{String, Dict{Int, Float64}}, Nothing}
    isempty(builds_input) && return nothing
    data = _read_json_input(builds_input, "exogenous builds")
    builds = Dict{String, Dict{Int, Float64}}()
    for (tech_name, year_mw) in data
        builds[String(tech_name)] = Dict{Int, Float64}(
            parse(Int, String(year)) => Float64(mw) for (year, mw) in year_mw
        )
    end
    return builds
end
