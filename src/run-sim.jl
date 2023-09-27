import InteractiveUtils
import LoggingExtras
import JSON3
using Logging
import Dates
using SHA: sha256
using ArgCheck
using SmallZarrGroups
import Random

const THIS_PACKAGE_VERSION::String = string(pkgversion(@__MODULE__))

const VERSION_INFO::String = """
    Julia Version: $VERSION
    MEDYANSimRunner Version: $(THIS_PACKAGE_VERSION)
    OS: $(Sys.iswindows() ? "Windows" : Sys.isapple() ? "macOS" : Sys.KERNEL) ($(Sys.MACHINE))
    CPU: $(Sys.cpu_info()[1].model)
    WORD_SIZE: $(Sys.WORD_SIZE)
    LLVM: libLLVM-$(Base.libllvm_version) ($(Sys.JIT) $(Sys.CPU_NAME))
    Threads: $(Threads.nthreads()) on $(Sys.CPU_THREADS) virtual cores
    """

const DATE_FORMAT = Dates.dateformat"yyyy-mm-ddTHH:MM:SS"

# amount to pad step count by with lpad
const STEP_PAD = 10




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
    # first set up logging
    job_out = mkpath(joinpath(abspath(out_dir), job))
    snaps = mkpath(joinpath(job_out, "snapshots"))
    all_logs = mkpath(joinpath(job_out, "logs"))
    logs = make_new_version(all_logs)
    # now logs is a fresh directory to save logs to for this run.
    logger = LoggingExtras.TeeLogger(
        global_logger(),
        timestamp_logger(joinpath(logs, "info.log"), Logging.Info),
        timestamp_logger(joinpath(logs, "warn.log"), Logging.Warn),
        timestamp_logger(joinpath(logs, "error.log"), Logging.Error),
    )
    list_file = open(joinpath(logs, "list.txt"); write=true)
    with_logger(logger) do
        @info "Starting new job."
        @info VERSION_INFO
        Random.seed!(collect(reinterpret(UInt64, sha256(job))))
        job_header, state = setup(job_idx)
        @info "setup complete."
        header_str = sprint() do io
            JSON3.pretty(io, job_header; allow_inf = true)
        end
        header_sha256 = bytes2hex(sha256(header_str))
        write(joinpath(logs, "header.json"), header_str)
        println_list(list_file,
            "version = 2 | job = $job | header_sha256 = $header_sha256"
        )
        local step::Int = 0
        snapshot_data = zip_group(save_snapshot(step, state))
        snapshot_rng = rng_2_str()
        state = load_snapshot(step, unzip_group(snapshot_data), state)
        snapshot_sha256 = bytes2hex(sha256(snapshot_data))
        println_list(list_file, 
            "$(Dates.format(now(),DATE_FORMAT)) | $(string(step, pad=STEP_PAD)) | $(snapshot_rng) | $(snapshot_sha256)"
        )
        write(joinpath(snaps, string(step, pad=STEP_PAD)*"_"*snapshot_sha256*".zarr.zip"), snapshot_data)
        @info "simulation started"
        while true
            state = loop(step, state)
            step += 1
            snapshot_data = zip_group(save_snapshot(step, state))
            snapshot_rng = rng_2_str()
            state = load_snapshot(step, unzip_group(snapshot_data), state)
            snapshot_sha256 = bytes2hex(sha256(snapshot_data))
            println_list(list_file, 
                "$(Dates.format(now(),DATE_FORMAT)) | $(string(step, pad=STEP_PAD)) | $(snapshot_rng) | $(snapshot_sha256)"
            )
            write(joinpath(snaps, string(step, pad=STEP_PAD)*"_"*snapshot_sha256*".zarr.zip"), snapshot_data)
            isdone::Bool, expected_final_step::Int64 = done(step::Int, state)
            @info "step $step of $expected_final_step done"
            if isdone
                println_list(list_file, "Done")
                @info "simulation completed"
                break
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
    error("continuing a job is not implemented yet")

end



"""
Print a `str` and add " | (hex sha256 of the line)\n", and then flush
"""
function println_list(io::IO, str::AbstractString)
    println(io,str, " | ", bytes2hex(sha256(str)))
    flush(io)
    nothing
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


function timestamp_logger(file, level) 
    LoggingExtras.MinLevelLogger(
        LoggingExtras.TransformerLogger(
            LoggingExtras.FileLogger(file; append=true),
        ) do log
            merge(log, (; message = "$(Dates.format(Dates.now(), DATE_FORMAT)) $(log.message)"))
        end,
        level,
    )
end