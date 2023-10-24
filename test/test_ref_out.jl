# compare output against a reference.


using Test

using MEDYANSimRunner
using LoggingExtras
using Logging

module UserCode
    include("example/main.jl")
end
@testset "reference output" begin

ref_out = if VERSION >= v"1.10"
    joinpath(@__DIR__, "example/output-ref-1_10")
else
    joinpath(@__DIR__, "example/output-ref-1_9")
end
warn_only_logger = MinLevelLogger(current_logger(), Logging.Warn);


@testset "full run example" begin
    for continue_sim in (true,false)
        test_out = joinpath(@__DIR__, "example/output/full",continue_sim ? "conti" : "start")
        rm(test_out; force=true, recursive=true)
        args = ["--out=$test_out","--batch=1"]
        continue_sim && push!(args,"--continue")
        with_logger(warn_only_logger) do
            MEDYANSimRunner.run(args;
                UserCode.jobs,
                UserCode.setup,
                UserCode.save,
                UserCode.load,
                UserCode.loop,
                UserCode.done,
            )
        end
        out_diff = sprint(MEDYANSimRunner.print_traj_diff, joinpath(ref_out,"a"), joinpath(test_out,"a"))
        if !isempty(out_diff)
            println(out_diff)
            @test false
        end
    end
end
@testset "partial restart example $v" for v in 1:8
    for continue_sim in (true,false)
        test_out = joinpath(@__DIR__, "example/output/restart $v",continue_sim ? "conti" : "start")
        mkpath(test_out)
        cp(ref_out, test_out; force=true)
        if v > 1
            rm(joinpath(test_out,"a/traj/footer.json"))
        end
        if v > 2
            rm(joinpath(test_out,"a/traj/snap11.zarr.zip"))
        end
        if v > 3
            for i in 10:-1:5
                rm(joinpath(test_out,"a/traj/snap$i.zarr.zip"))
            end
        end
        if v > 4
            for i in 4:-1:2
                rm(joinpath(test_out,"a/traj/snap$i.zarr.zip"))
            end
        end
        if v > 5
            rm(joinpath(test_out,"a/traj/snap1.zarr.zip"))
        end
        if v > 6
            rm(joinpath(test_out,"a/traj/snap0.zarr.zip"))
        end
        if v > 7
            rm(joinpath(test_out,"a/traj/header.json"))
        end

        args = ["--out=$test_out","--batch=1"]
        continue_sim && push!(args,"--continue")
        with_logger(warn_only_logger) do
            MEDYANSimRunner.run(args;
                UserCode.jobs,
                UserCode.setup,
                UserCode.save,
                UserCode.load,
                UserCode.loop,
                UserCode.done,
            )
        end
        out_diff = sprint(MEDYANSimRunner.print_traj_diff, joinpath(ref_out,"a"), joinpath(test_out,"a"))
        if !isempty(out_diff)
            println(out_diff)
            @test false
        end
    end
end
end