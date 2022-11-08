module MEDYANSimRunner

import Comonicon
import InteractiveUtils
using LoggingExtras
using Logging
using TOML
using Dates
using SHA
using Distributed
import Pkg
import Random

include("timeout.jl")

const DATE_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

# amount to pad step count by with lpad
const STEP_PAD = 7

"""
Return a string describing the state of the rng without any newlines or commas
"""
function rng_2_str(rng = Random.default_rng())::String
    myrng = copy(rng)
    if typeof(myrng)==Random.Xoshiro
        "Xoshiro: $(repr(myrng.s0)) $(repr(myrng.s1)) $(repr(myrng.s2)) $(repr(myrng.s3))"
    else
        error("rng of type $(typeof(myrng)) not supported yet")
    end
end

"""
Decode an rng stored in a string.
"""
function str_2_rng(str::AbstractString)::Random.AbstractRNG
    parts = split(str, " ")
    parts[1] == "Xoshiro:" || error("rng type must be Xoshiro not $(parts[1])")
    state = parse.(UInt64, parts[2:end])
    Random.Xoshiro(state...)
end

include("listparse.jl")

timestamp_logger(logger) = TransformerLogger(logger) do log
    merge(log, (; message = "$(Dates.format(now(), DATE_FORMAT)) $(log.message)"))
end

"""
Return true if the input_dir is valid.

Otherwise log errors and return false.
"""
function is_input_dir_valid(input_dir::AbstractString)
    if !isdir(input_dir)
        @error "input directory $input_dir not found."
        return false
    end
    required_toml_files = [
        "Manifest.toml",
        "Project.toml",
    ]
    required_files = [
        required_toml_files;
        "main.jl";
    ]
    # check that required files exist
    iszero(sum(required_files) do required_file
        if !isfile(joinpath(input_dir,required_file))
            @error "$required_file missing from $input_dir."
            true
        else
            false
        end
    end) || return false

    # check that toml files don't have syntax errors
    iszero(sum(required_toml_files) do required_toml_file
        ex = TOML.tryparsefile(joinpath(input_dir,required_toml_file))
        if ex isa TOML.ParserError
            @error "invalid toml syntax." exception=ex
            true
        else
            false
        end
    end) || return false

    return true
end

"""
Print a `str` and add ", (hex sha256 of the line)\n", and then flush
"""
function println_list(io::IO, str::AbstractString)
    println(io,str, ", ", bytes2hex(sha256(str)))
    flush(io)
    nothing
end

