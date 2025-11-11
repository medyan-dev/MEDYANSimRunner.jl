function get_version_string()
    """
    Julia Version: $VERSION
    MEDYANSimRunner Version: $(THIS_PACKAGE_VERSION)
    OS: $(Sys.iswindows() ? "Windows" : Sys.isapple() ? "macOS" : Sys.KERNEL) ($(Sys.MACHINE))
    CPU: $(Sys.cpu_info()[1].model)
    WORD_SIZE: $(Sys.WORD_SIZE)
    LLVM: libLLVM-$(Base.libllvm_version) ($(Sys.JIT) $(Sys.CPU_NAME))
    Threads: $(Threads.nthreads()) on $(Sys.CPU_THREADS) virtual cores
    """
end

mutable struct RunState
    rng_state::Random.Xoshiro
    step::Int
    state::Any
    prev_sha256::String
    traj::String
end

function init_run_state(;job, traj, setup, profiler)
    rng_state = Random.Xoshiro(reinterpret(UInt64, sha256(job))...)

    copy!(Random.default_rng(), rng_state)
    job_header, state = @zone profiler setup(job; profiler)
    copy!(rng_state, Random.default_rng())

    header_str = sprint() do io
        JSON3.pretty(io, job_header; allow_inf = true)
    end
    header_str, RunState(rng_state, 0, state, "", traj)
end

function do_a_step!(r::RunState; loop, load, save, done, profiler=NullProfiler())
    output = ZGroup()
    copy!(Random.default_rng(), r.rng_state)
    r.step += 1
    r.state = @zone profiler name="loop" begin
        zone_text!(profiler, "step: $(r.step)")
        loop(r.step, r.state; output, profiler)
    end
    copy!(r.rng_state, Random.default_rng())

    save_load_state!(r; save, load, output, profiler)

    copy!(Random.default_rng(), r.rng_state)
    isdone::Bool, expected_final_step::Int64 = @zone profiler done(r.step, r.state; profiler)
    copy!(r.rng_state, Random.default_rng())

    @info "step $(r.step) of $expected_final_step done"
    frame_mark!(profiler)
    if isdone
        save_footer(r; profiler)
        false
    else
        true
    end
end

"""
    run(ARGS; setup, loop, load, save, done, profiler=NullProfiler())

This function should be called at the end of a script to run a simulation.
It takes keyword arguments:

 - `jobs::AbstractVector{String}`
is a list of jobs. Each job is a string. 
The string should be a valid directory name because 
it will be used as the name of a subdirectory in the output directory.

 - `setup(job::String; kwargs...) -> header_dict, state`
is called once at the beginning of the simulation.

 - `loop(step::Int, state; kwargs...) -> state`
is called once per step of the simulation.

- `save(step::Int, state; kwargs...) -> group::SmallZarrGroups.ZGroup`
is called to save a snapshot.

 - `load(step::Int, group::SmallZarrGroups.ZGroup, state; kwargs...) -> state`
is called to load a snapshot.

 - `done(step::Int, state; kwargs...) -> done::Bool, expected_final_step::Int`
is called to check if the simulation is done.

 - `profiler` (optional)
is a ZoneProfilers profiler instance for performance instrumentation.
Defaults to NullProfiler() for zero runtime overhead.

`ARGS` is the command line arguments passed to the script.

$(CLI_HELP)
"""
function run(cli_args;
        jobs::Vector{String},
        setup,
        loop,
        save,
        load,
        done,
        profiler=NullProfiler(),
        kwargs...
    )
    @nospecialize
    @argcheck !isempty(jobs)
    @argcheck allunique(jobs)
    maybe_options = parse_cli_args(deepcopy(cli_args), jobs)
    if isnothing(maybe_options)
        return
    end
    options::CLIOptions = something(maybe_options)
    app_info!(profiler, get_version_string())
    # TODO run all jobs in parallel
    @info "Running $(length(options.batch_range)) jobs with indexes $(options.batch_range)"
    for job in jobs[options.batch_range]
        if options.continue_sim
            continue_job(options.out_dir, job;
                setup,
                loop,
                save,
                load,
                done,
                profiler,
            )
        else
            start_job(options.out_dir, job;
                setup,
                loop,
                save,
                load,
                done,
                profiler,
            )
        end
    end
    return
end


function start_job(out_dir, job::String;
        setup,
        loop,
        save,
        load,
        done,
        profiler= NullProfiler(),
    )
    basic_name_check.(String.(split(job, '/'; keepempty=true)))
    # first set up logging
    job_out = mkpath(joinpath(abspath(out_dir), job))
    in_new_log_dir(job_out) do
        FileWatching.Pidfile.mkpidlock(joinpath(job_out,"traj.lock"); wait=false) do
            message!(profiler, "Starting new job in $(repr(job_out))")
            @info "Starting new job." job out_dir
            @info get_version_string()
            @zone profiler name="remove old snapshot data" begin
                rm(joinpath(job_out, "traj"); recursive=true, force=true)
            end
            traj = mkpath(joinpath(job_out, "traj"))
            header_str, r = init_run_state(;job, traj, setup, profiler)
            r.prev_sha256 = write_traj_file(traj, "header.json", codeunits(header_str); profiler)
            save_load_state!(r; save, load, profiler)
            while do_a_step!(r; loop, load, save, done, profiler)
            end
        end
    end
