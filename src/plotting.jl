# src/plotting.jl
#
# Plotting functions for PCM results using PowerGraphics.jl

"""
    plot_generation_bar(uc_results; scenario::String="unknown", curtailment::Bool=false, bar::Bool=true,
                        output_dir::String="results/plots")

Generate a bar plot of aggregated generation by fuel type from UC results.
Extracts total generation (MWh) for each resource and displays as bar chart.

Arguments:
  uc_results: Unit commitment results from PowerSimulations
  scenario: Scenario name for plot title
  curtailment: Whether to include curtailment data (currently ignored)
  bar: If true, creates bar chart; if false, creates other format
  output_dir: Directory where the HTML plot is saved

Returns:
  PlotlyJS plot object
"""
function plot_generation_bar(uc_results; scenario::String="unknown", curtailment::Bool=false, bar::Bool=true,
                             output_dir::String="results/plots")
    try
        # Extract generation data directly from results
        # Try HydroTurbine first, fall back to HydroDispatch
        hydro_p = try
            PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.HydroTurbine)
        catch
            try
                PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.HydroDispatch)
            catch
                DataFrame()
            end
        end
        wind_p = try
            PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.RenewableDispatch)
        catch
            # If wind uses FixedOutput model, try reading as parameter
            try
                PSI.read_realized_parameter(uc_results, "ActivePowerTimeSeriesParameter__RenewableDispatch")
            catch
                DataFrame()
            end
        end
        diesel_p = PSI.read_realized_variable(uc_results, PSI.ActivePowerVariable, PSY.ThermalStandard)

        # Sum each fuel type (hourly values sum to MWh)
        hydro_total = isempty(hydro_p) ? 0.0 : sum(sum(skipmissing(col)) for col in eachcol(hydro_p) if eltype(col) <: Number)
        wind_total = isempty(wind_p) ? 0.0 : sum(sum(skipmissing(col)) for col in eachcol(wind_p) if eltype(col) <: Number)
        diesel_total = isempty(diesel_p) ? 0.0 : sum(sum(skipmissing(col)) for col in eachcol(diesel_p) if eltype(col) <: Number)

        total = hydro_total + wind_total + diesel_total

        if bar
            # Create bar chart
            trace = PlotlyJS.bar(
                x = ["Hydro", "Wind", "Diesel"],
                y = [hydro_total, wind_total, diesel_total],
                marker_color = ["#1f77b4", "#2ca02c", "#d62728"],
                text = [@sprintf("%.0f MWh\n(%.1f%%)", hydro_total, 100*hydro_total/max(total, 1)),
                        @sprintf("%.0f MWh\n(%.1f%%)", wind_total, 100*wind_total/max(total, 1)),
                        @sprintf("%.0f MWh\n(%.1f%%)", diesel_total, 100*diesel_total/max(total, 1))],
                textposition = "outside",
                hovertemplate = "<b>%{x}</b><br>Energy: %{y:.0f} MWh<extra></extra>",
            )

            layout = Layout(
                title = "Annual Generation by Fuel Type ($scenario)",
                xaxis_title = "Resource",
                yaxis_title = "Energy (MWh)",
                height = 500,
                showlegend = false,
                hovermode = "closest",
            )
        else
            # Alternative format (currently same as bar)
            trace = PlotlyJS.bar(
                x = ["Hydro", "Wind", "Diesel"],
                y = [hydro_total, wind_total, diesel_total],
                marker_color = ["#1f77b4", "#2ca02c", "#d62728"],
            )

            layout = Layout(
                title = "Annual Generation by Fuel Type ($scenario)",
                yaxis_title = "Energy (MWh)",
                height = 500,
            )
        end

        p = PlotlyJS.plot([trace], layout)
        mkpath(output_dir)
        PlotlyJS.savefig(p, joinpath(output_dir, "generation_resource_$(scenario).html"))

        return PlotlyJS.plot([trace], layout)
    catch e
        @warn "Error generating fuel plot: $e"
        return nothing
    end
