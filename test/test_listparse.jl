using Test

using MEDYANSimRunner
using Dates
using Random


@testset "list.txt doesn't exist" begin
    list_info, _ = MEDYANSimRunner.parse_list_file("not a file")
    @test iszero(list_info.job_idx) # list is empty
    list_info, _ = MEDYANSimRunner.parse_list_file("not a file";ignore_error=true)
    @test iszero(list_info.job_idx) # list is empty
end
@testset "list.txt is empty" begin
    list_info, _ = MEDYANSimRunner.parse_list_file("list-examples/list empty.txt")
    @test iszero(list_info.job_idx) # list is empty
    list_info, _ = MEDYANSimRunner.parse_list_file("list-examples/list empty.txt";ignore_error=true)
    @test iszero(list_info.job_idx) # list is empty
end
@testset "list.txt partial too small" begin
    list_info, _ = MEDYANSimRunner.parse_list_file("list-examples/list partial too small.txt")
    @test iszero(list_info.job_idx) # list is empty
    list_info, _ = MEDYANSimRunner.parse_list_file("list-examples/list partial too small.txt";ignore_error=true)
    @test iszero(list_info.job_idx) # list is empty
end
@testset "list.txt startup error" begin
    list_info, good_rawlines = MEDYANSimRunner.parse_list_file("list-examples/list start error.txt")
    @test list_info.job_idx == 1
    @test list_info.input_tree_hash == hex2bytes("8eaa2ae599032df7a3322615aa7fe75c2d4488f8a7b547954f1899b8553b94a4")
    @test list_info.header_sha256 == []
    @test list_info.snapshot_infos == []
    @test list_info.final_message == "Error starting job"
    @test length(good_rawlines) == 2
    list_info, good_rawlines = MEDYANSimRunner.parse_list_file("list-examples/list start error.txt";ignore_error=true)
    @test iszero(list_info.job_idx) # list is empty
    @test isempty(good_rawlines)
end
@testset "list.txt partial run clean lines" begin
    for ignore_error in (false,true)
        list_info, _ = MEDYANSimRunner.parse_list_file("list-examples/list partial clean.txt";ignore_error)
        @test list_info.job_idx == 2
        @test list_info.input_tree_hash == hex2bytes("f4fde7178433b85c216b15d4678cacfa8650b7289cb2bd8f0ce05c0041924473")
        @test list_info.header_sha256 == hex2bytes("a36a3e400d8f3383247c9c58b380b74d9462d3c0484895eaf8a9f55db1aab9aa")
        @test length(list_info.snapshot_infos) == 4

        @test list_info.snapshot_infos[1].time_stamp == DateTime("2022-11-06T17:30:03")
        @test list_info.snapshot_infos[1].step_number == 0
        @test list_info.snapshot_infos[1].nthreads == 1
        @test list_info.snapshot_infos[1].julia_versioninfo == "Long Julia Version String"
        @test list_info.snapshot_infos[1].rngstate == Xoshiro(0xfff0241072ddab67, 0xc53bc12f4c3f0b4e, 0x56d451780b2dd4ba, 0x50a4aa153d208dd8)
        @test list_info.snapshot_infos[1].snapshot_sha256 == hex2bytes("6575c62733b459ec9ee5f7308229a090f1116f0164ab8ef5713e71b9d58dd220")

        @test list_info.snapshot_infos[2].time_stamp == DateTime("2022-11-06T17:30:03")
        @test list_info.snapshot_infos[2].step_number == 1
        @test list_info.snapshot_infos[2].nthreads == 1
        @test list_info.snapshot_infos[2].julia_versioninfo == "Long Julia Version String"
        @test list_info.snapshot_infos[2].rngstate == Xoshiro(0xfff0241072ddab67, 0xc53bc12f4c3f0b4e, 0x56d451780b2dd4ba, 0x50a4aa153d208dd8)
        @test list_info.snapshot_infos[2].snapshot_sha256 == hex2bytes("6f52d44936bef59e543126cbd610a09538f5b5aeb568d616a99750240002b000")

        @test list_info.snapshot_infos[4].time_stamp == DateTime("2022-11-06T17:30:04")
        @test list_info.snapshot_infos[4].step_number == 3
        @test list_info.snapshot_infos[4].nthreads == 1
        @test list_info.snapshot_infos[4].julia_versioninfo == "Long Julia Version String"
        @test list_info.snapshot_infos[4].rngstate == Xoshiro(0x0d78c6c5f2400a9c, 0xcf341e2315f17db6, 0x01ceb25a2560ce54, 0x609e89462d6ec715)
        @test list_info.snapshot_infos[4].snapshot_sha256 == hex2bytes("4edb8ed71bf2126da7900a58923f96b181a4b4eb9c001da824a9b1a059eb5f9c")

        @test list_info.final_message == ""
    end
