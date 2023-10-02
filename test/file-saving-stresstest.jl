using Base: _UVError

using Base: SIGKILL

using Distributed

@everywhere begin
    using MEDYANSimRunner
end

input_dir = mktempdir()

# start the worker
# add processes on the same machine  with the specified input dir
worker = addprocs(1;
    topology=:master_worker,
    dir=input_dir,
)[1]

ospid = remotecall_fetch(getpid, worker)
rc = ccall(:uv_kill, Cint, (Cint, Cint), ospid, SIGKILL)
rc == 0 || throw(_UVError("kill", rc))
close(channel)
try
    rmprocs(worker)
catch e
    if e isa Base.IOError
        #Windows creates an IOError here for some reason
    else
        rethrow()
    end
end