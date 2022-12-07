module MEDYANSimRunner

import Comonicon
import InteractiveUtils
using LoggingExtras
using Logging
using TOML
using Dates
using SHA
using Distributed
import Random

include("timeout.jl")
include("treehash.jl")

const DATE_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

# amount to pad step count by with lpad
const STEP_PAD = 7


    # Don't use regular Base.open with append=true to make log files
    # because it overwrites appends from other processes.
    # Maybe add Base.Filesystem.JL_O_SYNC?
const LOG_FLAGS = Base.Filesystem.JL_O_APPEND | Base.Filesystem.JL_O_CREAT | Base.Filesystem.JL_O_WRONLY
const LOG_PERMISSIONS = Base.Filesystem.S_IROTH | Base.Filesystem.S_IRGRP | Base.Filesystem.S_IWGRP | Base.Filesystem.S_IRUSR | Base.Filesystem.S_IWUSR

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

"""
Shared startup code
"""
const WORKER_STARTUP_CODE = Expr(:toplevel, (quote
    copy!(LOAD_PATH,["@","@stdlib",])
    import Pkg; Pkg.instantiate()
    import Dates
    import LoggingExtras
    import Logging
    import JSON3
    import StorageTrees
    import Random
    worker_timestamp_logger(logger) = LoggingExtras.TransformerLogger(logger) do log
        merge(log, (; message = "$(Dates.format(Dates.now(), $DATE_FORMAT)) $(log.message)"))
    end
    jobout = ENV["MEDYAN_JOBOUT"]
    LoggingExtras.TeeLogger(
        # Logging.global_logger(),
        worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"info.log"),  $LOG_FLAGS, $LOG_PERMISSIONS), Logging.Info)),
        worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"warn.log"),  $LOG_FLAGS, $LOG_PERMISSIONS), Logging.Warn)),
        worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"error.log"), $LOG_FLAGS, $LOG_PERMISSIONS), Logging.Error)),
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

    const worker_rng_str = Ref("")
    const worker_rng_copy = copy(Random.default_rng())
    module UserCode
        include("main.jl")
    end

    function save_load_snapshot_dir(step, jobout, worker_rng_str, state)
        snapshot_dir = mkpath(joinpath(jobout,"snapshots","snapshot$step.zarr"))
        rm(snapshot_dir; force=true, recursive=true)
        StorageTrees.save_dir(snapshot_dir, UserCode.save_snapshot(step, state))
        worker_rng_str[] = worker_rng_2_str()
        load_snapshot(step, StorageTrees.load_dir(snapshot_dir), state)
    end

    job_header, state =  UserCode.setup($job_idx)
    step::Int = 0
    nothing
end).args...)