"""
Start or continue a simulation job.

# Args

- `input_dir`: The input directory.
- `output_dir`: The output directory.
- `job_idx`: The job index for multi-job simulations, starts at 1.

# Options

- `--step_timeout`: max amount of time a step can take in seconds.
- `--max_steps`: max number of steps.
- `--startup_timeout`: max amount of time job startup can take in seconds.
- `--max_snapshot_MB`: max amount of disk space one snapshot can take up.

"""
Comonicon.@main function main(input_dir::AbstractString, output_dir::AbstractString, job_idx::Int;
        step_timeout::Float64=100.0,
        max_steps::Int=1_000_000,
        startup_timeout::Float64=1000.0,
        max_snapshot_MB::Float64=1E3,
    )
    job_idx > 0 || throw(ArgumentError("job_idx must be greater than 0"))

    # first make the output folder
    jobout = abspath(mkpath(joinpath(output_dir,"out$job_idx")))

    # Don't use regular Base.open with append=true to make log files
    # because it overwrites appends from other processes.
    # Maybe add Base.Filesystem.JL_O_SYNC?
    log_flags = Base.Filesystem.JL_O_APPEND | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_WRONLY
    log_perm = Base.Filesystem.S_IROTH | Base.Filesystem.S_IRGRP | Base.Filesystem.S_IWGRP | Base.Filesystem.S_IRUSR | Base.Filesystem.S_IWUSR

    # next set up logging
    info_logger = ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"info.log"), log_flags, log_perm), Logging.Info)
    warn_logger = ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"warn.log"), log_flags, log_perm), Logging.Warn)
    error_logger = ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"error.log"), log_flags, log_perm), Logging.Error)
    logger = TeeLogger(
        global_logger(),
        timestamp_logger(info_logger),
        timestamp_logger(warn_logger),
        timestamp_logger(error_logger),
    )
    global_logger(logger)

    # now start writing to a file every second to detect multiple processes trying to run the same job
    # any process that detects this should log an error and exit.
    detect_mult_runners_f = Base.Filesystem.open(joinpath(jobout, "detect-mult-process"), log_flags, log_perm)
    detect_mult_runners_size = Ref(filesize(detect_mult_runners_f))
    Timer(0.0; interval=0.5) do t
        write(detect_mult_runners_f, 0x41)
        flush(detect_mult_runners_f)
        detect_mult_runners_size[] += 1
        if filesize(detect_mult_runners_f) != detect_mult_runners_size[]
            @error "multiple runners are running this job, exiting"
            exit(1)
        end
    end
    sleep(1.1)

    input_dir_valid = is_input_dir_valid(input_dir)
    if !input_dir_valid
        exit(1)
    end
    
    list_info, list_file_good_lines = try
        parse_list_file(joinpath(jobout,"list.txt"))
    catch ex
        @error "invalid list.txt syntax." exception=ex
        rethrow()
        exit(1)
    end

    # check if simulation is aready done
    # note: this doesn't validate the snapshot files, or input files.
    if !isempty(list_info.final_message)
        @info "simulation already complete, exiting"
        exit()
    end

    input_git_tree_sha1 = Pkg.GitTools.tree_hash(input_dir)
    
    # start the worker
    # add processes on the same machine  with the specified input dir
    worker = addprocs(1;
        topology=:master_worker,
        exeflags="--project",
        dir=input_dir,
    )[1]

    worker_nthreads = remotecall_fetch(Threads.nthreads, worker)
    # worker_versioninfo = replace(sprint(InteractiveUtils.versioninfo), "\n"=>" ", ","=>" ")

    # Shared startup code
    worker_startup_code = Expr(:toplevel, (quote
            filter!(LOAD_PATH) do path
                path != "@v#.#"
            end;
            import Pkg; Pkg.instantiate()
            import Dates
            import LoggingExtras
            import Logging
            import JSON3
            import HDF5
            import Random
            worker_timestamp_logger(logger) = LoggingExtras.TransformerLogger(logger) do log
                merge(log, (; message = "$(Dates.format(Dates.now(), $DATE_FORMAT)) $(log.message)"))
            end            
            LoggingExtras.TeeLogger(
                # Logging.global_logger(),
                worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath($jobout,"info.log"),  $log_flags, $log_perm), Logging.Info)),
                worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath($jobout,"warn.log"),  $log_flags, $log_perm), Logging.Warn)),
                worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath($jobout,"error.log"), $log_flags, $log_perm), Logging.Error)),
            ) |> Logging.global_logger
            
            const worker_version_info::String = """
            Julia Version: $VERSION \
            OS: $(Sys.iswindows() ? "Windows" : Sys.isapple() ? "macOS" : Sys.KERNEL) ($(Sys.MACHINE)) \
            CPU: $(Sys.cpu_info()[1].model) \
            WORD_SIZE: $(Sys.WORD_SIZE) \
            LIBM: $(Base.libm_name) \
            LLVM: libLLVM-$(Base.libllvm_version) ($(Sys.JIT) $(Sys.CPU_NAME)) \
            Threads: $(Threads.nthreads()) on $(Sys.CPU_THREADS) virtual cores \
            """

            """
            Return a string describing the state of the rng without any newlines or commas
            """
            function worker_rng_2_str(rng = Random.default_rng())::String
                myrng = copy(rng)
                if typeof(myrng)==Random.Xoshiro
                    "Xoshiro: $(repr(myrng.s0)) $(repr(myrng.s1)) $(repr(myrng.s2)) $(repr(myrng.s3))"
                else
                    error("rng of type $(typeof(myrng)) not supported yet")
                end
            end

            const worker_rng_str0 = Ref("")
            const worker_rng_str1 = Ref("")
            const worker_rng_copy = copy(Random.default_rng())
            module UserCode
                include("main.jl")
            end
            job_header, state =  UserCode.setup($job_idx)
        end).args...)

    # if list is empty start new job, otherwise continue the job
    local step::Int
    local worker_versioninfo::String
    if iszero(list_info.job_idx)
        @info "starting new job"
        step = 0
        # delete stuff from dir and remake it
        snapshot_dir = joinpath(jobout,"snapshots")
        rm(snapshot_dir; force=true, recursive=true)
        rm(joinpath(jobout,"list.txt"); force=true)
        rm(joinpath(jobout,"header.json"); force=true)
        list_file = Base.Filesystem.open(joinpath(jobout,"list.txt"), log_flags, log_perm)
        mkdir(snapshot_dir)
        println_list(list_file,
            "version = 1, job_idx = $job_idx, input_git_tree_sha1 = $(bytes2hex(input_git_tree_sha1))"
        )

        @info "starting up simulation"
        status, result = run_with_timeout(worker, startup_timeout, Expr(worker_startup_code.head, worker_startup_code.args..., (quote
            step::Int = $step    
            open(joinpath($jobout,"header.json"), "w") do io
                JSON3.pretty(io, job_header)
            end
            state = HDF5.h5open(joinpath($jobout,"snapshots","snapshot$step.h5"), "w") do job_file
                UserCode.save_snapshot(step, job_file, state)
                worker_rng_str0[] = worker_rng_2_str()
                UserCode.load_snapshot(step, job_file, state)
            end
            state = UserCode.loop(step, state)
            step += 1
            state = HDF5.h5open(joinpath($jobout,"snapshots","snapshot$step.h5"), "w") do job_file
                UserCode.save_snapshot(step, job_file, state)
                worker_rng_str1[] = worker_rng_2_str()
                UserCode.load_snapshot(step, job_file, state)
            end
            isdone::Bool, expected_final_step::Int64 = UserCode.done(step, state)
            copy!(worker_rng_copy, Random.default_rng())
            isdone, expected_final_step, worker_rng_str0[], worker_rng_str1[], worker_version_info
        end).args...))
        if status != :ok
            @error "failed to startup, status: $status"
            if status === :timed_out
                println_list(list_file, "Error startup_timeout of $startup_timeout seconds reached")
            else
                @error result
                println_list(list_file, "Error starting job")
            end
            exit(1)
        end
        worker_versioninfo = result[5]
        header_sha256 = open(joinpath(jobout,"header.json")) do io
            sha256(io)
        end
        println_list(list_file, "header_sha256 = $(bytes2hex(header_sha256))")
        snapshot0_sha256 = open(joinpath(jobout,"snapshots","snapshot0.h5")) do io
            sha256(io)
        end
        println_list(list_file,
            "$(Dates.format(now(),DATE_FORMAT)), \
            $(lpad(0,STEP_PAD)), \
            $worker_nthreads, \
            $worker_versioninfo, \
            $(result[3]), \
            $(bytes2hex(snapshot0_sha256))"
        )
        snapshot1_sha256 = open(joinpath(jobout,"snapshots","snapshot1.h5")) do io
            sha256(io)
        end
        println_list(list_file,
            "$(Dates.format(now(),DATE_FORMAT)), \
            $(lpad(1,STEP_PAD)), \
            $worker_nthreads, \
            $worker_versioninfo, \
            $(result[4]), \
            $(bytes2hex(snapshot1_sha256))"
        )
        if result[1]
            @info "simulation completed"
            println_list(list_file, "Done")
            exit()
        end
        step = 1
        @info "Step 1 of $(result[2]) done"
    else
        # Continue from an old job
        @info "continuing job"
        # check list_info is valid 
        if list_info.input_git_tree_sha1 != input_git_tree_sha1
            @error "input_git_tree_sha1 was $(bytes2hex(list_info.input_git_tree_sha1)) now is $(bytes2hex(input_git_tree_sha1))"
            exit(1)
        end
        if list_info.job_idx != job_idx
            @error "job_idx was $(list_info.job_idx) now is $job_idx"
            exit(1)
        end
        # header isn't needed to continue the simulation, if the input hasn't changed, lets assume the header is still OK

        @info "finding last valid snapshot to load"
        snapshot_i = length(list_info.snapshot_infos)
        while snapshot_i > 0
            snapshot_info = list_info.snapshot_infos[snapshot_i]
            snapshot_file = joinpath(jobout,"snapshots","snapshot$(snapshot_info.step_number).h5")
            if isfile(snapshot_file)
                snapshot_file_sha256 = open(snapshot_file) do io
                    sha256(io)
                end
                if snapshot_info.snapshot_sha256 == snapshot_file_sha256
                    break
                end
            end
            snapshot_i -= 1
        end
        if iszero(snapshot_i)
            @error "None of the recorded snapshots are valid."
            exit(1)
        end
        snapshot_info = list_info.snapshot_infos[snapshot_i]
        snapshot_file = joinpath(jobout,"snapshots","snapshot$(snapshot_info.step_number).h5")
        step = snapshot_info.step_number
        worker_rng_state = (snapshot_info.rngstate.s0, snapshot_info.rngstate.s1, snapshot_info.rngstate.s2, snapshot_info.rngstate.s3)

        @info "restarting simulation from step $step"

        # delete stuff from dir and remake it
        snapshot_dir = joinpath(jobout,"snapshots")
        #rewrite list file to remove broken lines.
        list_file_str = join(list_file_good_lines[begin:end-(length(list_info.snapshot_infos)-snapshot_i)], "\n")*"\n"
        write(joinpath(jobout,"list.txt"), list_file_str)
        list_file = Base.Filesystem.open(joinpath(jobout,"list.txt"), log_flags, log_perm)

        status, result = run_with_timeout(worker, startup_timeout, Expr(worker_startup_code.head, worker_startup_code.args..., (quote
            step::Int = $step
            state = HDF5.h5open(joinpath($jobout,"snapshots","snapshot$step.h5"), "r") do job_file
                copy!(Random.default_rng(), Random.Xoshiro(($worker_rng_state)...))
                UserCode.load_snapshot(step, job_file, state)
            end
            isdone::Bool, expected_final_step::Int64 = UserCode.done(step, state)
            copy!(worker_rng_copy, Random.default_rng())
            isdone, expected_final_step, worker_version_info
        end).args...))
        if status != :ok
            @error "failed to restartup, status: $status"
            if status === :timed_out
                println_list(list_file, "Error restartup_timeout of $startup_timeout seconds reached")
            else
                @error result
                println_list(list_file, "Error restarting job")
            end
            exit(1)
        end
        @info "Done restarting simulation from step $step"
        worker_versioninfo = result[3]

        if result[1]
            @info "simulation completed"
            println_list(list_file, "Done")
            exit()
        end
    end
    while step < max_steps
        status, result = run_with_timeout(worker, step_timeout, quote
            copy!(Random.default_rng(), worker_rng_copy)
            state = UserCode.loop(step, state)
            step += 1
            state = HDF5.h5open(joinpath($jobout,"snapshots","snapshot$step.h5"), "w") do job_file
                UserCode.save_snapshot(step, job_file, state)
                worker_rng_str0[] = worker_rng_2_str()
                UserCode.load_snapshot(step, job_file, state)
            end
            isdone::Bool, expected_final_step::Int64 = UserCode.done(step, state)
            copy!(worker_rng_copy, Random.default_rng())
            isdone, expected_final_step, worker_rng_str0[]
        end)
        step += 1
        if status != :ok
            @error "failed to step, status: $status"
            if status === :timed_out
                @error "step_timeout of $step_timeout seconds reached"
                println_list(list_file, "Error step_timeout of $step_timeout seconds reached")
            else
                @error result
                println_list(list_file, "Error running job")
            end
            exit(1)
        end
        snapshot_filename = joinpath(jobout,"snapshots","snapshot$step.h5")
        snapshot_sha256 = open(snapshot_filename) do io
            sha256(io)
        end
        println_list(list_file,
            "$(Dates.format(now(),DATE_FORMAT)), \
            $(lpad(step,STEP_PAD)), \
            $worker_nthreads, \
            $worker_versioninfo, \
            $(result[3]), \
            $(bytes2hex(snapshot_sha256))"
        )
        @info "Step $step of $(result[2]) done"

        if result[1]
            @info "simulation completed"
            println_list(list_file, "Done")
            exit()
        end

        if filesize(snapshot_filename) > max_snapshot_MB*2^20
            @error "snapshot too large, $(filesize(snapshot_filename)/2^20) MB"
            @error "max_snapshot_MB of $max_snapshot_MB MB reached"
            println_list(list_file, "Error max_snapshot_MB of $max_snapshot_MB MB reached")
            exit(1)
        end
    end
    @error "max_steps of $max_steps steps reached"
    println_list(list_file, "Error max_steps of $max_steps steps reached")
    exit(1)
end



















end # module MEDYANSimRunner
