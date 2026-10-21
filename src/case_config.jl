# Case settings parsed from case.toml.
#
# Sections:
#   [case]               name, title
#   [financial]          discount_rate, base_year, inflation_rate, interest_rate, capital_recovery_period,
#                        debt_fraction, debt_rate, return_on_equity, tax_rate, optional capital_within_horizon
#                        (default true: builds pay only the capital payments up to the horizon end)
#   [penalties]          unserved_energy_per_mwh, reserve_margin_per_mw_yr
#   [tier2_fuel]         fuel_limit_gal_per_yr, penalty_per_gal, default_heat_rate_mbtu_per_mwh
#                        (system-wide cap on fuel burned by all thermal units in the CEM)
#   [tier2_hours]        hours_per_yr, penalty_per_mwh (CEM operating limit for each Tier 2 unit)
#   [emission_tiers]     existing_default (tier of existing thermal units), optional [emission_tiers.existing]
#                        table of unit name = tier overrides; each [[candidates.diesel]] has a tier
#   [solver]             mip_gap, time_limit_s
#   [planning]           reserve_margin, synthetic_wind_capacity_factor (CEM wind CF only when [pcm]
#                        reference_wind_unit is not in the system)
#   [base_demand]        name, bus
#   [scenarios]          arrivals (JSON of load arrival scenarios), default_scenario (name in that file),
#                        default_procurement_timelines (JSON); paths are relative to the case directory
#   [pcm]                reference_wind_unit, default_bus
#   [[planned_additions]] name, kind, bus, capacity_mw, year, id, optional pcm_bus; built exactly in `year`
#   [[planned_retirements]] unit, capacity_mw, year: MW of an existing unit retired from `year` on
#   [candidates]         diesel_heat_rate_mbtu_per_mwh, diesel_start_up_cost, diesel_shut_down_cost,
#                        battery_efficiency, battery_lifetime_years, battery_power_cost_share,
#                        and [[candidates.battery]], [[candidates.diesel]], [[candidates.wind]] tables
#   [report.benchmarks]  optional: source, hydro_mwh, wind_mwh, renewable_share_pct (printed as given)
#   [capacity_credit]    optional: method = "net_load" (default; wind and solar credited at their mean
#                        CF over the top_hours highest net-load hours) or "fixed", top_hours (default 100)

_nt(d::AbstractDict) = (; (Symbol(k) => v for (k, v) in d)...)

battery_candidate_name(b) = "Battery_$(b.power_mw)MW_$(b.energy_mwh)MWh"
diesel_candidate_name(d) = "Diesel_$(d.unit_name)_$(d.site)"

function load_candidates(cfg::AbstractDict)
    c = cfg["candidates"]
    return (
        battery = [_nt(b) for b in c["battery"]],
        diesel = [_nt(d) for d in c["diesel"]],
        wind = [_nt(w) for w in c["wind"]],
        diesel_heat_rate_mbtu_per_mwh = c["diesel_heat_rate_mbtu_per_mwh"],
        diesel_start_up_cost = c["diesel_start_up_cost"],
        diesel_shut_down_cost = c["diesel_shut_down_cost"],
        battery_efficiency = c["battery_efficiency"],
        battery_lifetime_years = c["battery_lifetime_years"],
        battery_power_cost_share = c["battery_power_cost_share"],
    )
end

# Name → (kind, pcm_bus, sizes) for every candidate and planned addition
function build_technology_catalog(candidates, planned_additions)
    catalog = Dict{String, NamedTuple}()
    for b in candidates.battery
        catalog[battery_candidate_name(b)] =
            (kind = "Battery", pcm_bus = b.pcm_bus, power_mw = b.power_mw, energy_mwh = b.energy_mwh)
    end
    for d in candidates.diesel
        catalog[diesel_candidate_name(d)] =
            (kind = "Diesel", pcm_bus = d.pcm_bus, capacity_mw = d.capacity_mw, tier = d.tier)
    end
    for w in candidates.wind
        catalog[w.name] = (kind = "Wind", pcm_bus = w.pcm_bus, capacity_mw = w.capacity_mw)
    end
    for a in planned_additions
        catalog[a.name] = (kind = titlecase(a.kind), pcm_bus = get(a, :pcm_bus, nothing), capacity_mw = a.capacity_mw)
    end
    return catalog
