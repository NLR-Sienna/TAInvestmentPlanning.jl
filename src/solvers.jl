# MILP solver for the CEM and PCM: HiGHS (default) or Xpress. Xpress is optional: it is loaded from
# the active environment when selected (Pkg.add("Xpress"), with an Xpress installation and license),
# and the TAInvestmentPlanningXpressExt extension adds it to _OPTIMIZERS.

const _SOLVER = Ref("highs")
const _XPRESS_PKGID = Base.PkgId(Base.UUID("9e70acf3-d6c9-5be6-b5bd-4e2c73e3e054"), "Xpress")

# Solver name => (mip_gap, time_limit in seconds or nothing, silent) -> optimizer. Each solver has
# its own names for these options.
const _OPTIMIZERS = Dict{String, Function}(
    "highs" => (mip_gap, time_limit, silent) -> optimizer_with_attributes(
        HiGHS.Optimizer,
        "mip_rel_gap" => mip_gap,
        (isnothing(time_limit) ? () : ("time_limit" => Float64(time_limit),))...,
        "output_flag" => !silent,
        "log_to_console" => !silent,
    ),
)

"""
    set_solver!(name)

Solver for the CEM and PCM: `"highs"` (default) or `"xpress"`. Xpress needs Xpress.jl in the active
environment and an Xpress installation and license.
"""
function set_solver!(name::AbstractString)
    name = lowercase(name)
    if name == "xpress" && !haskey(_OPTIMIZERS, name)
        try
            Base.require(_XPRESS_PKGID)  # loads TAInvestmentPlanningXpressExt, which registers Xpress
        catch e
            error("The xpress solver needs Xpress.jl in the active environment (Pkg.add(\"Xpress\")) " *
                  "and an Xpress installation:\n$(sprint(showerror, e))")
        end
    end
    haskey(_OPTIMIZERS, name) || error("Unknown solver \"$name\". Solvers: highs, xpress")
    _SOLVER[] = name
    return name
end

"Name of the solver used by the CEM and PCM (see [`set_solver!`](@ref))."
solver_name() = _SOLVER[]

# Optimizer for the selected solver
_optimizer(; mip_gap::Real, time_limit = nothing, silent::Bool = true) =
    Base.invokelatest(_OPTIMIZERS[_SOLVER[]], Float64(mip_gap), time_limit, silent)