end



function continue_job(out_dir, job;
        setup,
        loop,
        save,
        load,
        done,
        profiler=NullProfiler(),
    )
    basic_name_check.(String.(split(job, '/'; keepempty=true)))
    # first set up logging
    job_out = mkpath(joinpath(abspath(out_dir), job))
    in_new_log_dir(job_out) do
        message!(profiler, "Continuing job in $(repr(job_out))")
        @info "Continuing job." job out_dir
        @info get_version_string()
        pidlock = try
            FileWatching.Pidfile.mkpidlock(joinpath(job_out,"traj.lock"); wait=false)
        catch ex
            ex isa InterruptException && rethrow()
            message!(profiler, "failed to get traj.lock, continuing.")
            @warn "failed to get traj.lock, continuing."
            nothing
        end
        try
            traj = mkpath(joinpath(job_out, "traj"))
            # Figure out what step to continue from
            status = @zone profiler status_traj_dir(traj)
            if status == :done
                message!(profiler, "Simulation already finished, exiting.")
                @info "Simulation already finished, exiting."
                return
            end
            step::Int = status

            header_str, r = init_run_state(;job, traj, setup, profiler)

            if step == -2 || step == -1
                @info "Simulation restarting."
                r.prev_sha256 = write_traj_file(traj, "header.json", codeunits(header_str); profiler)
                save_load_state!(r; save, load, profiler)
            else
                @info "Continuing simulation from step $(step)."
                r.step = step
                snapshot_data = @zone profiler read(joinpath(traj, step_path(step)))
                snapshot_group = @zone profiler unzip_group(snapshot_data)
                reread_sub_snapshot_group = snapshot_group["snap"]
                r.rng_state = str_2_rng(attrs(snapshot_group)["rng_state"])

                copy!(Random.default_rng(), r.rng_state)
                r.state = @zone profiler load(r.step, reread_sub_snapshot_group, r.state; profiler)
                copy!(r.rng_state, Random.default_rng())

                r.prev_sha256 = bytes2hex(sha256(snapshot_data))
                if step > 0
                    # check if done here.
                    copy!(Random.default_rng(), r.rng_state)
                    isdone::Bool, expected_final_step::Int64 = @zone profiler done(step::Int, r.state; profiler)
                    copy!(r.rng_state, Random.default_rng())
                    @info "step $step of $expected_final_step done"
                    if isdone
                        save_footer(r; profiler)
                        return
                    end
                end
            end
            while do_a_step!(r; loop, load, save, done, profiler)
            end
        finally
            isnothing(pidlock) || close(pidlock)
        end
    end
end

function save_load_state!(
        r::RunState;
        save,
        load,
        output= nothing,
        profiler= NullProfiler(),
    )
    @zone profiler name="io" begin
        snapshot_group = ZGroup()

        copy!(Random.default_rng(), r.rng_state)
        sub_snapshot_group = @zone profiler save(r.step, r.state; profiler)
        copy!(r.rng_state, Random.default_rng())

        snapshot_group["snap"] = sub_snapshot_group
        if !isnothing(output)
            snapshot_group["out"] = output
        end
        attrs(snapshot_group)["rng_state"] = rng_2_str(r.rng_state)
        attrs(snapshot_group)["step"] = r.step
        attrs(snapshot_group)["prev_sha256"] = r.prev_sha256
        snapshot_data = @zone profiler zip_group(snapshot_group)
        reread_sub_snapshot_group = @zone(profiler, unzip_group(snapshot_data))["snap"]

        copy!(Random.default_rng(), r.rng_state)
        r.state = @zone profiler load(r.step, reread_sub_snapshot_group, r.state; profiler)
        copy!(r.rng_state, Random.default_rng())

        # avoid over 1000 files in a directory
        sp = step_path(r.step)
        mkpath(dirname(joinpath(r.traj, sp)))
        r.prev_sha256 = write_traj_file(r.traj, sp, snapshot_data; profiler)
        nothing
    end
end

function save_footer(r::RunState; profiler=NullProfiler())
    job_footer = OrderedCollections.OrderedDict([
        "steps" => r.step,
        "prev_sha256" => r.prev_sha256,
    ])
    footer_str = sprint() do io
        JSON3.pretty(io, job_footer; allow_inf = true)
    end
    write_traj_file(r.traj, "footer.json", codeunits(footer_str); profiler)
    @info "Simulation completed."
end

function zip_group(g::ZGroup)::Vector{UInt8}
    io = IOBuffer()
    SmallZarrGroups.save_zip(io, g)
    take!(io)
end

# ignores the top level "out" group
function unzip_group(data::Vector{UInt8})::ZGroup
    SmallZarrGroups.load_zip(data;
        predicate=!startswith("out/"),
    )
end