end

"""
    plot_reserve_timeseries(uc_results; scenario::String="unknown")

Generate a stacked area plot of reserve provision by generator with unmet reserve as overlay line.
Uses PowerGraphics plot_dataframe for stacking reserve provision by thermal generator.

Arguments:
  uc_results: Unit commitment results from PowerSimulations
  scenario: Scenario name for plot title

Returns:
  PlotlyJS plot object
"""
function plot_reserve_timeseries(uc_results; scenario::String="unknown")
    try
        # Read reserve provision by generator (contributions to reserve)
        reserve_provision = unstack(
            PSI.read_realized_variable(uc_results, PSI.ActivePowerReserveVariable, PSY.ConstantReserve{ReserveUp}, case_operating_reserve_name()),
            :DateTime,
            :name,
            :value
        )

        # Read unmet reserve (slack - shortage when positive)
        unmet_reserve = unstack(
            PSI.read_realized_variable(uc_results, PSI.ReserveRequirementSlack, PSY.ConstantReserve{ReserveUp}, case_operating_reserve_name()),
            :DateTime,
            :name,
            :value
        )
        DataFrames.rename!(unmet_reserve, Symbol("ReserveRequirementSlack__ConstantReserve__ReserveUp__" * case_operating_reserve_name()) => :Unmet_Reserve)


        p = PG.plot_dataframe(unmet_reserve,
            seriescolor = [:red]);
        p = PG.plot_dataframe!(p, reserve_provision,
            title = "Operating Reserve Provision by Generator ($scenario)",
            xlabel = "Time",
            ylabel = "Reserve (MW)",
            stack = true,
            legend = :topright,
            display = false);


        return p;

    catch e
        @warn "Failed to create reserve plot: $e"
        return nothing
    end
end

function plot_generation_by_resource(uc_results; scenario::String="unknown")
    # Wrapper for backwards compatibility
    return plot_generation_bar(uc_results; scenario=scenario, curtailment=false, bar=true)
end

