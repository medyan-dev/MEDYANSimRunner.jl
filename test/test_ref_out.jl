# compare output against a reference.


using Test

using MEDYANSimRunner


@testset "good example" begin
    rm("examples/good/output"; force=true, recursive=true)
    mkpath("examples/good/output")
    MEDYANSimRunner.run("examples/good/input/", "examples/good/output/", 1)
    out_diff = sprint(MEDYANSimRunner.diff, "examples/good/output-ref/out1", "examples/good/output/out1")
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end
@testset "good partial example" begin
    mkpath("examples/good partial/output")
    cp("examples/good partial/output partial", "examples/good partial/output"; force=true)
    MEDYANSimRunner.run("examples/good/input/", "examples/good partial/output/", 1)
    out_diff = sprint(MEDYANSimRunner.diff, "examples/good/output-ref/out1", "examples/good partial/output/out1")
    if !isempty(out_diff)
        println(out_diff)
        @test false
    end
end