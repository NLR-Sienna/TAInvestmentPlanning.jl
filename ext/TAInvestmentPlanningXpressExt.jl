# Xpress solver for TAInvestmentPlanning, loaded when Xpress.jl is (see set_solver!)
module TAInvestmentPlanningXpressExt

import TAInvestmentPlanning
import Xpress

# Xpress names the options MIPRELSTOP (relative gap), MAXTIME (seconds; negative stops at the limit
# even without a solution, as HiGHS time_limit does), and OUTPUTLOG (0 = silent)
_xpress_optimizer(mip_gap, time_limit, silent) = TAInvestmentPlanning.JuMP.optimizer_with_attributes(
    Xpress.Optimizer,
    "MIPRELSTOP" => mip_gap,
    (isnothing(time_limit) ? () : ("MAXTIME" => -floor(Int, time_limit),))...,
    "OUTPUTLOG" => silent ? 0 : 1,
)

# An Xpress Community license solves only problems of up to 5000 rows and columns; Xpress does not
# start larger solves and reports no solution, so say so when one is in use
function _warn_community_license()
    file = try
        Xpress._get_xpauthpath("", false)
    catch
        return
    end
    if isfile(file) && occursin("Community", read(file, String))
        @warn "Xpress is using a Community license ($file), which solves problems of up to 5000 rows " *
              "and columns only. Larger CEM and PCM problems will fail with no solution; set XPAUTH_PATH " *
              "to a full Xpress license or use --solver=highs."
    end
    return
end

function __init__()
    TAInvestmentPlanning._OPTIMIZERS["xpress"] = _xpress_optimizer
    _warn_community_license()
    return
end

end
