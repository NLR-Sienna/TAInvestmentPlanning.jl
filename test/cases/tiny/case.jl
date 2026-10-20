# Tiny test case code.
#
# Two buses (Main, East) joined by one line, a 12 MW diesel unit and an 8 MW peak load at Main,
# and a 3 MW wind plant at East. Hourly time series cover 2025-2027 so the CEM representative
# periods and the post-investment PCM year both have data. No hydro.

using PowerSystems
using Dates
using TimeSeries
using Random

const PSY = PowerSystems

const TINY = (
    diesel_price = 4.0,               # $/gal
    hhv_mbtu_per_gal = 0.138,
    peak_load_mw = 8.0,
    simulation_year = 2025,
    reserve_name = "Tiny_Reserve",
    wind_mw = 3.0,
    diesel_mw = 12.0,
    diesel_hr_curve = [(1.0, 14.0), (6.0, 11.0), (12.0, 10.0)],   # (MW, MBTU/MWh)
)

# Linear input-output curve through the rated point (same shape as the package's candidates)
function tiny_io_curve(hr_curve, fuel_price_per_mbtu)
    rated_mw, rated_hr = hr_curve[end]
    return PSY.PiecewiseLinearData([(0.0, 0.0), (rated_mw, rated_mw * rated_hr * fuel_price_per_mbtu)])
end

function build_tiny_system(; diesel_price::Float64 = TINY.diesel_price, verbose::Bool = false)
    # The CEM draws synthetic wind profiles from the global RNG; seed it for repeatable results
    Random.seed!(42)

    timestamps = collect(DateTime(2025, 1, 1) : Hour(1) : DateTime(2027, 12, 31, 23))
    # Component values below are per unit on each component's own base (input_basis = CU)
    sys = PSY.System(100.0; time_series_in_memory = true)

    main = PSY.ACBus(; number = 1, name = "Main", available = true, bustype = PSY.ACBusTypes.REF,
                     angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.95, max = 1.05), base_voltage = 69.0,
                     input_basis = u"CU")
    east = PSY.ACBus(; number = 2, name = "East", available = true, bustype = PSY.ACBusTypes.PQ,
                     angle = 0.0, magnitude = 1.0, voltage_limits = (min = 0.95, max = 1.05), base_voltage = 69.0,
                     input_basis = u"CU")
    PSY.add_component!(sys, main)
    PSY.add_component!(sys, east)

    PSY.add_component!(sys, PSY.Line(;
        name = "Main_East",
        available = true,
        arc = PSY.Arc(from = main, to = east),
        r = 0.01,
        x = 0.05,
        b = (from = 0.0, to = 0.0),
        rating = 0.5,
        angle_limits = (min = -π/2, max = π/2),
        active_power_flow = 0.0,
        reactive_power_flow = 0.0,
        input_basis = u"CU",
    ))

    fuel_price_mbtu = diesel_price / TINY.hhv_mbtu_per_gal
    diesel = PSY.ThermalStandard(;
        name = "Diesel_1",
        available = true,
        status = PSY.OperationalStates.OFFLINE,
        bus = main,
        active_power = 0.0,
        reactive_power = 0.0,
        rating = 1.0,
        prime_mover_type = PSY.PrimeMovers.IC,
        fuel = PSY.ThermalFuels.DISTILLATE_FUEL_OIL,
        active_power_limits = (min = 1.0 / TINY.diesel_mw, max = 1.0),
        reactive_power_limits = nothing,
        ramp_limits = (up = 1.0, down = 1.0),
        time_limits = (up = 1.0, down = 1.0),
        operation_cost = PSY.ThermalGenerationCost(;
            variable_operation_cost = PSY.CostCurve(;
                value_curve = PSY.InputOutputCurve(tiny_io_curve(TINY.diesel_hr_curve, fuel_price_mbtu)),
                power_units = PSY.NaturalUnit(),
            ),
            fixed = 10.0,
            start_up = 100.0,
            shut_down = 50.0,
        ),
        base_power = TINY.diesel_mw,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, diesel)

    wind = PSY.RenewableDispatch(;
        name = "Wind_1",
        available = true,
        bus = east,
        active_power = 0.0,
        reactive_power = 0.0,
        rating = 1.0,
        prime_mover_type = PSY.PrimeMovers.WT,
        reactive_power_limits = nothing,
        power_factor = 1.0,
        operation_cost = PSY.RenewableGenerationCost(nothing),
        base_power = TINY.wind_mw,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, wind)

    load = PSY.PowerLoad(;
        name = "Load_Main",
        available = true,
        bus = main,
        active_power = 0.5 * TINY.peak_load_mw,
        reactive_power = 0.0,
        base_power = 1.0,
        max_active_power = TINY.peak_load_mw,
        max_reactive_power = 0.0,
        input_basis = u"CU",
    )
    PSY.add_component!(sys, load)

    # Smooth deterministic profiles: seasonal and diurnal wind, diurnal load peaking at 1.0.
    # The operational models scale these normalized profiles by each device's max active power.
    wind_cf = [clamp(0.35 + 0.15 * cos(2π * dayofyear(t) / 365) + 0.10 * sin(2π * hour(t) / 24), 0.0, 1.0)
               for t in timestamps]
    load_profile = [0.65 + 0.35 * sin(2π * (hour(t) - 6) / 24) for t in timestamps]
    PSY.add_time_series!(sys, wind, PSY.SingleTimeSeries("max_active_power", TimeSeries.TimeArray(timestamps, wind_cf)))
    PSY.add_time_series!(sys, load, PSY.SingleTimeSeries("max_active_power", TimeSeries.TimeArray(timestamps, load_profile)))

    PSY.transform_single_time_series!(sys, Hour(48), Hour(24))

    reserve = PSY.OnlineReserve{PSY.ReserveUp}(;
        name = TINY.reserve_name,
        available = true,
        time_frame = 10.0,
        requirement = 0.5 / 100.0,
        sustained_time = 0.5,
        max_output_fraction = 1.0,
    )
    PSY.add_service!(sys, reserve, [diesel])

    verbose && @info "Built tiny system: $(length(timestamps)) hours"
    return sys, timestamps
end

# Case functions called by the workflows
case_default_diesel_price() = TINY.diesel_price
case_fuel_hhv_mbtu_per_gal() = TINY.hhv_mbtu_per_gal
case_base_peak_load_mw() = TINY.peak_load_mw
case_simulation_year() = TINY.simulation_year
case_operating_reserve_name() = TINY.reserve_name
case_hydro_rating_mw() = 0.0
case_wind_rating_mw() = TINY.wind_mw
case_rated_heat_rate(unit_name::AbstractString) = unit_name == "Diesel_1" ? TINY.diesel_hr_curve[end][2] : nothing
case_candidate_heat_rate_curve(capacity_mw::Float64) =
    [(0.25 * capacity_mw, 13.0), (0.5 * capacity_mw, 11.0), (capacity_mw, 9.5)]

build_case_system(; diesel_price::Float64 = case_default_diesel_price(), verbose::Bool = false) =
    build_tiny_system(; diesel_price = diesel_price, verbose = verbose)
