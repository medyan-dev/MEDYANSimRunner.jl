# run code on a worker with a timeout

# A lot of this code is copied from 
# https://github.com/ararslan/Timeout.jl/blob/master/src/Timeout.jl


using Base: _UVError

using Base: SIGTERM

using Distributed


"""
    run_with_timeout(worker::Int, timeout::Float64, expr::Expr; verbose=true, poll=0.1)

Run code on a worker in `Main` with a time out in seconds and return the result.
The worker must be on the same computer.

Will return one of four possibilities.
1. `(:timed_out, nothing)`
2. `(:worker_exited, nothing)`
3. `(:errored, sprint(showerror, real_e, real_bt))`
4. `(:ok, fetched_value)`

If the status is :timed_out or :worker_exited, `worker` will no longer be available.

This function can also error if `expr` causes something 
to be returned which cannot be interpreted on the master process.
"""
function run_with_timeout(worker::Int, timeout::Float64, expr::Expr; verbose=true, poll=0.1)
    nprocs() > 1 || throw(ArgumentError("No worker processes available"))
    worker in workers() || throw(ArgumentError("Unknown worker process ID: $worker"))
    worker == myid() && throw(ArgumentError("Can't run on the current process"))
    poll > 0 || throw(ArgumentError("Can't poll every $poll seconds"))

    # We need the worker process to be on the same host as the calling process, otherwise
    # sending a SIGTERM to the result of getpid might kill off something local
    if gethostname() != remotecall_fetch(gethostname, worker)
        throw(ArgumentError("Can't run with a worker on a different host"))
    end

    # Now start by getting the OS process ID for the worker so that we have something to
    # forcibly kill if need be
    ospid = remotecall_fetch(getpid, worker)

    # This remote call is put into a task bound to a channel, 
    # so the result can be polled
    # with timedwait without any blocking.
    channel = Channel() do ch
        put!(ch, remotecall_fetch(Core.eval, worker, Main, expr))
    end

    timedout = timedwait(timeout; pollint=poll) do
        # isready becomes true if put! happens, !isopen becomes true if channel has an error
        isready(channel) || !isopen(channel)
    end

    if timedout == :timed_out
        verbose && @warn "Time limit for computation exceeded, forcibly kill the worker process..."
        rc = ccall(:uv_kill, Cint, (Cint, Cint), ospid, SIGTERM)
        rc == 0 || throw(_UVError("kill", rc))
        close(channel)
        rmprocs(worker)
        return (:timed_out, nothing)
    end

    @assert isready(channel) || !isopen(channel)
    try
        return (:ok, take!(channel))
    catch e
        if e isa TaskFailedException
            result_error = e.task.result
            if result_error isa RemoteException
                real_e = e.task.result.captured.ex
                real_bt = e.task.result.captured.processed_bt
                return (:errored, sprint(showerror, real_e, real_bt))
            elseif result_error isa ProcessExitedException
                return (:worker_exited, nothing)
            else
                rethrow()
            end
        else
            rethrow()
        end
    end
end