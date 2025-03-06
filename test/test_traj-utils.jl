using Test
using Logging
using MEDYANSimRunner
using MEDYANSimRunner: step_path, is_valid_subpath, is_valid_superpath, status_traj_dir

@testset "traj utils" begin
    @testset "step_path" begin
        @test_throws ArgumentError step_path(-1)
        @test step_path(0) == "0/000.zip"
        @test step_path(1) == "0/001.zip"
        @test step_path(999) == "0/999.zip"
        @test step_path(1000) == "1/000.zip"
        @test step_path(1001) == "1/001.zip"
        @test step_path(999999) == "999/999.zip"
        @test step_path(1000000) == "1000/000.zip"
        @test step_path(1000001) == "1000/001.zip"
    end
    @testset "is_valid_subpath or superpath" begin
        for i in 0:2001
            @test is_valid_subpath(basename(step_path(i)))
            @test is_valid_superpath(dirname(step_path(i)))
        end
        @test !is_valid_subpath("")
        @test !is_valid_superpath("")
        @test !is_valid_subpath("000")
        @test !is_valid_superpath("001")
        @test !is_valid_subpath("0.zip")
        @test !is_valid_subpath("0000.zip")
        @test !is_valid_superpath("-1")
    end
    @testset "status_traj_dir" begin
        mktempdir() do traj_dir
            # Case 1: Empty directory (should return -2)
            @test status_traj_dir(traj_dir) == -2
            
            # Case 2: Directory with only header.json (should return -1)
            write(joinpath(traj_dir, "header.json"), "{}")
            @test status_traj_dir(traj_dir) == -1
            
            # Case 3: Directory with header.json and snapshots
            mkdir(joinpath(traj_dir, "0"))
            @test status_traj_dir(traj_dir) == -1
            write(joinpath(traj_dir, "0", "000.zip"), "dummy content")
            @test status_traj_dir(traj_dir) == 0
            write(joinpath(traj_dir, "0", "001.zip"), "dummy content")
            @test status_traj_dir(traj_dir) == 1
            write(joinpath(traj_dir, "0", "002.zip"), "dummy content")
            @test status_traj_dir(traj_dir) == 2
            
            # Empty directory should be ignored
            mkdir(joinpath(traj_dir, "2"))
            @test status_traj_dir(traj_dir) == 2
            mkdir(joinpath(traj_dir, "3"))
            @test status_traj_dir(traj_dir) == 2
            
            # Invalid files should be ignored
            write(joinpath(traj_dir, "0", "invalid.txt"), "invalid file")
            write(joinpath(traj_dir, "0", "0001.zip"), "invalid format")
            write(joinpath(traj_dir, "stuff"), "dummy content")
            @test status_traj_dir(traj_dir) == 2
            
            # Invalid directory names should be ignored
            mkdir(joinpath(traj_dir, "not_a_number"))
            write(joinpath(traj_dir, "not_a_number", "000.zip"), "dummy content")
            @test status_traj_dir(traj_dir) == 2
            
            # Add another higher-numbered directory
            mkdir(joinpath(traj_dir, "1"))
            write(joinpath(traj_dir, "1", "000.zip"), "dummy content")
            @test status_traj_dir(traj_dir) == 1000

            # Extremely high step number should be ignored
            mkdir(joinpath(traj_dir, "100000000000000"))
            write(joinpath(traj_dir, "100000000000000", "000.zip"), "dummy content")
            @test status_traj_dir(traj_dir) == 1000
            
            # Case 4: Directory with footer.json (should return :done)
            write(joinpath(traj_dir, "footer.json"), "{}")
            @test status_traj_dir(traj_dir) == :done
        end
    end
    @testset "steps_traj_dir" begin
        mktempdir() do traj_dir
            # Case 1: Empty directory (should return empty array)
            @test isempty(steps_traj_dir(traj_dir))
            
            # Case 2: Directory with only header.json (should still return empty array)
            write(joinpath(traj_dir, "header.json"), "{}")
            @test isempty(steps_traj_dir(traj_dir))
            
            # Case 3: Directory with header.json and snapshots
            mkdir(joinpath(traj_dir, "0"))
            @test isempty(steps_traj_dir(traj_dir)) # Empty directory should still return empty
            
            # Add snapshots in various directories
            write(joinpath(traj_dir, "0", "000.zip"), "dummy content")
            @test steps_traj_dir(traj_dir) == [0]
            
            write(joinpath(traj_dir, "0", "001.zip"), "dummy content")
            @test steps_traj_dir(traj_dir) == [0, 1]
            
            write(joinpath(traj_dir, "0", "002.zip"), "dummy content")
            @test steps_traj_dir(traj_dir) == [0, 1, 2]
            
            mkdir(joinpath(traj_dir, "1"))
            write(joinpath(traj_dir, "1", "000.zip"), "dummy content")
            @test steps_traj_dir(traj_dir) == [0, 1, 2, 1000]
            
            # Add snapshots out of order and verify sorting works
            write(joinpath(traj_dir, "1", "002.zip"), "dummy content")
            write(joinpath(traj_dir, "1", "001.zip"), "dummy content")
            @test steps_traj_dir(traj_dir) == [0, 1, 2, 1000, 1001, 1002]
            
            # Add snapshots to a higher directory
            mkdir(joinpath(traj_dir, "5"))
            write(joinpath(traj_dir, "5", "010.zip"), "dummy content")
            @test steps_traj_dir(traj_dir) == [0, 1, 2, 1000, 1001, 1002, 5010]
            
            # Add invalid files and directories - should be ignored
            write(joinpath(traj_dir, "0", "invalid.txt"), "invalid file")
            write(joinpath(traj_dir, "0", "0001.zip"), "invalid format")
            mkdir(joinpath(traj_dir, "not_a_number"))
            write(joinpath(traj_dir, "not_a_number", "000.zip"), "dummy content")
            @test steps_traj_dir(traj_dir) == [0, 1, 2, 1000, 1001, 1002, 5010]
            
            # Test with footer.json (should still find all steps)
            write(joinpath(traj_dir, "footer.json"), "{}")
            @test steps_traj_dir(traj_dir) == [0, 1, 2, 1000, 1001, 1002, 5010]
            
            # Test without header.json (should return empty)
            mktempdir() do traj_dir_no_header
                mkdir(joinpath(traj_dir_no_header, "0"))
                write(joinpath(traj_dir_no_header, "0", "000.zip"), "dummy content")
                @test isempty(steps_traj_dir(traj_dir_no_header))
            end
        end
    end
end