using Base: _UVError

using Base: SIGKILL

using Distributed

@everywhere begin
    using MEDYANSimRunner
end

out_dir = mktempdir()
@show readdir(out_dir)
out_file = joinpath(out_dir, "foo")

worker = workers()[end]
ospid = remotecall_fetch(getpid, worker)

data1 = remotecall(ones, worker, UInt8, 1<<20)

remotecall_fetch(worker, data1) do data
    MEDYANSimRunner.write_traj_file(out_dir, "foo", fetch(data))
end

fetch(data1)

N = 1<<20
data2 = remotecall(ones, worker, UInt8, N)

r = remotecall(worker, data2) do data
    MEDYANSimRunner.write_traj_file(out_dir, "foo", fetch(data))
end

fetch(r)

N = 1<<30
data3 = remotecall(ones, worker, UInt8, N+1)

remotecall_fetch(x->length(fetch(x)), worker, data3)

r = remotecall(worker, data3) do data
    MEDYANSimRunner.write_traj_file(out_dir, "foo", fetch(data))
end

# rc = ccall(:uv_kill, Cint, (Cint, Cint), ospid, SIGKILL)
# rc == 0 || throw(_UVError("kill", rc))
# try
#     rmprocs(worker)
# catch e
#     if e isa Base.IOError
#         #Windows creates an IOError here for some reason
#     else
#         rethrow()
#     end
# end

@show length(read(out_file))
for i in 1:10
    sleep(0.5)
    @show readdir(out_dir)
end
@show length(read(out_file))

fetch(r)

@show length(read(out_file))