end

function _capacity_credit_settings(cfg::AbstractDict)
    method = get(cfg, "method", "net_load")
    method in ("net_load", "fixed") || error("[capacity_credit] method must be \"net_load\" or \"fixed\", got \"$method\"")
    return (method = method, top_hours = Int(get(cfg, "top_hours", 100)))
end

function load_planning_settings(path::AbstractString)
    cfg = TOML.parsefile(path)
    case_dir = dirname(abspath(path))
    candidates = load_candidates(cfg)
    planned_additions = [_nt(a) for a in get(cfg, "planned_additions", [])]
    planned_retirements = [_nt(r) for r in get(cfg, "planned_retirements", [])]
    benchmarks = get(get(cfg, "report", Dict()), "benchmarks", nothing)
    return (
        name = cfg["case"]["name"],
        title = cfg["case"]["title"],
        candidates = candidates,
        planned_additions = planned_additions,
        planned_retirements = planned_retirements,
        catalog = build_technology_catalog(candidates, planned_additions),
        discount_rate = cfg["financial"]["discount_rate"],
        base_year = cfg["financial"]["base_year"],
        financial = _nt(cfg["financial"]),
        capital_within_horizon = get(cfg["financial"], "capital_within_horizon", true),
        unserved_energy_per_mwh = cfg["penalties"]["unserved_energy_per_mwh"],
        reserve_margin_per_mw_yr = cfg["penalties"]["reserve_margin_per_mw_yr"],
        tier2_fuel_limit_gal = cfg["tier2_fuel"]["fuel_limit_gal_per_yr"],
        tier2_penalty_per_gal = cfg["tier2_fuel"]["penalty_per_gal"],
        default_heat_rate = cfg["tier2_fuel"]["default_heat_rate_mbtu_per_mwh"],
        tier2_hours_per_yr = cfg["tier2_hours"]["hours_per_yr"],
        tier2_hours_penalty_per_mwh = cfg["tier2_hours"]["penalty_per_mwh"],
        existing_unit_tier = cfg["emission_tiers"]["existing_default"],
        existing_unit_tiers = Dict{String, Int}(get(cfg["emission_tiers"], "existing", Dict())),
        mip_gap = cfg["solver"]["mip_gap"],
        time_limit_s = cfg["solver"]["time_limit_s"],
        reserve_margin = cfg["planning"]["reserve_margin"],
        synthetic_wind_capacity_factor = cfg["planning"]["synthetic_wind_capacity_factor"],
        base_demand = _nt(cfg["base_demand"]),
        default_arrivals_path = joinpath(case_dir, cfg["scenarios"]["arrivals"]),
        default_scenario = cfg["scenarios"]["default_scenario"],
        default_procurement_timelines_path = joinpath(case_dir, cfg["scenarios"]["default_procurement_timelines"]),
        pcm = _nt(cfg["pcm"]),
        report_benchmarks = isnothing(benchmarks) ? nothing : _nt(benchmarks),
        capacity_credit = _capacity_credit_settings(get(cfg, "capacity_credit", Dict())),
    )
end

technology_kind(name::AbstractString) = get(settings().catalog, name, (kind = nothing,)).kind

"MW of an existing unit retired by `year` (`[[planned_retirements]]` in case.toml)."
retired_capacity_mw(unit_name::AbstractString, year::Integer) =
    sum(Float64(r.capacity_mw) for r in settings().planned_retirements if r.unit == unit_name && r.year <= year; init = 0.0)

"""
    unit_tier(unit_name) -> Int

EPA engine tier of a thermal unit: from the candidate catalog for diesel candidates, otherwise
from `[emission_tiers]` for existing units.
"""
function unit_tier(unit_name::AbstractString)
    entry = get(settings().catalog, unit_name, nothing)
    !isnothing(entry) && hasproperty(entry, :tier) && return entry.tier
    return get(settings().existing_unit_tiers, unit_name, settings().existing_unit_tier)
end
