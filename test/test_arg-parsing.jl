using Test
using Logging
using MEDYANSimRunner


@testset "arg parsing" begin
    @test MEDYANSimRunner.parse_cli_args(
            String[], ["job1", "job2"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch=-1,
            outdir=".",
        )
    @test MEDYANSimRunner.parse_cli_args(
            String["--continue"], ["job1", "job2"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=true,
            batch=-1,
            outdir=".",
        )
    @test MEDYANSimRunner.parse_cli_args(
            String["--out=/home/nathan/sim1"], ["job1", "job2"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch=-1,
            outdir="/home/nathan/sim1",
        )
    @test MEDYANSimRunner.parse_cli_args(
            String["--batch=-1"], ["job1", "job2"]
        ) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch=-1,
            outdir=".",
        )
    @test (@test_logs (:error, "--batch must be -1 or in 1:2, instead got 3") MEDYANSimRunner.parse_cli_args(
            String["--batch=3"], ["job1", "job2"]
        )) === nothing
    @test (@test_logs (:error, "--batch must be a integer, instead got \"dfgdf\"") MEDYANSimRunner.parse_cli_args(
            String["--batch=dfgdf"], ["job1", "job2"]
        )) === nothing
    @test (@test_logs (:warn, "not all ARGS used") MEDYANSimRunner.parse_cli_args(
        String["--bach=dfgdf"], ["job1", "job2"]
        )) == MEDYANSimRunner.CLIOptions(;
            continue_sim=false,
            batch=-1,
            outdir=".",
        )
end