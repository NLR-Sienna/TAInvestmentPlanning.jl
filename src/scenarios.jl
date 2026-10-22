# Scenario inputs: load arrivals, procurement timelines, and exogenous builds.
# Each input is a JSON file path or a JSON string. Empty input means "use the case default".

@kwdef struct LoadArrival
    year::Int                                   # first year this load is present
    mw::Float64                                 # MW of new demand
    conforming::Bool                            # true = follows system load shape, false = custom/flat
    bus::String                                 # bus name where load is connected
    custom_profile_path::Union{String, Nothing} = nothing  # normalized (0-1) hourly profile for non-conforming loads
end

# JSON object that keeps every key/value pair in order, including repeated keys
struct _JSONPairs <: AbstractDict{String, Any}
    pairs::Vector{Pair{String, Any}}
end
_JSONPairs() = _JSONPairs(Pair{String, Any}[])
Base.setindex!(o::_JSONPairs, v, k::AbstractString) = (push!(o.pairs, String(k) => v); o)
Base.length(o::_JSONPairs) = length(o.pairs)
Base.iterate(o::_JSONPairs, state...) = iterate(o.pairs, state...)
function Base.get(o::_JSONPairs, k, default)
    i = findlast(p -> p.first == k, o.pairs)
    return isnothing(i) ? default : o.pairs[i].second
end
Base.haskey(o::_JSONPairs, k) = any(p -> p.first == k, o.pairs)

# JSON input from a file path or a JSON string. With repeated_keys, objects keep repeated keys
# (as _JSONPairs); otherwise a repeated key keeps its last value, as in JSON.parse.
function _read_json_input(input::AbstractString, description::AbstractString; repeated_keys::Bool = false)
    parse_json(text) = repeated_keys ? JSON.parse(text; dicttype = _JSONPairs) : JSON.parse(text)
    if isfile(input)
        @info "Loaded $description from file: $input"
        return parse_json(read(input, String))
    end
    endswith(lowercase(strip(input)), ".json") && error("$(uppercasefirst(description)) file not found: $(abspath(input))")
    return parse_json(input)
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
    data = _read_json_input(builds_input, "exogenous builds"; repeated_keys = true)
    data isa AbstractDict || error("Exogenous builds must be a JSON object of technology => {\"year\": MW}")
    # Repeated technologies or years add up, e.g. one entry per unit of a multi-unit candidate
    builds = Dict{String, Dict{Int, Float64}}()
    for (tech_name, year_mw) in data
        year_mw isa AbstractDict || error("Exogenous builds for $tech_name must be {\"year\": MW}")
        years = get!(builds, String(tech_name), Dict{Int, Float64}())
        for (year, mw) in year_mw
            y = parse(Int, String(year))
            years[y] = get(years, y, 0.0) + Float64(mw)
        end
    end
    return builds
end
