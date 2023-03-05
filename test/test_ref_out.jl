# compare output against a reference.


using Test

using MEDYANSimRunner


@testset "good example" begin
    test_out = "examples/good/output"
    rm(test_out; force=true, recursive=true)
    mkpath(test_out)
    MEDYANSimRunner.run("examples/good/input/", test_out, "1")
    out_diff = sprint(MEDYANSimRunner.diff, "examples/good/output-ref/1", joinpath(test_out,"1"))
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end
@testset "good partial example" begin
    test_out = "examples/good partial/output"
    mkpath(test_out)
    cp("examples/good partial/output partial", test_out; force=true)
    MEDYANSimRunner.run("examples/good/input/", test_out, "1")
    out_diff = sprint(MEDYANSimRunner.diff, "examples/good/output-ref/1", joinpath(test_out,"1"))
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end
@testset "missing manifest example" begin
    test_out = "examples/missing manifest/output"
    rm(test_out; force=true, recursive=true)
    mkpath(test_out)
    MEDYANSimRunner.run("examples/missing manifest/input/", test_out, "1")
    # The output should be empty
    out_diff = sprint(MEDYANSimRunner.diff, mktempdir(), joinpath(test_out,"1"))
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end
@testset "loading timeout example" begin
    test_out = "examples/loading timeout/output"
    rm(test_out; force=true, recursive=true)
    mkpath(test_out)
    MEDYANSimRunner.run("examples/loading timeout/input/", test_out, "1";
        startup_timeout=2.0,
    )
    out_diff = sprint(MEDYANSimRunner.diff, "examples/loading timeout/output-ref/1", joinpath(test_out,"1"))
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end