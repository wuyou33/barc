#!/usr/bin/env julia

using RobotOS
@rosimport barc.msg: ECU, pos_info
@rosimport data_service.msg: TimeData
@rosimport geometry_msgs.msg: Vector3
rostypegen()
using barc.msg
using data_service.msg
using geometry_msgs.msg
using JuMP
using Ipopt
using JLD

# log msg
include("barc_lib/classes.jl")
include("barc_lib/LMPC/MPC_models.jl")
include("barc_lib/LMPC/coeffConstraintCost.jl")
include("barc_lib/LMPC/solveMpcProblem.jl")
include("barc_lib/LMPC/functions.jl")

# This function is called whenever a new state estimate is received.
# It saves this estimate in oldTraj and uses it in the MPC formulation (see in main)
function SE_callback(msg::pos_info,lapStatus::LapStatus,posInfo::PosInfo,mpcSol::MpcSol,oldTraj::OldTrajectory,coeffCurvature_update::Array{Float64,1},z_est::Array{Float64,1},x_est::Array{Float64,1})         # update current position and track data
    # update mpc initial condition
    z_est[:]                  = [msg.v_x,msg.v_y,msg.psiDot,msg.epsi,msg.ey,msg.s]             # use z_est as pointer
    coeffCurvature_update[:]  = msg.coeffCurvature
    x_est[:]                  = [msg.x,msg.y,msg.psi,msg.v]
    
    # check if lap needs to be switched
    if z_est[6] % posInfo.s_target <= lapStatus.s_lapTrigger && lapStatus.switchLap
        lapStatus.currentLap += 1
        lapStatus.nextLap = true
        lapStatus.switchLap = false
    elseif z_est[6] > lapStatus.s_lapTrigger
        lapStatus.switchLap = true
    end

    # save current state in oldTraj
    oldTraj.oldTraj[oldTraj.count[lapStatus.currentLap],:,lapStatus.currentLap] = z_est
    oldTraj.oldInput[oldTraj.count[lapStatus.currentLap],:,lapStatus.currentLap] = [mpcSol.a_x,mpcSol.d_f]
    oldTraj.oldTimes[oldTraj.count[lapStatus.currentLap],lapStatus.currentLap] = to_sec(msg.header.stamp)
    oldTraj.count[lapStatus.currentLap] += 1

    # if necessary: append to end of previous lap
    if lapStatus.currentLap > 1 && z_est[6] < 3.0
        oldTraj.oldTraj[oldTraj.count[lapStatus.currentLap-1],:,lapStatus.currentLap-1] = z_est
        oldTraj.oldTraj[oldTraj.count[lapStatus.currentLap-1],6,lapStatus.currentLap-1] += posInfo.s_target
        oldTraj.oldInput[oldTraj.count[lapStatus.currentLap-1],:,lapStatus.currentLap-1] = [mpcSol.a_x,mpcSol.d_f]
        oldTraj.oldTimes[oldTraj.count[lapStatus.currentLap-1],lapStatus.currentLap-1] = to_sec(msg.header.stamp)
        oldTraj.count[lapStatus.currentLap-1] += 1
    end

    #if necessary: append to beginning of next lap
    if z_est[6] > posInfo.s_target - 3.0
        oldTraj.oldTraj[oldTraj.count[lapStatus.currentLap+1],:,lapStatus.currentLap+1] = z_est
        oldTraj.oldTraj[oldTraj.count[lapStatus.currentLap+1],6,lapStatus.currentLap+1] -= posInfo.s_target
        oldTraj.oldInput[oldTraj.count[lapStatus.currentLap+1],:,lapStatus.currentLap+1] = [mpcSol.a_x,mpcSol.d_f]
        oldTraj.oldTimes[oldTraj.count[lapStatus.currentLap+1],lapStatus.currentLap+1] = to_sec(msg.header.stamp)
        oldTraj.count[lapStatus.currentLap+1] += 1
    end
end