"""
    plot_pcm_results(pcm_results::Dict; output_dir::String="results/plots") -> String

Generate and save plots for PCM simulation results.

Creates plots showing fuel consumption, generation by resource, and system operation.

Arguments:
  pcm_results: Dict with keys "simulation", "system", "scenario", "results_dir"
  output_dir: Directory where plots will be saved

Returns:
  Path to the plots directory

Example:
  pcm_results = run_pcm_workflow(args)
  plot_pcm_results(pcm_results)
"""
function plot_pcm_results(pcm_results::Dict; output_dir::String="results/plots")
    sim = get(pcm_results, "simulation", nothing)
    scenario = get(pcm_results, "scenario", "unknown")

    if isnothing(sim)
        @warn "No simulation object in pcm_results; skipping plots"
        return ""
    end

    mkpath(output_dir)

    try
        @info "Generating PCM results plots..."

        # Get simulation results
        sim_results = PSI.SimulationResults(sim)
        uc_results = PSI.get_decision_problem_results(sim_results, "UC")

        # Create fuel plot
        @info "  Creating fuel/generation plots..."
        fuel_plot = try
            PG.plot_fuel(uc_results, title="Fuel Mix - $(String(scenario))", curtailment=false)
        catch e
            @warn "Failed to create fuel plot: $e"
            nothing
        end

        if !isnothing(fuel_plot)
            fuel_plot_path = joinpath(output_dir, "fuel_generation_$(scenario)")
            try
                PG.save_plot(fuel_plot, fuel_plot_path * ".png")
                PG.save_plot(fuel_plot, fuel_plot_path * ".html")
                PG.save_plot(fuel_plot, fuel_plot_path * ".svg")
                @info "  ✓ Fuel plot saved: $fuel_plot_path"
            catch e
                @warn "Failed to save fuel plot: $e"
            end
        end

        # PowerGraphics fuel plot (alternative rendering)
        @info "  Creating PowerGraphics fuel plot..."
        pg_fuel_plot = try
            PG.plot_fuel(uc_results, title="Fuel Mix - $(String(scenario))", curtailment=false)
        catch e
            @warn "PowerGraphics fuel plot not available (may be due to wind model): $e"
            nothing
        end

        if !isnothing(pg_fuel_plot)
            pg_fuel_plot_path = joinpath(output_dir, "pg_fuel_$(scenario)")
            try
                PG.save_plot(pg_fuel_plot, pg_fuel_plot_path * ".png")
                PG.save_plot(pg_fuel_plot, pg_fuel_plot_path * ".html")
                PG.save_plot(pg_fuel_plot, pg_fuel_plot_path * ".svg")
                @info "  ✓ PowerGraphics fuel plot saved: $pg_fuel_plot_path"
            catch e
                @warn "Failed to save PowerGraphics fuel plot: $e"
            end
        end

        # PowerGraphics generation plot
        @info "  Creating generation plots..."
        gen_plot = try
            PG.plot_fuel(uc_results, title=String(scenario), curtailment=false, bar=true)
        catch e
            @warn "Generation plot not available: $e"
            nothing
        end

        if !isnothing(gen_plot)
            gen_plot_path = joinpath(output_dir, "generation_$(scenario)")
            try
                PG.save_plot(gen_plot, gen_plot_path * ".png")
                PG.save_plot(gen_plot, gen_plot_path * ".html")
                PG.save_plot(gen_plot, gen_plot_path * ".svg")
                @info "  ✓ Generation plot saved: $gen_plot_path"
            catch e
                @warn "Failed to save generation plot: $e"
            end
        end

        # PowerGraphics demand plot
        @info "  Creating demand/load plots..."
        demand_plot = try
            PG.plot_demand(uc_results)
        catch e
            @warn "Demand plot not available: $e"
            nothing
        end

        if !isnothing(demand_plot)
            demand_plot_path = joinpath(output_dir, "demand_$(scenario)")
            try
                PG.save_plot(demand_plot, demand_plot_path * ".png")
                PG.save_plot(demand_plot, demand_plot_path * ".html")
                PG.save_plot(demand_plot, demand_plot_path * ".svg")
                @info "  ✓ Demand plot saved: $demand_plot_path"
            catch e
                @warn "Failed to save demand plot: $e"
            end
        end

        # Reserve requirement and unmet reserve plot
        @info "  Creating reserve plots..."
        reserve_plot = try
            plot_reserve_timeseries(uc_results; scenario=String(scenario))
        catch e
            @warn "Reserve plot not available: $e"
            nothing
        end

        @info "PCM plots generated → $output_dir"
        return output_dir

    catch e
        @error "Error generating PCM plots: $e"
        return ""
    end
end

"""
    plot_pcm_comparison(pcm_no_battery::Dict, pcm_with_battery::Dict;
                       output_dir::String="results/plots") -> String

Generate comparison plots for battery vs no-battery scenarios.

Arguments:
  pcm_no_battery: PCM results without battery
  pcm_with_battery: PCM results with battery
  output_dir: Directory where plots will be saved

Returns:
  Path to the plots directory
"""
function plot_pcm_comparison(pcm_no_battery::Dict, pcm_with_battery::Dict;
                            output_dir::String="results/plots")
    mkpath(output_dir)

    @info "Generating comparison plots..."

    # Plot both scenarios side-by-side
    try
        plot_pcm_results(pcm_no_battery; output_dir=joinpath(output_dir, "no_battery"))
        plot_pcm_results(pcm_with_battery; output_dir=joinpath(output_dir, "with_battery"))

        @info "Comparison plots generated → $output_dir"
        return output_dir
    catch e
        @error "Error generating comparison plots: $e"
        return ""
    end
end
