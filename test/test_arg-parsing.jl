using Test
using Logging
using MEDYANSimRunner


@testset "arg parsing" begin
    @test MEDYANSimRunner.parse_cli_args(
            String[], ["job1", "job2"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:2,
            out_dir=".",
        )
    @test MEDYANSimRunner.parse_cli_args(
            String["--continue"], ["job1", "job2"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=true,
            batch_range=1:1:2,
            out_dir=".",
        )
    @test MEDYANSimRunner.parse_cli_args(
            String["--out=/home/nathan/sim1"], ["job1", "job2"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:2,
            out_dir="/home/nathan/sim1",
        )
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=-1"], ["job1", "job2"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:2,
            out_dir=".",
        )
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=3"], ["job1", "job2", "job3", "job4"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=3:4:4,
            out_dir=".",
        )

    # Test range parsing with various formats
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=1:3"], ["job1", "job2", "job3", "job4"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:3,
            out_dir=".",
        )
    
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=1:2:4"], ["job1", "job2", "job3", "job4"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:2:4,
            out_dir=".",
        )

    # Test plain colon (all jobs)
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=:"], ["job1", "job2", "job3"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:3,
            out_dir=".",
        )

    # Test begin/end keywords
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=begin:end"], ["job1", "job2", "job3"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:3,
            out_dir=".",
        )

    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=begin:2:end"], ["job1", "job2", "job3", "job4", "job5"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:2:5,
            out_dir=".",
        )

    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=2:end"], ["job1", "job2", "job3", "job4"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=2:1:4,
            out_dir=".",
        )

    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=begin:3"], ["job1", "job2", "job3", "job4"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:3,
            out_dir=".",
        )

    # Test edge cases and error conditions
    @test (@test_logs (:error, "--batch must be an integer or a range, instead got \"dfgdf\"") MEDYANSimRunner.parse_cli_args(
            String["--batch=dfgdf"], ["job1", "job2"]
        )) === nothing

    @test (@test_logs (:error, "--batch must be an integer or a range, instead got \"1:2:3:4\"") MEDYANSimRunner.parse_cli_args(
            String["--batch=1:2:3:4"], ["job1", "job2", "job3", "job4"]
        )) === nothing

    @test (@test_logs (:error, "--batch must be an integer or a range, instead got \"abc:def\"") MEDYANSimRunner.parse_cli_args(
            String["--batch=abc:def"], ["job1", "job2", "job3", "job4"]
        )) === nothing

    @test (@test_logs (:error, "--batch must be an integer or a range, instead got \"1:abc:3\"") MEDYANSimRunner.parse_cli_args(
            String["--batch=1:abc:3"], ["job1", "job2", "job3", "job4"]
        )) === nothing

    @test (@test_logs (:error, "--batch must be an integer or a range, instead got \"\"") MEDYANSimRunner.parse_cli_args(
            String["--batch="], ["job1", "job2", "job3", "job4"]
        )) === nothing

    # Test out of bounds batch range
    @test (@test_logs (:error, r"--batch must be a subset of 1:2, instead got 3:1:5") MEDYANSimRunner.parse_cli_args(
            String["--batch=3:5"], ["job1", "job2"]
        )) === nothing

    # Test more edge cases
    # Single job range
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=2"], ["job1", "job2", "job3"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=2:3:3,
            out_dir=".",
        )

    # Empty step in range (should default to 1)
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=2:4"], ["job1", "job2", "job3", "job4", "job5"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=2:1:4,
            out_dir=".",
        )

    # Test with mixed begin/end and numbers
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=begin:2"], ["job1", "job2", "job3", "job4"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:2,
            out_dir=".",
        )

    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=3:end"], ["job1", "job2", "job3", "job4"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=3:1:4,
            out_dir=".",
        )

    # Test step size that is larger than range
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=1:10:3"], ["job1", "job2", "job3"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:10:3,
            out_dir=".",
        )

    # Test unused arguments warning
    @test (@test_logs (:warn, "not all ARGS used") MEDYANSimRunner.parse_cli_args(
        String["--bach=dfgdf"], ["job1", "job2"]
        )) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch_range=1:1:2,
            out_dir=".",
        )
    
end