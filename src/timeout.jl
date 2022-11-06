# run code on a worker with a timeout

# A lot of this code is copied from 
# https://github.com/ararslan/Timeout.jl/blob/master/src/Timeout.jl


using Base: _UVError

using Base: SIGTERM

using Distributed


"""
Run code on a worker in `Main` with a time out in seconds and return the result.
The worker must be on the same computer.

Will return one of three possibilities.
1. `(:timed_out, nothing)`
2. `(:errored, sprint(showerror, real_e, real_bt))`
3. `(:ok, fetched_value)`

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

    timedout = timedwait(timeout; poll) do
        # isready becomes true if put! happens, !isopen becomes true if channel has an error
        isready(channel) || !isopen(channel)
    end

    if timedout == :timed_out
        verbose && @warn "Time limit for computation exceeded. Interrupting..."
        patience = 10
        while isopen(channel) && (patience -= 1) > 0
            interrupt(worker)
        end
        # If our interrupts didn't work, forcibly kill the process
        if isopen(channel)
            rc = ccall(:uv_kill, Cint, (Cint, Cint), ospid, SIGTERM)
            rc == 0 || throw(_UVError("kill", rc))
        end
        close(channel)
        return (:timed_out, nothing)
    end

    @assert isready(channel) || !isopen(channel)
    try
        return (:ok, take!(channel))
    catch e
        if e isa TaskFailedException
            real_e = e.task.result.captured.ex
            real_bt = e.task.result.captured.processed_bt
            return (:errored, sprint(showerror, real_e, real_bt))
        else
            rethrow()
        end
    end
end