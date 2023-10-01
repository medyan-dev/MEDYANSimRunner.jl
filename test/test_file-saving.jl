using Test
using Logging
using MEDYANSimRunner


@testset "write_traj_file" begin
    # write empty file
    mktempdir() do path
        MEDYANSimRunner.write_traj_file(path, "empty.txt", b"")
        @test read(joinpath(path, "empty.txt")) == UInt8[]
        @test readdir(path) == ["empty.txt"]
    end
    # write file with no existing file
    mktempdir() do path
        MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
        @test read(joinpath(path, "snap1.txt")) == [0x01, 0x02]
        @test readdir(path) == ["snap1.txt"]
    end
    # write file with existing same file
    mktempdir() do path
        MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
        MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
        @test read(joinpath(path, "snap1.txt")) == [0x01, 0x02]
        @test readdir(path) == ["snap1.txt"]
    end
    # write file with existing different file
    mktempdir() do path
        MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x02, 0x02])
        MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
        @test read(joinpath(path, "snap1.txt")) == [0x01, 0x02]
        @test readdir(path) == ["snap1.txt"]
    end
    # write file with existing dir
    mktempdir() do path
        mkdir(joinpath(path, "snap1.txt"))
        @test_throws ErrorException MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
        @test readdir(path) == ["snap1.txt"]
    end
end