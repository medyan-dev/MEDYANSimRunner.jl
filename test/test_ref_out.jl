# compare output against a reference.


using Test

using MEDYANSimRunner
using LoggingExtras
using Logging

module UserCode
    include("example/main.jl")
end
@testset "run example" begin

warn_only_logger = MinLevelLogger(current_logger(), Logging.Warn);

example_output = joinpath(@__DIR__, "example/output")


@testset "full run example" begin
    for continue_sim in (true,false)
        test_out = joinpath(example_output, continue_sim ? "conti" : "start")
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
    end
    out_diff = sprint(MEDYANSimRunner.print_traj_diff, joinpath(example_output, "conti", "a"), joinpath(example_output, "start", "a"))
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
    @test MEDYANSimRunner.steps_traj_dir(joinpath(example_output, "start", "a", "traj")) == 0:3001
    @test read(joinpath(example_output, "start", "a", "traj", "footer.json")) == read(joinpath(@__DIR__, "example/output-ref-1_11", "a", "traj", "footer.json"))
end

ref_out = joinpath(example_output, "start")
@testset "partial restart example $i" for i in 1:11
    for continue_sim in (true,false)
        test_out = joinpath(@__DIR__, "example/output/restart $i",continue_sim ? "conti" : "start")
        mkpath(test_out)
        cp(ref_out, test_out; force=true)
        v = i
        (v-=1) > 0 && rm(joinpath(test_out,"a/traj/footer.json"))
        (v-=1) > 0 && rm(joinpath(test_out,"a/traj/3/001.zip"))
        (v-=1) > 0 && rm(joinpath(test_out,"a/traj/3/000.zip"))
        (v-=1) > 0 && rm(joinpath(test_out,"a/traj/3"))
        if (v-=1) > 0
            for i in 999:-1:800
                rm(joinpath(test_out,"a/traj/2/$(string(i; pad=3)).zip"))
            end
        end
        if (v-=1) > 0
            rm(joinpath(test_out,"a/traj/2"); recursive=true)
            rm(joinpath(test_out,"a/traj/1"); recursive=true)
        end
        if (v-=1) > 0
            for i in 999:-1:2
                rm(joinpath(test_out,"a/traj/0/$(string(i; pad=3)).zip"))
            end
        end
        if (v-=1) > 0
            rm(joinpath(test_out,"a/traj/0/001.zip"))
        end
        if (v-=1) > 0
            rm(joinpath(test_out,"a/traj/0/000.zip"))
        end
        if (v-=1) > 0
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