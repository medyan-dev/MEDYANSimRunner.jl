# compare output against a reference.


using Test

using MEDYANSimRunner
using LoggingExtras
using Logging

module UserCode
    include("example/main.jl")
end
@testset "reference output" begin


ref_out = joinpath(@__DIR__, "example/output-ref")
warn_only_logger = MinLevelLogger(current_logger(), Logging.Warn);


@testset "full run example" begin
    for continue_sim in (true,false)
        test_out = joinpath(@__DIR__, "example/output/full",continue_sim ? "con" : "start")
        rm(test_out; force=true, recursive=true)
        args = ["--out=$test_out","--batch=1"]
        continue_sim && push!(args,"--continue")
        with_logger(warn_only_logger) do
            MEDYANSimRunner.run_sim(args;
                UserCode.jobs,
                UserCode.setup,
                UserCode.save_snapshot,
                UserCode.load_snapshot,
                UserCode.loop,
                UserCode.done,
            )
        end
        out_diff = sprint(MEDYANSimRunner.print_traj_diff, joinpath(ref_out,"1"), joinpath(test_out,"1"))
        if !isempty(out_diff)
            println(out_diff)
            @test false
        end
    end
end
@testset "partial restart example $v" for v in 1:4
    test_out = joinpath(@__DIR__, "example/output/restart $v")
    rm(test_out; force=true, recursive=true)
    mkpath(test_out)
    cp(joinpath(@__DIR__, "example/output-ref partial $v"), test_out; force=true)
    with_logger(warn_only_logger) do
        MEDYANSimRunner.run_sim(["--out=$test_out","--batch=1"];
            UserCode.jobs,
            UserCode.setup,
            UserCode.save_snapshot,
            UserCode.load_snapshot,
            UserCode.loop,
            UserCode.done,
        )
    end
    out_diff = sprint(MEDYANSimRunner.print_traj_diff, joinpath(ref_out,"1"), joinpath(test_out,"1"))
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end
@testset "partial continue example $v" for v in 1:4
    test_out = joinpath(@__DIR__, "example/output/continue $v")
    rm(test_out; force=true, recursive=true)
    mkpath(test_out)
    cp(joinpath(@__DIR__, "example/output-ref partial $v"), test_out; force=true)
    with_logger(warn_only_logger) do
        MEDYANSimRunner.run_sim(["--out=$test_out","--batch=1", "--continue"];
            UserCode.jobs,
            UserCode.setup,
            UserCode.save_snapshot,
            UserCode.load_snapshot,
            UserCode.loop,
            UserCode.done,
        )
    end
    out_diff = sprint(MEDYANSimRunner.print_traj_diff, joinpath(ref_out,"1"), joinpath(test_out,"1"))
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end
@testset "continue complete job" begin
    test_out = joinpath(@__DIR__, "example/output/continue complete")
    rm(test_out; force=true, recursive=true)
    mkpath(test_out)
    cp(joinpath(@__DIR__, "example/output-ref"), test_out; force=true)
    with_logger(warn_only_logger) do
        MEDYANSimRunner.run_sim(["--out=$test_out","--batch=1", "--continue"];
            UserCode.jobs,
            UserCode.setup,
            UserCode.save_snapshot,
            UserCode.load_snapshot,
            UserCode.loop,
            UserCode.done,
        )
    end
    out_diff = sprint(MEDYANSimRunner.print_traj_diff, joinpath(ref_out,"1"), joinpath(test_out,"1"))
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end
end