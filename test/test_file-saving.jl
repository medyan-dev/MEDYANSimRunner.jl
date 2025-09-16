using Test
using MEDYANSimRunner

@testset "write_traj_file unit tests" begin
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
        @test_throws Exception MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
        @test isdir(joinpath(path, "snap1.txt"))
        @test readdir(path) == ["snap1.txt"]
    end
    # write file with existing open file with same content
    mktempdir() do path
        MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
        open(joinpath(path, "snap1.txt")) do f
            MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
            @test read(joinpath(path, "snap1.txt")) == [0x01, 0x02]
            @test read(f) == [0x01, 0x02]
            @test readdir(path) == ["snap1.txt"]
        end
    end
    # write file with existing open file with different content
    # this errors safely on windows
    mktempdir() do path
        MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x02, 0x02])
        open(joinpath(path, "snap1.txt")) do f
            if Sys.iswindows()
                @test_throws ErrorException MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
                @test read(joinpath(path, "snap1.txt")) == [0x02, 0x02]
                @test read(f) == [0x02, 0x02]
            else
                MEDYANSimRunner.write_traj_file(path, "snap1.txt", [0x01, 0x02])
                @test read(joinpath(path, "snap1.txt")) == [0x01, 0x02]
                @test read(f) == [0x02, 0x02]
            end
            @test readdir(path) == ["snap1.txt"]
        end
    end
end