include("listparse.jl")
include("outputdiff.jl")

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
Comonicon.@cast function run(input_dir::AbstractString, output_dir::AbstractString, job_idx::Int;
        step_timeout::Float64=100.0,
        max_steps::Int=1_000_000,
        startup_timeout::Float64=1000.0,
        max_snapshot_MB::Float64=1E3,
    )::Int
    job_idx > 0 || throw(ArgumentError("job_idx must be greater than 0"))

    # first make the output folder
    jobout = abspath(mkpath(joinpath(output_dir,"out$job_idx")))

    # next set up logging
    info_logger = ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"info.log"), LOG_FLAGS, LOG_PERMISSIONS), Logging.Info)
    warn_logger = ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"warn.log"), LOG_FLAGS, LOG_PERMISSIONS), Logging.Warn)
    error_logger = ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"error.log"), LOG_FLAGS, LOG_PERMISSIONS), Logging.Error)
    logger = TeeLogger(
        global_logger(),
        timestamp_logger(info_logger),
        timestamp_logger(warn_logger),
        timestamp_logger(error_logger),
    )
        # now start writing to a file every second to detect multiple processes trying to run the same job
    # any process that detects this should log an error and exit.
    detect_mult_runners_f = Base.Filesystem.open(joinpath(jobout, "detect-mult-process"), LOG_FLAGS, LOG_PERMISSIONS)
    detect_mult_runners_size = Ref(filesize(detect_mult_runners_f))
    detect_mult_runners_t = Timer(0.0; interval=0.5) do t
        write(detect_mult_runners_f, 0x41)
        flush(detect_mult_runners_f)
        detect_mult_runners_size[] += 1
        if filesize(detect_mult_runners_f) != detect_mult_runners_size[]
            @error "multiple runners are running this job, exiting"
            exit(1)
        end
    end

    return_code = with_logger(logger) do


    detect_mult_runners_startup = @async sleep(1.1)
    # wait on detect_mult_runners_startup before writing to list.txt
    

    input_dir_valid = is_input_dir_valid(input_dir)
    if !input_dir_valid
        return 1
    end
    
    list_info, list_file_good_lines = try
        parse_list_file(joinpath(jobout,"list.txt"))
    catch ex
        @error "invalid list.txt syntax." exception=ex
        return 1
    end

    # check if simulation is aready done
    # note: this doesn't validate the snapshot files, or input files.
    if !isempty(list_info.final_message)
        @info "simulation already complete, exiting"
        return 0
    end

    input_tree_hash = my_tree_hash(input_dir)
    
    # start the worker
    # add processes on the same machine  with the specified input dir
    worker = addprocs(1;
        topology=:master_worker,
        exeflags="--project",
        dir=input_dir,
        env = [
            "JULIA_WORKER_TIMEOUT"=>"60.0",
            "MEDYAN_JOBOUT"=>jobout,

        ],
    )[1]

    worker_nthreads = remotecall_fetch(Threads.nthreads, worker)
    wait(detect_mult_runners_startup)

    

    # if list is empty start new job, otherwise continue the job
    local step::Int
    local worker_versioninfo::String
    if iszero(list_info.job_idx)
        @info "starting new job"
        step = 0
        # delete stuff from dir and remake it
        snapshots_dir = joinpath(jobout,"snapshots")
        rm(snapshots_dir; force=true, recursive=true)
        rm(joinpath(jobout,"list.txt"); force=true)
        rm(joinpath(jobout,"header.json"); force=true)
        list_file = Base.Filesystem.open(joinpath(jobout,"list.txt"), LOG_FLAGS, LOG_PERMISSIONS)
        mkdir(snapshots_dir)
        println_list(list_file,
            "version = 1, job_idx = $job_idx, input_tree_hash = $(bytes2hex(input_tree_hash))"
        )

        @info "starting up simulation"
        status, result = run_with_timeout(worker, startup_timeout, Expr(WORKER_STARTUP_CODE.head, WORKER_STARTUP_CODE.args..., (quote
            open(joinpath(jobout,"header.json"), "w") do io
                JSON3.pretty(io, job_header; allow_inf = true)
            end
            state = save_load_snapshot_dir(step, jobout, worker_rng_str, state)
            copy!(worker_rng_copy, Random.default_rng())
            worker_rng_str[], worker_version_info
        end).args...))
        if status != :ok
            @error "failed to startup, status: $status"
            if status === :timed_out
                println_list(list_file, "Error startup_timeout of $startup_timeout seconds reached")
            else
                @error result
                println_list(list_file, "Error starting job")
            end
            return 1
        end
        worker_versioninfo = result[2]
        header_sha256 = open(joinpath(jobout,"header.json")) do io
            sha256(io)
        end
        println_list(list_file, "header_sha256 = $(bytes2hex(header_sha256))")
        snapshot0_sha256 = my_tree_hash(joinpath(snapshots_dir,"snapshot$step.zarr"))
        println_list(list_file,
            "$(Dates.format(now(),DATE_FORMAT)), \
            $(lpad(step,STEP_PAD)), \
            $worker_nthreads, \
            $worker_versioninfo, \
            $(result[1]), \
            $(bytes2hex(snapshot0_sha256))"
        )
        @info "simulation started"
    else
        # Continue from an old job
        @info "continuing job"
        # check list_info is valid 
        if list_info.input_tree_hash != input_tree_hash
            @error "input_tree_hash was $(bytes2hex(list_info.input_tree_hash)) now is $(bytes2hex(input_tree_hash))"
            return 1
        end
        if list_info.job_idx != job_idx
            @error "job_idx was $(list_info.job_idx) now is $job_idx"
            return 1
        end
        # header isn't needed to continue the simulation, if the input hasn't changed, lets assume the header is still OK

        @info "finding last valid snapshot to load"
        snapshot_i = length(list_info.snapshot_infos)
        while snapshot_i > 0
            snapshot_info = list_info.snapshot_infos[snapshot_i]
            snapshot_dir = joinpath(jobout,"snapshots","snapshot$(snapshot_info.step_number).zarr")
            if isdir(snapshot_dir)
                snapshot_sha256 = my_tree_hash(snapshot_dir)
                if snapshot_info.snapshot_sha256 == snapshot_sha256
                    break
                end
            end
            snapshot_i -= 1
        end
        if iszero(snapshot_i)
            @error "none of the recorded snapshots are valid."
            return 1
        end
        snapshot_info = list_info.snapshot_infos[snapshot_i]
        step = snapshot_info.step_number

        @info "restarting simulation from step $step"

        # delete stuff from dir and remake it
        #rewrite list file to remove broken lines.
        list_file_str = join(list_file_good_lines[begin:end-(length(list_info.snapshot_infos)-snapshot_i)], "\n")*"\n"
        write(joinpath(jobout,"list.txt"), list_file_str)
        list_file = Base.Filesystem.open(joinpath(jobout,"list.txt"), LOG_FLAGS, LOG_PERMISSIONS)
        status, result = run_with_timeout(worker, startup_timeout, WORKER_STARTUP_CODE)
        if status != :ok
            @error "failed to restartup, status: $status"
            if status === :timed_out
                println_list(list_file, "Error startup_timeout of $startup_timeout seconds reached")
            else
                @error result
                println_list(list_file, "Error starting job")
            end
            return 1
        end
        # set globals
        remotecall_fetch(worker, step, snapshot_info.rngstate) do _step, _rngstate
            global step = _step
            copy!(Random.default_rng(), _rngstate)
            nothing
        end
        status, result = run_with_timeout(worker, startup_timeout, quote
            state = load_snapshot(step, StorageTrees.load_dir(joinpath(jobout,"snapshots","snapshot$step.zarr")), state)
            isdone::Bool, expected_final_step::Int64 = UserCode.done(step, state)
            copy!(worker_rng_copy, Random.default_rng())
            isdone, expected_final_step, worker_version_info
        end)
        if status != :ok
            @error "failed to restartup, status: $status"
            if status === :timed_out
                println_list(list_file, "Error startup_timeout of $startup_timeout seconds reached")
            else
                @error result
                println_list(list_file, "Error starting job")
            end
            return 1
        end

        @info "done restarting simulation from step $step"
        worker_versioninfo = result[3]

        if result[1]
            @info "simulation completed"
            println_list(list_file, "Done")
            return 0
        end
    end
    first_step::Bool = true
    while step < max_steps
        # On the first step use startup_timeout because the sim needs to compile.
        timeout = if first_step
            startup_timeout
        else
            step_timeout
        end
        status, result = run_with_timeout(worker, timeout, quote
            copy!(Random.default_rng(), worker_rng_copy)
            state = UserCode.loop(step, state)
            step += 1
            state = save_load_snapshot_dir(step, jobout, worker_rng_str, state)
            isdone::Bool, expected_final_step::Int64 = UserCode.done(step, state)
            copy!(worker_rng_copy, Random.default_rng())
            isdone, expected_final_step, worker_rng_str[]
        end)
        step += 1
        if status != :ok
            @error "failed to step, status: $status"
            if status === :timed_out
                if first_step
                    println_list(list_file, "Error startup_timeout of $startup_timeout seconds reached")
                else
                    @error "step_timeout of $step_timeout seconds reached"
                    println_list(list_file, "Error step_timeout of $step_timeout seconds reached")
                end
            else
                @error result
                println_list(list_file, "Error running job")
            end
            return 1
        end
        snapshot_dir = joinpath(jobout,"snapshots","snapshot$step.zarr")
        snapshot_sha256 = my_tree_hash(snapshot_dir)
        println_list(list_file,
            "$(Dates.format(now(),DATE_FORMAT)), \
            $(lpad(step,STEP_PAD)), \
            $worker_nthreads, \
            $worker_versioninfo, \
            $(result[3]), \
            $(bytes2hex(snapshot_sha256))"
        )
        @info "step $step of $(result[2]) done"

        if result[1]
            @info "simulation completed"
            println_list(list_file, "Done")
            return 0
        end
        snapshot_dir_size = sum(x->sum(y->filesize(joinpath(x[1],y)), x[3]; init=0), walkdir(snapshot_dir); init=0)
        if snapshot_dir_size > max_snapshot_MB*2^20
            @error "snapshot too large, $(snapshot_dir_size/2^20) MB"
            @error "max_snapshot_MB of $max_snapshot_MB MB reached"
            println_list(list_file, "Error max_snapshot_MB of $max_snapshot_MB MB reached")
            return 1
        end
        first_step = false
    end
    @error "max_steps of $max_steps steps reached"
    println_list(list_file, "Error max_steps of $max_steps steps reached")
    return 1
    end # logging end
    close(detect_mult_runners_t)
    return_code
end


Comonicon.@main


# @precompile_setup begin
#     # Putting some things in `setup` can reduce the size of the
#     # precompile file and potentially make loading faster.
#     test_out = mktempdir()
#     test_out2 = mktempdir()
#     input_dir = joinpath(dirname(@__DIR__),"test","examples","good","input")
#     @precompile_all_calls begin
#         # all calls in this block will be precompiled, regardless of whether
#         # they belong to your package or not (on Julia 1.8 and higher)
        
#         MEDYANSimRunner.run(input_dir, test_out, 1)
#         MEDYANSimRunner.run(input_dir, test_out, 1)
#         # cp("../test/examples/good partial/output partial", test_out2; force=true)
#         # MEDYANSimRunner.run("../test/examples/good/input/", test_out2, 1)
#     end
# end

end # module MEDYANSimRunner
