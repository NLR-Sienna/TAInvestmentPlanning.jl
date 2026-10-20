# src/load_analytics.jl
#
# Load data retrieval with proper time series multiplier application.
# Extends PowerAnalytics.get_load_data() to apply load scaling factors.

"""
Time series by component (`data`) on a shared time axis (`time`). Same layout as the
`PowerData` that PowerAnalytics provided before its PowerSystems 6 update.
"""
struct PowerData
    data::Dict{Symbol, DataFrames.DataFrame}
    time::Union{StepRange{Dates.DateTime}, Vector{Dates.DateTime}}
end

"""
    get_load_data_with_multipliers(system::PSY.System; kwargs...) -> PowerData

Retrieve load time series with proper multiplier application.

Returns a PowerData object matching PowerAnalytics.get_load_data() structure:
- One key per individual load component (not aggregated)
- Each DataFrame has one column with that load's per-unit time series
- Time array contains hourly timestamps

This version operates on SingleTimeSeries (the base time series after build).

Parameters:
  system      : PowerSystems.System
  kwargs      : start_time, other kwargs (passed through but typically unused)

Returns:
  PowerData with individual load DataFrames and time axis
"""
function get_load_data_with_multipliers(
    system::PSY.System;
    kwargs...,
)
    initial_time = get(kwargs, :initial_time, PSY.get_forecast_initial_timestamp(system))

    parameters = Dict{Symbol, DataFrames.DataFrame}()

    resolution = nothing

    # Get all loads in system
    loads = PSY.get_components(PSY.PowerLoad, system)

    for load in loads
        load_name = PSY.get_name(load)

        # Use the SingleTimeSeries (base data) for this load
        if !PSY.has_time_series(load, PSY.SingleTimeSeries, "max_active_power")
            @warn "Load $load_name has no SingleTimeSeries with name 'max_active_power'"
            continue
        end

        ts = PSY.get_time_series(PSY.SingleTimeSeries, load, "max_active_power"; start_time = initial_time)
        my_resolution = PSY.get_resolution(ts)

        if isnothing(resolution)
            resolution = my_resolution
        else
            (resolution != my_resolution) &&
                throw(error("Load time series have mismatched resolutions"))
        end

        # The series is a normalized profile; scale it to per-unit on system base
        f = TimeSeries.values(PSY.get_data(ts)) .* PSY.get_max_active_power(load, u"SU")

        # Create a DataFrame with one column per load (matching PowerAnalytics structure)
        parameters[Symbol(load_name)] = DataFrames.DataFrame(Symbol(load_name) => f)
    end

    # Construct time range from resolution and data length
    time_range = if !isnothing(resolution) && !isempty(parameters)
        # Get the first DataFrame from the parameters dict
        first_df = first(values(parameters))
        if !isempty(first_df)
            nrows = nrow(first_df)
            collect(
                range(
                    initial_time;
                    step = resolution,
                    length = nrows,
                ),
            )
        else
            Dates.DateTime[]
        end
    else
        Dates.DateTime[]
    end

    return PowerData(parameters, time_range)
end

"""
    sum_load_data(pd::PowerData) -> DataFrame

Sum load data across all load components to get total system load.

Iterates through each row of each load DataFrame and sums across all columns,
producing a single-column DataFrame with total system load per timestep.

Input:  PowerData where pd.data contains individual load DataFrames
Output: DataFrame with single column "Total" containing total system load per hour (per-unit)
"""
function sum_load_data(pd::PowerData)::DataFrames.DataFrame
    result = DataFrames.DataFrame(Total = Float64[])

    if isempty(pd.data)
        @warn "PowerData contains no load data"
        return result
    end

    # Get all load DataFrames and stack them column-wise
    dfs = collect(values(pd.data))
    if isempty(dfs)
        return result
    end

    # Number of timesteps (all DataFrames should have same length)
    nrows = nrow(first(dfs))

    # Sum across all loads for each row
    for i in 1:nrows
        row_total = 0.0
        for df in dfs
            row_total += df[i, 1]  # Each load DataFrame has one column
        end
        push!(result, (Total=row_total,))
    end

    return result
end
