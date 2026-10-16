# TAInvestmentPlanning.jl

Capacity expansion (CEM) and production cost (PCM) workflows built on the Sienna packages
(PowerSystems, PowerSimulations, PowerSystemsInvestments, PowerSystemsInvestmentsPortfolios).
The code is separate from case data: a *case directory* supplies the system, settings, candidate
technologies, and scenario defaults, so the same workflows run on different datasets.

## Installation

The package depends on unregistered branches of the Sienna investment packages, declared in
`[sources]` in `Project.toml`:

- `PowerSystemsInvestments`: branch `cb/inv_compat` from GitHub
- `PowerSystemsInvestmentsPortfolios`: branch `cb/inv_compat` from GitHub

Pkg honors these `[sources]` only when this package is the active project or is developed. A
project that adds it from GitHub must add both investment packages itself first:

```julia
using Pkg
Pkg.add([
    PackageSpec(url = "https://github.com/Sienna-Platform/PowerSystemsInvestments.jl.git", rev = "cb/inv_compat"),
    PackageSpec(url = "https://github.com/Sienna-Platform/PowerSystemsInvestmentsPortfolios.jl.git", rev = "cb/inv_compat"),
])
Pkg.add(url = "https://github.com/NLR-Sienna/TAInvestmentPlanning.jl", rev = "main")
```

`PowerSystemsInvestments` has the same UUID as the registered `HybridSystemsSimulations` package.
Without an explicit source, Pkg resolves it from the General registry and fails.

`PowerSystemsInvestments` declares `__precompile__(false)`, so this package is compiled on each
load rather than cached.

## Running a case

```julia
using TAInvestmentPlanning
load_case!("path/to/case")
run_validation_workflow(parse_cmdline(["validate", "--arrivals=arrivals.json", "--scenario=base"]))
```

Or from a driver script that calls `TAInvestmentPlanning.main(ARGS; case_dir = ...)`:

```
julia --project=. run_case.jl validate --arrivals=arrivals.json --scenario=base --day-end=8
julia --project=. run_case.jl --help
```

Workflows: `pcm` (base system production cost), `cem` (capacity expansion), `validate` (CEM, then
PCM of the post-investment system in the planning horizon year), `battery` (battery size
sensitivity), and `uncertainty` (CEM for every arrivals scenario). Results are written under
`results/` in the working directory.

Scenario inputs are JSON files or JSON strings:

| Option | Format | Default |
|---|---|---|
| `--arrivals` | `{"scenario": [{"year": 2027, "mw": 1.0, "conforming": true, "bus": "Bus"}, ...]}` | the case's arrivals file |
| `--scenario` | scenario name in the arrivals input | the case's default scenario, else the only scenario |
| `--procurement-timelines` | `{"Tech_Name": [first_year, last_year]}` | case default timelines |
| `--exogenous-builds` | `{"Tech_Name": {"2030": 4.0}}` (0 = do not build) | none |
| `--diesel-price` | \$/gal | case default |

## Case directory

```
case/
├── case.toml       settings, penalties, candidate catalogs, scenario defaults
├── case.jl         builds the system and defines the case functions below
└── scenarios/      load arrival scenarios and default procurement timelines (JSON)
```

`case.toml` sections are listed at the top of `src/case_config.jl`; `test/cases/tiny` is a
complete small example.

`case.jl` is included into its own module and must define:

| Function | Returns |
|---|---|
| `build_case_system(; diesel_price, verbose)` | `(system, timestamps)`: the base system with hourly `SingleTimeSeries` covering every planning year, transformed to 48 h / 24 h forecasts, with a `ConstantReserve{ReserveUp}` |
| `case_default_diesel_price()` | \$/gal |
| `case_fuel_hhv_mbtu_per_gal()` | MBTU/gal |
| `case_base_peak_load_mw()` | base peak load before arrivals |
| `case_simulation_year()` | year of the base PCM |
| `case_operating_reserve_name()` | name of the operating reserve |
| `case_hydro_rating_mw()`, `case_wind_rating_mw()` | existing ratings for PCM capacity factors |
| `case_rated_heat_rate(unit_name)` | MBTU/MWh for an existing thermal unit, or `nothing` |
| `case_candidate_heat_rate_curve(capacity_mw)` | `[(MW, MBTU/MWh), ...]` for a candidate diesel unit |

Optional (defaults apply when not defined):

| Function | Default |
|---|---|
| `case_existing_availability_multiplier(unit_name, year)` | `1.0` |
| `adjust_planning_system!(sys, rep_years; verbose)` | no change |
| `adjust_pcm_system!(sys, timestamps)` | no change |

## Tests

```julia
using Pkg
Pkg.test("TAInvestmentPlanning")
```

The tests cover settings and scenario parsing, investment intervals, the CLI arguments, and a
CEM → PCM run of the tiny case checked against `test/reference`. After an intended change in
results, regenerate the references with `UPDATE_REFERENCE=true`.