end
@testset "list.txt partial run not clean lines" begin
    list_info, _ = MEDYANSimRunner.parse_list_file("list-examples/list partial.txt")
    @test list_info.job_idx == 2
    @test list_info.input_tree_hash == hex2bytes("f4fde7178433b85c216b15d4678cacfa8650b7289cb2bd8f0ce05c0041924473")
    @test list_info.header_sha256 == hex2bytes("a36a3e400d8f3383247c9c58b380b74d9462d3c0484895eaf8a9f55db1aab9aa")
    @test length(list_info.snapshot_infos) == 3

    @test list_info.snapshot_infos[1].time_stamp == DateTime("2022-11-06T17:30:03")
    @test list_info.snapshot_infos[1].step_number == 0
    @test list_info.snapshot_infos[1].nthreads == 1
    @test list_info.snapshot_infos[1].julia_versioninfo == "Long Julia Version String"
    @test list_info.snapshot_infos[1].rngstate == Xoshiro(0xfff0241072ddab67, 0xc53bc12f4c3f0b4e, 0x56d451780b2dd4ba, 0x50a4aa153d208dd8)
    @test list_info.snapshot_infos[1].snapshot_sha256 == hex2bytes("6575c62733b459ec9ee5f7308229a090f1116f0164ab8ef5713e71b9d58dd220")

    @test list_info.snapshot_infos[2].time_stamp == DateTime("2022-11-06T17:30:03")
    @test list_info.snapshot_infos[2].step_number == 1
    @test list_info.snapshot_infos[2].nthreads == 1
    @test list_info.snapshot_infos[2].julia_versioninfo == "Long Julia Version String"
    @test list_info.snapshot_infos[2].rngstate == Xoshiro(0xfff0241072ddab67, 0xc53bc12f4c3f0b4e, 0x56d451780b2dd4ba, 0x50a4aa153d208dd8)
    @test list_info.snapshot_infos[2].snapshot_sha256 == hex2bytes("6f52d44936bef59e543126cbd610a09538f5b5aeb568d616a99750240002b000")

    @test list_info.snapshot_infos[3].time_stamp == DateTime("2022-11-06T17:30:03")
    @test list_info.snapshot_infos[3].step_number == 2
    @test list_info.snapshot_infos[3].nthreads == 1
    @test list_info.snapshot_infos[3].julia_versioninfo == "Long Julia Version String"
    @test list_info.snapshot_infos[3].rngstate == Xoshiro(0x2007f3c789b9526d, 0x085f596501ec49e6, 0x8048aeb561cb1458, 0xf95c00361c064979)
    @test list_info.snapshot_infos[3].snapshot_sha256 == hex2bytes("7c02a201a9f2326c924f961b479ca6570493cb6f15fc173a332c30fa6556c34a")

    @test list_info.final_message == ""
end
@testset "list.txt full run" begin
    for ignore_error in (false,true)
        list_info, _ = MEDYANSimRunner.parse_list_file("list-examples/list done.txt"; ignore_error)
        @test list_info.job_idx == 2
        @test list_info.input_tree_hash == hex2bytes("f4fde7178433b85c216b15d4678cacfa8650b7289cb2bd8f0ce05c0041924473")
        @test list_info.header_sha256 == hex2bytes("a36a3e400d8f3383247c9c58b380b74d9462d3c0484895eaf8a9f55db1aab9aa")
        @test length(list_info.snapshot_infos) == 4

        @test list_info.snapshot_infos[1].time_stamp == DateTime("2022-11-06T17:30:03")
        @test list_info.snapshot_infos[1].step_number == 0
        @test list_info.snapshot_infos[1].nthreads == 1
        @test list_info.snapshot_infos[1].julia_versioninfo == "Long Julia Version String"
        @test list_info.snapshot_infos[1].rngstate == Xoshiro(0xfff0241072ddab67, 0xc53bc12f4c3f0b4e, 0x56d451780b2dd4ba, 0x50a4aa153d208dd8)
        @test list_info.snapshot_infos[1].snapshot_sha256 == hex2bytes("6575c62733b459ec9ee5f7308229a090f1116f0164ab8ef5713e71b9d58dd220")

        @test list_info.snapshot_infos[2].time_stamp == DateTime("2022-11-06T17:30:03")
        @test list_info.snapshot_infos[2].step_number == 1
        @test list_info.snapshot_infos[2].nthreads == 1
        @test list_info.snapshot_infos[2].julia_versioninfo == "Long Julia Version String"
        @test list_info.snapshot_infos[2].rngstate == Xoshiro(0xfff0241072ddab67, 0xc53bc12f4c3f0b4e, 0x56d451780b2dd4ba, 0x50a4aa153d208dd8)
        @test list_info.snapshot_infos[2].snapshot_sha256 == hex2bytes("6f52d44936bef59e543126cbd610a09538f5b5aeb568d616a99750240002b000")

        @test list_info.snapshot_infos[3].time_stamp == DateTime("2022-11-06T17:30:03")
        @test list_info.snapshot_infos[3].step_number == 2
        @test list_info.snapshot_infos[3].nthreads == 1
        @test list_info.snapshot_infos[3].julia_versioninfo == "Long Julia Version String"
        @test list_info.snapshot_infos[3].rngstate == Xoshiro(0x2007f3c789b9526d, 0x085f596501ec49e6, 0x8048aeb561cb1458, 0xf95c00361c064979)
        @test list_info.snapshot_infos[3].snapshot_sha256 == hex2bytes("7c02a201a9f2326c924f961b479ca6570493cb6f15fc173a332c30fa6556c34a")

        @test list_info.snapshot_infos[4].time_stamp == DateTime("2022-11-06T17:30:04")
        @test list_info.snapshot_infos[4].step_number == 3
        @test list_info.snapshot_infos[4].nthreads == 1
        @test list_info.snapshot_infos[4].julia_versioninfo == "Long Julia Version String"
        @test list_info.snapshot_infos[4].rngstate == Xoshiro(0x0d78c6c5f2400a9c, 0xcf341e2315f17db6, 0x01ceb25a2560ce54, 0x609e89462d6ec715)
        @test list_info.snapshot_infos[4].snapshot_sha256 == hex2bytes("4edb8ed71bf2126da7900a58923f96b181a4b4eb9c001da824a9b1a059eb5f9c")

        @test list_info.final_message == "Done"
    end
end
