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
    run_sim(ARGS; setup, loop, load_snapshot, save_snapshot, done)

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

- `save_snapshot(step::Int, state; kwargs...) -> group::SmallZarrGroups.ZGroup`
is called to save a snapshot.

 - `load_snapshot(step::Int, group::SmallZarrGroups.ZGroup, state; kwargs...) -> state`
is called to load a snapshot.

 - `done(step::Int, state; kwargs...) -> done::Bool, expected_final_step::Int`
is called to check if the simulation is done.

`ARGS` is the command line arguments passed to the script.
This should be a list of strings.
It can include the following optional arguments:

 - `--out=<output directory>` defaults to cwd, where to save the output.
This directory will be created if it does not exist.

 - `--batch=<batch number>` defaults to "-1" which means run all jobs.
If a batch number is given, only run the jobs with that batch number.

 - `--continue` defaults to restart jobs. 
If set, try to continue jobs that were previously interrupted.
"""
function run_sim(cli_args;
        jobs::Vector{String},
        setup,
        loop,
        save_snapshot,
        load_snapshot,
        done,
        kwargs...
    )
    @argcheck !isempty(jobs)
    @argcheck allunique(jobs)
    maybe_options = parse_cli_args(cli_args, jobs)
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
                    save_snapshot,
                    load_snapshot,
                    done,
                )
            else
                start_job(options.out_dir, job;
                    setup,
                    loop,
                    save_snapshot,
                    load_snapshot,
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
                save_snapshot,
                load_snapshot,
                done,
            )
        else
            start_job(options.out_dir, job;
                setup,
                loop,
                save_snapshot,
                load_snapshot,
                done,
            )
        end
    end
    return
end


function start_job(out_dir, job::String;
        setup,
        loop,
        save_snapshot,
        load_snapshot,
        done,
    )
    basic_name_check.(split(job, '/'; keepempty=true))
    # first set up logging
    job_out = mkpath(joinpath(abspath(out_dir), job))
    traj = mkpath(joinpath(job_out, "traj"))
    all_logs = mkpath(joinpath(job_out, "logs"))
    in_new_log_dir(all_logs) do
        FileWatching.Pidfile.mkpidlock("traj.lock"; wait=false) do
            @info "Starting new job."
            @info get_version_string()
            Random.seed!(collect(reinterpret(UInt64, sha256(job))))
            job_header, state = setup(job_idx)
            @info "Setup complete."
            header_str = sprint() do io
                JSON3.pretty(io, job_header; allow_inf = true)
            end
            write_traj_file(traj, "header.json", codeunits(header_str))
            local step::Int = 0
            snapshot_group = ZGroup()
            snapshot_group["snap"] = save_snapshot(step, state)
            attrs(snapshot_group)["rng_state"] = rng_2_str()
            attrs(snapshot_group)["step"] = step
            snapshot_data = zip_group(snapshot_group)
            state = load_snapshot(step, unzip_group(snapshot_data)["snap"], state)
            write_traj_file(traj, SNAP_PREFIX*string(step)*SNAP_POSTFIX, snapshot_data)
            @info "simulation started"
            while true
                state = loop(step, state)
                step += 1
                snapshot_group = ZGroup()
                snapshot_group["snap"] = save_snapshot(step, state)
                attrs(snapshot_group)["rng_state"] = rng_2_str()
                attrs(snapshot_group)["step"] = step
                snapshot_data = zip_group(snapshot_group)
                state = load_snapshot(step, unzip_group(snapshot_data)["snap"], state)
                write_traj_file(traj, SNAP_PREFIX*string(step)*SNAP_POSTFIX, snapshot_data)
                isdone::Bool, expected_final_step::Int64 = done(step::Int, state)
                @info "step $step of $expected_final_step done"
                if isdone
                    write_traj_file(traj, "done.txt", codeunits("$step steps"))
                    @info "simulation completed"
                    break
                end
            end
        end
    end
end



function continue_job(out_dir, job;
        setup,
        loop,
        save_snapshot,
        load_snapshot,
        done,
    )
    basic_name_check.(split(job, '/'; keepempty=true))
    # first set up logging
    job_out = mkpath(joinpath(abspath(out_dir), job))
    traj = mkpath(joinpath(job_out, "traj"))
    all_logs = mkpath(joinpath(job_out, "logs"))
    in_new_log_dir(all_logs) do
        @info "Continuing job."
        @info get_version_string()
        pidlock = try
            FileWatching.Pidfile.mkpidlock("traj.lock"; wait=false)
        catch ex
            ex isa InterruptException && rethrow()
            @warn "failed to get traj.lock, continuing."
            nothing
        end
        # Figure out what step to continue from
        snaps = readdir(traj)
        if "done.txt" ∈ snaps
            @info "Simulation already finished, exiting."
            return
        end
        max_step = if "header.json" ∈ snaps
            local steps = Int64[]
            for file_name in snaps
                isascii(file_name) || continue
                startswith(file_name, SNAP_PREFIX) || continue
                endswith(file_name, SNAP_POSTFIX) || continue
                ncodeunits(file_name) > ncodeunits(SNAP_PREFIX) + ncodeunits(SNAP_POSTFIX)
                local step_part = file_name[begin+ncodeunits(SNAP_PREFIX):end-ncodeunits(SNAP_POSTFIX)]
                local step_maybe = tryparse(Int, step_part)
                if !isnothing(step_maybe)
                    push!(steps, step_maybe)
                end
            end
            @info "Continuing from step $(max_step)"
            maximum(steps; init=-1)
        else
            @info "Starting new simulation."
            -2
        end
        Random.seed!(collect(reinterpret(UInt64, sha256(job))))
        job_header, state = setup(job_idx)
        @info "setup complete."        
        header_str = sprint() do io
            JSON3.pretty(io, job_header; allow_inf = true)
        end
        write_traj_file(traj, "header.json", codeunits(header_str))
        local step::Int = 0
        snapshot_group = ZGroup()
        snapshot_group["snap"] = save_snapshot(step, state)
        attrs(snapshot_group)["rng_state"] = rng_2_str()
        attrs(snapshot_group)["step"] = step
        snapshot_data = zip_group(snapshot_group)
        state = load_snapshot(step, unzip_group(snapshot_data)["snap"], state)
        write_traj_file(traj, "snap$(step).zarr.zip", snapshot_data)
        @info "simulation started"
        while true
            state = loop(step, state)
            step += 1
            snapshot_group = ZGroup()
            snapshot_group["snap"] = save_snapshot(step, state)
            attrs(snapshot_group)["rng_state"] = rng_2_str()
            attrs(snapshot_group)["step"] = step
            snapshot_data = zip_group(snapshot_group)
            state = load_snapshot(step, unzip_group(snapshot_data)["snap"], state)
            write_traj_file(traj, "snap$(step).zarr.zip", snapshot_data)
            isdone::Bool, expected_final_step::Int64 = done(step::Int, state)
            @info "step $step of $expected_final_step done"
            if isdone
                write_traj_file(traj, "done.txt", codeunits("$step steps"))
                @info "simulation completed"
                break
            end
        end
    end
end


function zip_group(g::ZGroup)::Vector{UInt8}
    io = IOBuffer()
    writer = SmallZarrGroups.ZarrZipWriter(io)
    SmallZarrGroups.save_dir(writer, g)
    SmallZarrGroups.closewriter(writer)
    take!(io)
end

function unzip_group(data::Vector{UInt8})::ZGroup
    SmallZarrGroups.load_dir(SmallZarrGroups.ZarrZipReader(data))
end


