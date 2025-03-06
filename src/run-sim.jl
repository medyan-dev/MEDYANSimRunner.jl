import InteractiveUtils
import LoggingExtras
import JSON3
using Logging
import Dates
using SHA: sha256
using ArgCheck
using SmallZarrGroups
import Random
import FileWatching
import OrderedCollections



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

"""
    run(ARGS; setup, loop, load, save, done)

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
    if options.batch == -1
        # TODO run all jobs in parallel
        for job in jobs
            if options.continue_sim
                continue_job(options.out_dir, job;
                    setup,
                    loop,
                    save,
                    load,
                    done,
                )
            else
                start_job(options.out_dir, job;
                    setup,
                    loop,
                    save,
                    load,
                    done,
                )
            end
        end
    else
        job = jobs[options.batch]
        if options.continue_sim
            continue_job(options.out_dir, job;
                setup,
                loop,
                save,
                load,
                done,
            )
        else
            start_job(options.out_dir, job;
                setup,
                loop,
                save,
                load,
                done,
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
    )
    basic_name_check.(String.(split(job, '/'; keepempty=true)))
    # first set up logging
    job_out = mkpath(joinpath(abspath(out_dir), job))
    in_new_log_dir(job_out) do
        FileWatching.Pidfile.mkpidlock(joinpath(job_out,"traj.lock"); wait=false) do
            @info "Starting new job." job out_dir
            @info get_version_string()

            # remove old snapshot data
            rm(joinpath(job_out, "traj"); recursive=true, force=true)
            traj = mkpath(joinpath(job_out, "traj"))

            rng_state = Random.Xoshiro(reinterpret(UInt64, sha256(job))...)
            copy!(Random.default_rng(), rng_state)
            job_header, state = setup(job)
            copy!(rng_state, Random.default_rng())
            
            @info "Setup complete."
            header_str = sprint() do io
                JSON3.pretty(io, job_header; allow_inf = true)
            end
            prev_sha256 = bytes2hex(sha256(header_str))
            write_traj_file(traj, "header.json", codeunits(header_str))
            local step::Int = 0

            state, prev_sha256 = save_load_state!(rng_state, step, state, traj, save, load, prev_sha256)
            @info "Simulation started."
            while true
                output = ZGroup()
                copy!(Random.default_rng(), rng_state)
                state = loop(step, state; output)
                copy!(rng_state, Random.default_rng())

                step += 1
                state, prev_sha256 = save_load_state!(rng_state, step, state, traj, save, load, prev_sha256, output)

                copy!(Random.default_rng(), rng_state)
                isdone::Bool, expected_final_step::Int64 = done(step::Int, state)
                copy!(rng_state, Random.default_rng())

                @info "step $step of $expected_final_step done"
                if isdone
                    save_footer(traj, step, prev_sha256)
                    return
                end
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
    )
    basic_name_check.(String.(split(job, '/'; keepempty=true)))
    # first set up logging
    job_out = mkpath(joinpath(abspath(out_dir), job))
    traj = mkpath(joinpath(job_out, "traj"))
    in_new_log_dir(job_out) do
        @info "Continuing job." job out_dir
        @info get_version_string()
        pidlock = try
            FileWatching.Pidfile.mkpidlock(joinpath(job_out,"traj.lock"); wait=false)
        catch ex
            ex isa InterruptException && rethrow()
            @warn "failed to get traj.lock, continuing."
            nothing
        end
        try
            # Figure out what step to continue from
            status = status_traj_dir(traj)
            if status == :done
                @info "Simulation already finished, exiting."
                return
            end
            step::Int = status
            @info "Setting up simulation."
            rng_state = Random.Xoshiro(reinterpret(UInt64, sha256(job))...)
            copy!(Random.default_rng(), rng_state)
            job_header, state = setup(job)
            copy!(rng_state, Random.default_rng())
            @info "Setup complete."
            if step == -2 || step == -1
                header_str = sprint() do io
                    JSON3.pretty(io, job_header; allow_inf = true)
                end
                prev_sha256 = bytes2hex(sha256(header_str))
                write_traj_file(traj, "header.json", codeunits(header_str))
                step = 0
                state, prev_sha256 = save_load_state!(rng_state, step, state, traj, save, load, prev_sha256)
                @info "Simulation started."
            else
                @info "Continuing simulation from step $(step)."
                snapshot_data = read(joinpath(traj, step_path(step)))
                snapshot_group = unzip_group(snapshot_data)
                reread_sub_snapshot_group = snapshot_group["snap"]
                rng_state = str_2_rng(attrs(snapshot_group)["rng_state"])
                copy!(Random.default_rng(), rng_state)
                state = load(step, reread_sub_snapshot_group, state)
                copy!(rng_state, Random.default_rng())
                prev_sha256 = bytes2hex(sha256(snapshot_data))
                if step > 0
                    # check if done here.
                    copy!(Random.default_rng(), rng_state)
                    isdone::Bool, expected_final_step::Int64 = done(step::Int, state)
                    copy!(rng_state, Random.default_rng())
                    @info "step $step of $expected_final_step done"
                    if isdone
                        save_footer(traj, step, prev_sha256)
                        return
                    end
                end
            end
            while true
                output = ZGroup()
                copy!(Random.default_rng(), rng_state)
                state = loop(step, state; output)
                copy!(rng_state, Random.default_rng())

                step += 1
                state, prev_sha256 = save_load_state!(rng_state, step, state, traj, save, load, prev_sha256, output)

                copy!(Random.default_rng(), rng_state)
                isdone, expected_final_step = done(step::Int, state)
                copy!(rng_state, Random.default_rng())

                @info "step $step of $expected_final_step done"
                if isdone
                    save_footer(traj, step, prev_sha256)
                    return
                end
            end
        finally
            isnothing(pidlock) || close(pidlock)
        end
    end
end


function save_load_state!(
        rng_state,
        step::Int,
        state,
        traj::String,
        save,
        load,
        prev_sha256::String,
        output::Union{Nothing, ZGroup}=nothing,
    )
    snapshot_group = ZGroup()

    copy!(Random.default_rng(), rng_state)
    sub_snapshot_group = save(step, state)
    copy!(rng_state, Random.default_rng())

    snapshot_group["snap"] = sub_snapshot_group
    if !isnothing(output)
        snapshot_group["out"] = output
    end
    attrs(snapshot_group)["rng_state"] = rng_2_str(rng_state)
    attrs(snapshot_group)["step"] = step
    attrs(snapshot_group)["prev_sha256"] = prev_sha256
    snapshot_data = zip_group(snapshot_group)
    reread_sub_snapshot_group = unzip_group(snapshot_data)["snap"]

    copy!(Random.default_rng(), rng_state)
    state = load(step, reread_sub_snapshot_group, state)
    copy!(rng_state, Random.default_rng())

    # avoid over 1000 files in a directory
    sp = step_path(step)
    mkpath(dirname(joinpath(traj, sp)))
    write_traj_file(traj, sp, snapshot_data)
    state, bytes2hex(sha256(snapshot_data))
end

function save_footer(traj, step, prev_sha256)
    job_footer = OrderedCollections.OrderedDict([
        "steps" => step,
        "prev_sha256" => prev_sha256,
    ])
    footer_str = sprint() do io
        JSON3.pretty(io, job_footer; allow_inf = true)
    end
    write_traj_file(traj, "footer.json", codeunits(footer_str))
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


