using Test

using Distributed

using MEDYANSimRunner


@testset "timeout normal cases" begin
    worker = addprocs(1;
        topology=:master_worker,
    )[1]
    state, result = MEDYANSimRunner.run_with_timeout(worker, 1000.0, quote
        1+1
    end)

    @test state === :ok
    @test result === 2

    state, result = MEDYANSimRunner.run_with_timeout(worker, 1.0, quote
        sleep(0.1)
        1+1
    end)

    @test state === :ok
    @test result === 2

    state, result = MEDYANSimRunner.run_with_timeout(worker, 0.1, quote
        sleep(1.0)
        1+1
    end)

    @test state == :timed_out
    @test result === nothing

    @test !(worker in workers())

    worker = addprocs(1;
        topology=:master_worker,
    )[1]

    state, result = MEDYANSimRunner.run_with_timeout(worker, 1000.0, quote
        1+1
    end)

    @test state === :ok
    @test result === 2

    state, result = MEDYANSimRunner.run_with_timeout(worker, 1000.0, quote
        exit()
    end)

    @test state === :worker_exited
    @test result === nothing

    @test !(worker in workers())

    worker = addprocs(1;
        topology=:master_worker,
    )[1]

    state, result = MEDYANSimRunner.run_with_timeout(worker, 1000.0, quote
        error("wow")
    end)

    @test state === :errored
    @test startswith(result, "wow\nStacktrace:\n [1] error\n")
    
    state, result = MEDYANSimRunner.run_with_timeout(worker, 1000.0, quote
        1+1
    end)

    @test state === :ok
    @test result === 2

    state, result = MEDYANSimRunner.run_with_timeout(worker, 0.1, quote
        function foo()
            x = rand()
            while x > 0.000001
                x += rand()
            end
            x
        end
        foo()
    end)

    @test state == :timed_out
    @test result === nothing

    @test !(worker in workers())

    worker in workers() && rmprocs(worker)
end