# This is the main function, it is called when the node is started.
function main()
    println("Starting LMPC node.")

    buffersize                  = 2000       # size of oldTraj buffers

    # Define and initialize variables
    # ---------------------------------------------------------------
    # General LMPC variables
    oldTraj                     = OldTrajectory()
    posInfo                     = PosInfo()
    mpcCoeff                    = MpcCoeff()
    lapStatus                   = LapStatus(1,1,false,false,0.3)
    mpcSol                      = MpcSol()
    trackCoeff                  = TrackCoeff()      # info about track (at current position, approximated)
    modelParams                 = ModelParams()
    mpcParams                   = MpcParams()
    mpcParams_pF                = MpcParams()       # for 1st lap (path following)

    InitializeParameters(mpcParams,mpcParams_pF,trackCoeff,modelParams,posInfo,oldTraj,mpcCoeff,lapStatus,buffersize)
    mdl    = MpcModel(mpcParams,mpcCoeff,modelParams,trackCoeff)
    mdl_pF = MpcModel_pF(mpcParams_pF,modelParams,trackCoeff)

    # ROS-specific variables
    z_est                       = zeros(6)          # this is a buffer that saves current state information (xDot, yDot, psiDot, ePsi, eY, s)
    x_est                       = zeros(4)          # this is a buffer that saves further state information (x, y, psi, v)
    coeffX                      = zeros(9)          # buffer for coeffX (only logging)
    coeffY                      = zeros(9)          # buffer for coeffY (only logging)
    cmd                         = ECU()      # command type
    coeffCurvature_update       = zeros(trackCoeff.nPolyCurvature+1)

    # Logging variables
    log_coeff_Cost              = zeros(mpcCoeff.order+1,2,10000)
    log_coeff_Const             = zeros(mpcCoeff.order+1,2,5,10000)
    log_sol_z                   = zeros(mpcParams.N+1,6,10000)
    log_sol_u                   = zeros(mpcParams.N,2,10000)
    log_curv                    = zeros(10000,trackCoeff.nPolyCurvature+1)
    log_state_x                 = zeros(10000,4)
    log_coeffX                  = zeros(10000,9)
    log_coeffY                  = zeros(10000,9)
    log_t                       = zeros(10000,1)
    log_state                   = zeros(10000,6)
    log_cost                    = zeros(10000,6)
    log_c_Vx                    = zeros(10000,3)
    log_c_Vy                    = zeros(10000,4)
    log_c_Psi                   = zeros(10000,3)
    log_cmd                     = zeros(10000,2)
    log_step_diff               = zeros(10000,5)
    
    # Initialize ROS node and topics
    init_node("mpc_traj")
    loop_rate = Rate(10)
    pub = Publisher("ecu", ECU, queue_size=1)::RobotOS.Publisher{barc.msg.ECU}
    # The subscriber passes arguments (coeffCurvature and z_est) which are updated by the callback function:
    s1 = Subscriber("pos_info", pos_info, SE_callback, (lapStatus,posInfo,mpcSol,oldTraj,coeffCurvature_update,z_est,x_est),queue_size=1)::RobotOS.Subscriber{barc.msg.pos_info}

    run_id = get_param("run_id")
    println("Finished initialization.")
    
    # buffer in current lap
    zCurr                       = zeros(10000,6)    # contains state information in current lap (max. 10'000 steps)
    uCurr                       = zeros(10000,2)    # contains input information
    u_final                     = zeros(2)          # contains last input of one lap
    step_diff                   = zeros(5)

    # Specific initializations:
    lapStatus.currentLap    = 1
    lapStatus.currentIt     = 1
    posInfo.s_target        = 17.76# 12.0#24.0
    k                       = 0                       # overall counter for logging
    
    mpcSol.z = zeros(11,4)
    mpcSol.u = zeros(10,2)
    mpcSol.a_x = 0
    mpcSol.d_f = 0
    
    # Precompile coeffConstraintCost:
    oldTraj.oldTraj[1:buffersize,6,1] = linspace(0,posInfo.s_target,buffersize)
    oldTraj.oldTraj[1:buffersize,6,2] = linspace(0,posInfo.s_target,buffersize)
    posInfo.s = posInfo.s_target/2
    lapStatus.currentLap = 3
    oldTraj.count[3] = 200
    coeffConstraintCost(oldTraj,mpcCoeff,posInfo,mpcParams,lapStatus)
    oldTraj.count[3] = 1
    lapStatus.currentLap = 1
    oldTraj.oldTraj[1:buffersize,6,1] = NaN*ones(buffersize,1)
    oldTraj.oldTraj[1:buffersize,6,2] = NaN*ones(buffersize,1)
    posInfo.s = 0

    uPrev = zeros(10,2)     # saves the last 10 inputs (1 being the most recent one)

    n_pf = 3        # number of first path-following laps (needs to be at least 2)

    # Start node
    while ! is_shutdown()
        if z_est[6] > 0         # check if data has been received (s > 0)
            # ============================= PUBLISH COMMANDS =============================
            # This is done at the beginning of the lap because this makes sure that the command is published 0.1s after the state has been received
            # This guarantees a constant publishing frequency of 10 Hz
            # (The state can be predicted by 0.1s)
            cmd.header.stamp = get_rostime()
            cmd.motor = convert(Float32,mpcSol.a_x)
            cmd.servo = convert(Float32,mpcSol.d_f)
            publish(pub, cmd)
            # ============================= Initialize iteration parameters =============================
            i                           = lapStatus.currentIt           # current iteration number, just to make notation shorter
            zCurr[i,:]                  = copy(z_est)                   # update state information
            posInfo.s                   = zCurr[i,6]                    # update position info
            trackCoeff.coeffCurvature   = copy(coeffCurvature_update)

            # ============================= Pre-Logging (before solving) ================================
            log_t[k+1]                  = to_sec(get_rostime())         # time is measured *before* solving (more consistent that way)
            if size(mpcSol.z,2) <= 4                                    # find 1-step-error
                step_diff = ([mpcSol.z[2,4], 0, 0, mpcSol.z[2,3], mpcSol.z[2,2]]-[norm(zCurr[i,1:2]), 0, 0, zCurr[i,4], zCurr[i,5]]).^2
            else
                step_diff = (mpcSol.z[2,1:5][:]-zCurr[i,1:5][:]).^2
            end
            log_step_diff[k+1,:]          = step_diff

            # ======================================= Lap trigger =======================================
            if lapStatus.nextLap                # if we are switching to the next lap...
                println("Finishing one lap at iteration $i")
                println("current state:  $(zCurr[i,:])")
                println("previous state: $(zCurr[i-1,:])")
                # Important: lapStatus.currentIt is now the number of points up to s > s_target -> -1 in saveOldTraj
                zCurr[1,:] = zCurr[i,:]         # copy current state
                u_final    = uCurr[i-1,:]       # ... and input
                i                     = 1
                lapStatus.currentIt   = 1       # reset current iteration
                lapStatus.nextLap = false
                # Set warm start for new solution (because s shifted by s_target)
                if lapStatus.currentLap <= n_pf
                    setvalue(mdl_pF.z_Ol[:,1],mpcSol.z[:,1]-posInfo.s_target)
                elseif lapStatus.currentLap > n_pf+1
                    setvalue(mdl.z_Ol[:,6],mpcSol.z[:,6]-posInfo.s_target)
                end
            end

            #  ======================================= Calculate input =======================================
            println("=================================== NEW ITERATION # $i ===================================")
            println("Current Lap: $(lapStatus.currentLap), It: $(lapStatus.currentIt)")
            println("State Nr. $i    = $z_est")
            println("s               = $(posInfo.s)")
            println("s_total         = $(posInfo.s%posInfo.s_target)")

            # Find coefficients for cost and constraints
            if lapStatus.currentLap > n_pf
                tic()
                coeffConstraintCost(oldTraj,mpcCoeff,posInfo,mpcParams,lapStatus)
                tt = toq()
                println("Finished coefficients, t = $tt s")
            end

            println("Starting solving.")
            # Solve the MPC problem
            tic()
            if lapStatus.currentLap <= n_pf
                z_pf = [zCurr[i,6],zCurr[i,5],zCurr[i,4],norm(zCurr[i,1:2])]        # use kinematic model and its states
                solveMpcProblem_pathFollow(mdl_pF,mpcSol,mpcParams_pF,trackCoeff,posInfo,modelParams,z_pf,uPrev)
            else                        # otherwise: use system-ID-model
                #mpcCoeff.c_Vx[3] = max(mpcCoeff.c_Vx[3],0.1)
                solveMpcProblem(mdl,mpcSol,mpcCoeff,mpcParams,trackCoeff,lapStatus,posInfo,modelParams,zCurr[i,:]',uPrev[1,:])
            end
            tt = toq()

            # Write current input information
            uCurr[i,:] = [mpcSol.a_x mpcSol.d_f]
            zCurr[i,6] = posInfo.s%posInfo.s_target   # save absolute position in s (for oldTrajectory)

            uPrev = circshift(uPrev,1)
            uPrev[1,:] = uCurr[i,:]
            println("Finished solving, status: $(mpcSol.solverStatus), u = $(uCurr[i,:]), t = $tt s")

            # Logging
            # ---------------------------
            k = k + 1       # counter
            log_state[k,:]          = zCurr[i,:]
            log_cmd[k+1,:]          = uCurr[i,:]                    # the command is going to be pubished in the next iteration
            log_sol_u[:,:,k]        = mpcSol.u
            log_coeff_Cost[:,:,k]   = mpcCoeff.coeffCost
            log_coeff_Const[:,:,:,k] = mpcCoeff.coeffConst
            log_cost[k,:]           = mpcSol.cost
            log_curv[k,:]           = trackCoeff.coeffCurvature
            log_state_x[k,:]        = x_est
            log_c_Vx[k,:]           = mpcCoeff.c_Vx
            log_c_Vy[k,:]           = mpcCoeff.c_Vy
            log_c_Psi[k,:]          = mpcCoeff.c_Psi
            if lapStatus.currentLap <= n_pf
                log_sol_z[:,1:4,k]        = mpcSol.z        # only 4 states during path following mode (first 2 laps)
            else
                log_sol_z[:,1:6,k]        = mpcSol.z
            end

            # Count one up:
            lapStatus.currentIt += 1
        else
            println("No estimation data received!")
        end
        rossleep(loop_rate)
    end
    # Save simulation data to file

    log_path = "$(homedir())/simulations/output-LMPC-$(run_id[1:4]).jld"
    if isfile(log_path)
        log_path = "$(homedir())/simulations/output-LMPC-$(run_id[1:4])-2.jld"
        warn("Warning: File already exists.")
    end
    save(log_path,"oldTraj",oldTraj,"state",log_state[1:k,:],"t",log_t[1:k],"sol_z",log_sol_z[:,:,1:k],"sol_u",log_sol_u[:,:,1:k],
                    "cost",log_cost[1:k,:],"curv",log_curv[1:k,:],"coeffCost",log_coeff_Cost,"coeffConst",log_coeff_Const,
                    "x_est",log_state_x[1:k,:],"coeffX",log_coeffX[1:k,:],"coeffY",log_coeffY[1:k,:],"c_Vx",log_c_Vx[1:k,:],
                    "c_Vy",log_c_Vy[1:k,:],"c_Psi",log_c_Psi[1:k,:],"cmd",log_cmd[1:k,:],"step_diff",log_step_diff[1:k,:])
    println("Exiting LMPC node. Saved data to $log_path.")

end

if ! isinteractive()
    main()
end

# Sequence within one iteration:
# 1. Publish commands from last iteration (because the car is in real *now* where we thought it was before (predicted state))
# 2. Receive new state information
# 3. Check if we've crossed the finish line and if we have, switch lap number and save old trajectories
# 4. (If in 3rd lap): Calculate coefficients
# 5. Calculate MPC commands (depending on lap) which are going to be published in the next iteration
# 6. (Do some logging)


# Definitions of variables:
# zCurr contains all state information from the beginning of the lap (first s >= 0) to the current state i
# uCurr -> same as zCurr for inputs
# generally: zCurr[i+1] = f(zCurr[i],uCurr[i])

# zCurr[1] = v_x
# zCurr[2] = v_y
# zCurr[3] = psiDot
# zCurr[4] = ePsi
# zCurr[5] = eY
# zCurr[6] = s