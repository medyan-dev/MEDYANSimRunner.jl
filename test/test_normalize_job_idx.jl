using Test

using MEDYANSimRunner
using SHA

@testset "unit tests for normalize_job_idx" begin
    get_seed(x) = collect(reinterpret(UInt64, sha256(x)))
    @test_throws ArgumentError MEDYANSimRunner.normalize_job_idx("", -1)
    @test_throws ArgumentError MEDYANSimRunner.normalize_job_idx("\xff", -1)
    @test_throws ArgumentError MEDYANSimRunner.normalize_job_idx("\n", -1)
    @test_throws ArgumentError MEDYANSimRunner.normalize_job_idx(",", -1)
    @test_throws ArgumentError MEDYANSimRunner.normalize_job_idx("../../1", -1)
    @test_throws ArgumentError MEDYANSimRunner.normalize_job_idx("..\\../1", -1)
    @test ("1", get_seed("1")) == MEDYANSimRunner.normalize_job_idx("1", -1)
    @test ("1/2", get_seed("1/2")) == MEDYANSimRunner.normalize_job_idx("1/2", -1)
    @test ("1/2", get_seed("1/2")) == MEDYANSimRunner.normalize_job_idx("1\\2", -1)
    @test ("1/2", get_seed("1/2")) == MEDYANSimRunner.normalize_job_idx("1\\2/", -1)
    @test ("1/2", get_seed("1/2")) == MEDYANSimRunner.normalize_job_idx("/1\\2/", -1)
    @test ("1/2", get_seed("1/2")) == MEDYANSimRunner.normalize_job_idx("//1//2///", -1)
    @test_throws ArgumentError MEDYANSimRunner.normalize_job_idx(joinpath(@__DIR__,"foo"), 1)
    @test_throws BoundsError MEDYANSimRunner.normalize_job_idx(joinpath(@__DIR__,"examples","good","jobnames.txt"), 10)
    @test ("6", get_seed("6")) == MEDYANSimRunner.normalize_job_idx(joinpath(@__DIR__,"examples","good","jobnames.txt"), 1)
    @test ("3", get_seed("3")) == MEDYANSimRunner.normalize_job_idx(joinpath(@__DIR__,"examples","good","jobnames.txt"), 2)
end