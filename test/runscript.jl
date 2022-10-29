using Distributed

# add processes on the same machine  with the specified input dir
workerpid = addprocs(1;
    topology=:master_worker,
    exeflags="--project",
    dir="badsim",
)[1]

# Load environment and main.jl

# This remote call is put into a task bound to a channel, 
# so the result can be polled
# with timedwait without any blocking.
taskref = Ref{Task}();
loading_c = Channel(;taskref) do ch
    put!(ch, remotecall_fetch(Core.eval, workerpid, Main, quote
        using Pkg; Pkg.instantiate()
        include("main.jl")
        # This nothing is to prevent fetch from trying to 
        # return the last value in "main.jl"
        nothing
    end))
end
# TODO load this parameter from a Job.toml file
loadingtimeout = 10.0
timedout = timedwait(loadingtimeout) do 
    istaskdone(taskref[])
end

if timedout == :timed_out
    println("Time out loading main.jl")
    # TODO gracefully mark job failed and exit
    # kill worker, is this needed?
    interrupt()
    rmprocs(workerpid)
    exit()
end

try
   take!(loading_c) 
catch e
    if e isa TaskFailedException
        real_e = e.task.result.captured.ex
        real_bt = e.task.result.captured.processed_bt
        println("Exception loading main.jl")
        # This error should be stored in some log file.
        showerror(stdout, real_e, real_bt)
        # TODO gracefully mark job failed and exit
        # kill worker, is this needed?
        rmprocs(workerpid)
        exit()
    else
        rethrow()
    end
end

