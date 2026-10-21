using Test
using TAInvestmentPlanning
using Dates
using JSON

const IP = TAInvestmentPlanning
const TINY_CASE = joinpath(@__DIR__, "cases", "tiny")
const REFERENCE_DIR = joinpath(@__DIR__, "reference")

# Set UPDATE_REFERENCE=true to rewrite the tiny-case reference summaries
const UPDATE_REFERENCE = get(ENV, "UPDATE_REFERENCE", "false") == "true"

@testset "TAInvestmentPlanning" begin
    @testset "No case loaded" begin
        @test_throws ErrorException settings()
    end

    load_case!(TINY_CASE)

    @testset "Case settings" begin
        s = settings()
        @test case_name() == "tiny"
        @test s.title == "Tiny Test System"
        @test case_dir() == abspath(TINY_CASE)
        @test s.discount_rate == 0.07
        @test s.base_year == 2025
        @test s.financial.capital_recovery_period == 25
        @test s.tier2_fuel_limit_gal == 4.0e6
        @test s.tier2_hours_per_yr == 100.0
        @test s.tier2_hours_penalty_per_mwh == 500.0
        # Existing thermal units default to Tier 2; candidates carry their own tier
        @test unit_tier("Diesel_1") == 2
        @test unit_tier("Diesel_Recip_2MW_Main") == 4
        @test s.catalog["Diesel_Recip_2MW_Main"].tier == 4
        @test s.base_demand == (name = "Tiny_Demand", bus = "Main")
        @test isnothing(s.report_benchmarks)
        @test isempty(s.planned_additions)
        @test isfile(s.default_arrivals_path)

        @test IP.battery_candidate_name(only(s.candidates.battery)) == "Battery_1.0MW_4.0MWh"
        @test IP.diesel_candidate_name(only(s.candidates.diesel)) == "Diesel_Recip_2MW_Main"
        @test sort(collect(keys(s.catalog))) == ["Battery_1.0MW_4.0MWh", "Diesel_Recip_2MW_Main", "Wind_new_1"]
        @test s.catalog["Battery_1.0MW_4.0MWh"] == (kind = "Battery", pcm_bus = "East", power_mw = 1.0, energy_mwh = 4.0)
        @test IP.technology_kind("Wind_new_1") == "Wind"
        @test IP.technology_kind("Diesel_Recip_2MW_Main") == "Diesel"
        @test isnothing(IP.technology_kind("Not_A_Technology"))
        @test IP.default_pcm_sim_name() == "tiny_annual"
        @test s.capacity_credit == (method = "net_load", top_hours = 100)  # defaults
        @test s.capital_within_horizon
        @test IP.retired_capacity_mw("Wind_1", 2025) == 0.0
        @test IP.retired_capacity_mw("Wind_1", 2026) == 1.0
        @test IP.retired_capacity_mw("Diesel_1", 2030) == 0.0
    end

    @testset "Case functions" begin
        @test IP.case_default_diesel_price() == 4.0
        @test IP.case_fuel_hhv_mbtu_per_gal() == 0.138
        @test IP.case_base_peak_load_mw() == 8.0
        @test IP.case_operating_reserve_name() == "Tiny_Reserve"
        @test IP.case_rated_heat_rate("Diesel_1") == 10.0
        @test isnothing(IP.case_rated_heat_rate("Wind_1"))
        @test IP.case_candidate_heat_rate_curve(2.0)[end] == (2.0, 9.5)
        # Optional functions the tiny case does not define fall back to defaults
        @test IP.case_existing_availability_multiplier("Wind_1", 2030) == 1.0
        @test IP.adjust_pcm_system!(:sys, DateTime[]) == :sys
        @test IP.adjust_planning_system!(:sys, [2025]) == :sys

        sys, timestamps = IP.build_case_system(; verbose = false)
        wind_mw(s) = IP.PSY.with_units_base(() -> IP.PSY.get_max_active_power(IP.PSY.get_component(IP.PSY.RenewableDispatch, s, "Wind_1")),
                                            s, IP.PSY.UnitSystem.NATURAL_UNITS)
        @test wind_mw(IP._apply_planned_retirements!(IP.build_case_system()[1], 2025)) ≈ 3.0
        @test wind_mw(IP._apply_planned_retirements!(IP.build_case_system()[1], 2026)) ≈ 2.0
        @test first(timestamps) == DateTime(2025, 1, 1)
        @test last(timestamps) == DateTime(2027, 12, 31, 23)
        @test length(collect(IP.PSY.get_components(IP.PSY.ThermalStandard, sys))) == 1
    end

    @testset "Scenario inputs" begin
        scenarios = parse_arrivals_scenarios("")
        @test sort(collect(keys(scenarios))) == ["flat", "growth"]
        @test settings().default_scenario == "growth"
        arrival = only(default_arrivals())
        @test (arrival.year, arrival.mw, arrival.conforming, arrival.bus) == (2026, 4.0, false, "East")
        @test isnothing(arrival.custom_profile_path)

        # JSON string with several scenarios, and a bare list
        multi = parse_arrivals_scenarios("""{"a": [{"year": 2027, "mw": 1.5, "bus": "Main"}], "b": []}""")
        @test sort(collect(keys(multi))) == ["a", "b"]
        @test only(multi["a"]).conforming  # conforming defaults to true
        @test only(keys(parse_arrivals_scenarios("""[{"year": 2027, "mw": 1.0, "bus": "Main"}]"""))) == "default"
        @test_throws ErrorException parse_arrivals_scenarios("""{"a": [{"year": 2027, "mw": 1.0}]}""")
        @test_throws ErrorException parse_arrivals_scenarios("{}")
        @test_throws "file not found" parse_arrivals_scenarios("no_such_arrivals.json")
        err = try
            get_arrivals_for_scenario(multi, "missing")
        catch e
            e
        end
        @test err isa ErrorException && occursin("Available scenarios: a, b", err.msg)

        defaults = default_procurement_timelines()
        @test defaults["Wind_new_1"] == (2026, 9999)
        @test isnothing(parse_procurement_timelines(""))
        @test isnothing(parse_procurement_timelines("{}"))
        @test parse_procurement_timelines("""{"Wind_new_1": [2030, 2032]}""") == Dict("Wind_new_1" => (2030, 2032))
        @test_throws ErrorException parse_procurement_timelines("""{"Wind_new_1": [2030]}""")
        @test_throws ErrorException parse_procurement_timelines("[2030, 2032]")
        merged = merge_procurement_timelines(Dict("Wind_new_1" => (2027, 2027)))
        @test merged["Wind_new_1"] == (2027, 2027)
        @test merged["Battery_1.0MW_4.0MWh"] == (2025, 9999)

        builds = parse_exogenous_builds("""{"Battery_1.0MW_4.0MWh": {"2026": 1.0}, "Wind_new_1": {"2026": 0}}""")
        @test builds["Battery_1.0MW_4.0MWh"] == Dict(2026 => 1.0)
        @test builds["Wind_new_1"] == Dict(2026 => 0.0)
        @test isnothing(parse_exogenous_builds(""))
    end

    @testset "Investment intervals" begin
        arrivals = [
            LoadArrival(; year = 2027, mw = 1.0, conforming = true, bus = "Main"),
            LoadArrival(; year = 2029, mw = 2.0, conforming = false, bus = "East"),
            LoadArrival(; year = 2029, mw = 0.5, conforming = true, bus = "East"),
        ]
        intervals, peaks, rep_years = IP.compute_investment_intervals(arrivals)
        @test intervals == [
            (Date(2025, 1, 1), Date(2026, 12, 31)),
            (Date(2027, 1, 1), Date(2028, 12, 31)),
            (Date(2029, 1, 1), Date(2029, 12, 31)),
        ]
        @test peaks == [8.0, 9.0, 11.5]
        @test rep_years == [2025, 2027, 2029]

        # No arrivals: one interval in the base year at the base peak
        intervals, peaks, rep_years = IP.compute_investment_intervals(LoadArrival[])
        @test intervals == [(Date(2025, 1, 1), Date(2025, 12, 31))]
        @test peaks == [8.0]

        stamps = IP.build_rep_period_timestamps(2026)
        @test length(stamps) == 12 * 168
        @test stamps[1] == DateTime(2026, 1, 15)
        @test stamps[168 + 1] == DateTime(2026, 2, 15)

        timelines = Dict("Wind_new_1" => (2028, 2030))
        @test !IP.is_technology_available("Wind_new_1", 2027, timelines)
        @test IP.is_technology_available("Wind_new_1", 2030, timelines)
        @test IP.is_technology_available("Battery_1.0MW_4.0MWh", 2027, timelines)
        @test IP._investment_period_for_year(intervals, 2025) == 1
    end

    @testset "Helpers" begin
        curve = IP.diesel_io_curve([(1.0, 14.0), (2.0, 10.0)], 30.0)
        @test IP.IS.get_points(curve) == [(x = 0.0, y = 0.0), (x = 2.0, y = 600.0)]

        credits = Dict("Wind_new_1" => 0.35, "Wind_new_10" => 0.5, "Battery_1.0MW_4.0MWh" => 0.9)
        @test IP._credit_for_build_variable("BuildCapacity_SupplyTechnology_{Wind_new_10, 1}", credits) == 0.5
        @test IP._credit_for_build_variable("BuildCapacity_SupplyTechnology_{Wind_new_1, 1}", credits) == 0.35
        @test isnothing(IP._credit_for_build_variable("BuildCapacity_{Other, 1}", credits))

        @test set_slack_options!(; nodal = false) == (nodal = false, energy = true, reserve = true)
        @test Main.ENABLE_NODAL_SLACK == false
        set_slack_options!(; nodal = true)
        @test Main.ENABLE_NODAL_SLACK == true
    end

    @testset "Command-line arguments" begin
        args = parse_cmdline(String[])
        @test args["mode"] == "validate"
        @test isnothing(args["diesel-price"])
        @test IP._diesel_price(args) == 4.0
        @test IP._diesel_price(parse_cmdline(["cem", "--diesel-price=6.5"])) == 6.5
        @test isnothing(args["solver-time-limit"])
        @test IP._solver_time_limit(args) == 60.0  # tiny case [solver] time_limit_s
        @test IP._solver_time_limit(parse_cmdline(["cem", "--solver-time-limit=3600"])) == 3600.0
        @test IP._solver_time_limit(Dict{String, Any}()) == 60.0  # hand-built REPL args without the key
        @test args["enable-nodal-slack"] && !parse_cmdline(["--disable-nodal-slack"])["enable-nodal-slack"]

        # Without --scenario: the case default scenario, else the only scenario in the input
        name, _, arrivals = IP._select_arrivals(args)
        @test name == "growth" && length(arrivals) == 1
        @test first(IP._select_arrivals(parse_cmdline(["--arrivals={\"only\": []}"]))) == "only"
        two = parse_cmdline(["--arrivals={\"a\": [], \"b\": []}"])
        @test_throws ErrorException IP._select_arrivals(two)
        @test first(IP._select_arrivals(parse_cmdline(["--arrivals={\"a\": [], \"b\": []}", "--scenario=b"]))) == "b"
    end

    @testset "CEM and PCM on the tiny case" begin
        mktempdir() do dir
            cd(dir) do
                args = parse_cmdline(["validate", "--day-start=1", "--day-end=2", "--mip-gap=0.01"])
                cem_results, pcm_results = run_validation_workflow(args)

                cem = JSON.parsefile(joinpath("results", "planning", "growth", "summary.json"))
                pcm = JSON.parsefile(joinpath("results", "pcm", "pcm_summary_growth.json"))

                # Builds come from the catalog and respect the candidate sizes
                @test !isempty(cem["investments_mw"])
                for (tech, mw) in cem["investments_mw"]
                    @test haskey(settings().catalog, tech)
                end
                @test cem_results["investment_decisions"] == Dict{String, Float64}(cem["investments_mw"])

                # Fuel slack covers exactly the fuel above the annual limit in each interval
                limit = settings().tier2_fuel_limit_gal
                for (gal, slack) in zip(cem["tier2_gallons_per_interval"], cem["tier2_slack_gallons_per_interval"])
                    @test isapprox(slack, max(gal - limit, 0.0); atol = 1.0)
                end
                # One Tier 2 unit (Diesel_1); reported excess energy is nonnegative per interval
                @test length(cem["tier2_hours_excess_mwh_per_interval"]) == length(cem["tier2_gallons_per_interval"])
                @test all(>=(-1e-6), cem["tier2_hours_excess_mwh_per_interval"])

                # PCM: 48 h of 8 MW peak load (mean 0.65 of peak) plus the 4 MW flat arrival
                served = 8.0 * 0.65 * 48 + 4.0 * 48
                @test isapprox(pcm["total_mwh"], served; rtol = 0.02)
                @test pcm["hydro_mwh"] == 0.0
                @test pcm_results["results_dir"] == joinpath("results", "pcm", "sim_growth")

                if UPDATE_REFERENCE
                    mkpath(REFERENCE_DIR)
                    cp(joinpath("results", "planning", "growth", "summary.json"), joinpath(REFERENCE_DIR, "tiny_cem.json"); force = true)
                    cp(joinpath("results", "pcm", "pcm_summary_growth.json"), joinpath(REFERENCE_DIR, "tiny_pcm.json"); force = true)
                    @info "Updated tiny-case references in $REFERENCE_DIR"
                end

                # A forced build of a binary candidate fixes both its MW and its 0/1 build decision
                run_cem_workflow(parse_cmdline(["cem", "--day-start=1", "--day-end=2",
                    "--exogenous-builds={\"Wind_new_1\": {\"2026\": 1.5}}"]))
                forced = JSON.parsefile(joinpath("results", "planning", "growth", "summary.json"))
                @test forced["investments_mw"]["Wind_new_1"] ≈ 1.5

                ref_cem = JSON.parsefile(joinpath(REFERENCE_DIR, "tiny_cem.json"))
                ref_pcm = JSON.parsefile(joinpath(REFERENCE_DIR, "tiny_pcm.json"))
                @test cem["investments_mw"] == ref_cem["investments_mw"]
                @test isapprox(cem["objective"], ref_cem["objective"]; rtol = 1e-6)
                @test all(isapprox.(cem["tier2_gallons_per_interval"], ref_cem["tier2_gallons_per_interval"]; rtol = 1e-6))
                @test all(isapprox.(cem["tier2_hours_excess_mwh_per_interval"], ref_cem["tier2_hours_excess_mwh_per_interval"]; rtol = 1e-6, atol = 1e-3))
                for key in keys(ref_pcm)
                    @test isapprox(pcm[key], ref_pcm[key]; rtol = 1e-6)
                end
            end
        end
    end
end
