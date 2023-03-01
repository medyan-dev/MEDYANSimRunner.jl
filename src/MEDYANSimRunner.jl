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

const THIS_PACKAGE_VERSION::String = TOML.parsefile(pkgdir(MEDYANSimRunner, "Project.toml"))["version"]

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

    const worker_version_info::String = """
        Julia Version: $VERSION \
        MEDYANSimRunner Version: $($THIS_PACKAGE_VERSION) \
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
    global jobout::String = ""
    global step::Int = 0
    global job_idx::String = ""
    module UserCode
        include("main.jl")
    end

    function save_load_snapshot_dir(step, jobout, worker_rng_str, state)
        snapshot_path = joinpath(jobout,"snapshots","snapshot$step.zarr.zip")
        StorageTrees.save_dir(snapshot_path, UserCode.save_snapshot(step, state))
        worker_rng_str[] = worker_rng_2_str()
        UserCode.load_snapshot(step, StorageTrees.load_dir(snapshot_path), state)
    end

    function setup_logging(jobout)
        LoggingExtras.TeeLogger(
            # Logging.global_logger(),
            worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"info.log"),  $LOG_FLAGS, $LOG_PERMISSIONS), Logging.Info)),
            worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"warn.log"),  $LOG_FLAGS, $LOG_PERMISSIONS), Logging.Warn)),
            worker_timestamp_logger(Logging.ConsoleLogger(Base.Filesystem.open(joinpath(jobout,"error.log"), $LOG_FLAGS, $LOG_PERMISSIONS), Logging.Error)),
        ) |> Logging.global_logger
    end
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
Return the job_idx string and job_seed, or error if invalid.
"""
function normalize_job_idx(job_idx_or_file::AbstractString, job_line::Int = -1)::Tuple{String, Vector{UInt64}}
    local unnorm_job_idx::String = if job_line == -1
        job_idx_or_file
    else
        job_line > 0 || throw(ArgumentError("job_line must be greater than 0 if used"))
        isfile(job_idx_or_file) || throw(ArgumentError("job_file: $(job_idx_or_file) missing"))
        readlines(job_idx_or_file)[job_line]
    end
    local job_idx_parts = split(replace(unnorm_job_idx, '\\'=>'/'), '/', keepempty=false)
    isempty(job_idx_parts) && throw(ArgumentError("job_idx is empty"))
    # each part of job_idx must be a valid part of a filename, on windows, linux and mac.
    # if job_idx contains references to parent directories, it could be a big issue.
    # job_idx is also stored in the csv file, so it cannot contain comma or newline.
    banned_chars = [
        ',',
        '\r',
        '\n',
        '\\',
        '/',
        '\0',
        '*',
        '|',
        ':',
        '<',
        '>',
        '?',
        '"',
    ]
    for part in job_idx_parts
        @assert !isempty(part)
        # Check that parts are valid utf8
        isvalid(part) || throw(ArgumentError("$(collect(part))"))
        if any(occursin(part), banned_chars)
            throw(ArgumentError("job_idx part: $(repr(part)) cannot contain $banned_chars"))
        end
        endswith(part, '.') && throw(ArgumentError("job_idx part: $(repr(part)) cannot end with ".""))
        startswith(part, '.') && throw(ArgumentError("job_idx part: $(repr(part)) cannot start with ".""))
    end
    job_idx = join(job_idx_parts, "/")
    job_seed = collect(reinterpret(UInt64,sha256(job_idx)))
    job_idx, job_seed
end


"""
Start or continue a simulation job.

# Args

- `input_dir`: The input directory.
- `output_dir`: The output directory.
- `job_idx_or_file`: The job index for multi-job simulations, or a filename.
- `job_line`: If specified, get the job index from this line in the `job_idx_or_file` file.

# Options

- `--step_timeout`: max amount of time a step can take in seconds.
- `--max_steps`: max number of steps.
- `--startup_timeout`: max amount of time job startup can take in seconds.
- `--max_snapshot_MB`: max amount of disk space one snapshot can take up.

# Flags

- `--force, -f`: delete existing "<output_dir>/out<job_idx>") if it exists, and restart the simulation.
- `--ignore_error, -i`: ignore previous error when restarting the simulation.

"""
Comonicon.@cast function run(
        input_dir::AbstractString,
        output_dir::AbstractString,
        job_idx_or_file::AbstractString,
        job_line::Int = -1,
        ;
        step_timeout::Float64=Inf64,
        max_steps::Int=1_000_000,
        startup_timeout::Float64=Inf64,
        max_snapshot_MB::Float64=1E3,
        force::Bool=false,
        ignore_error::Bool=false,
    )::Int
    job_idx::String, job_seed::Vector{UInt64} = normalize_job_idx(job_idx_or_file, job_line)        

    if force
        rm(joinpath(output_dir,job_idx); force=true, recursive=true)
    end

    # first make the output folder
    jobout = abspath(mkpath(joinpath(output_dir,job_idx)))

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

    # This next section is inside a do block, so detect_mult_runners_t can be closed
    # if an error occurs
    return_code = with_logger(logger) do


    detect_mult_runners_startup = @async sleep(1.1)
    # wait on detect_mult_runners_startup before writing to list.txt
    # the actual wait happens after some setup that cannot change list.txt
    

    input_dir_valid = is_input_dir_valid(input_dir)
    if !input_dir_valid
        return 1
    end
    
    list_info, list_file_good_lines = try
        parse_list_file(joinpath(jobout,"list.txt");ignore_error)
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
    )[1]

    worker_nthreads = remotecall_fetch(Threads.nthreads, worker)
    wait(detect_mult_runners_startup)


    "Log start up error and return 1"
    function startup_error(list_file, status, result)
        @error "failed to startup, status: $status"
        if status == :timed_out
            println_list(list_file, "Error startup_timeout of $startup_timeout seconds reached")
        else
            @error result
            println_list(list_file, "Error starting job")
        end
        return 1
    end
    

    # if list is empty start new job, otherwise continue the job
    local step::Int
    local worker_versioninfo::String
    if list_info.isempty
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
        status, result = run_with_timeout(worker, startup_timeout, WORKER_STARTUP_CODE)
        status == :ok || return startup_error(list_file, status, result)
        status, result = run_with_timeout(worker, startup_timeout, quote
            global step = $step
            global job_idx = $job_idx
            global jobout = $jobout
            setup_logging(jobout)
            # set seed on worker
            Random.seed!($job_seed)
            job_header, state =  UserCode.setup(job_idx)
            open(joinpath(jobout,"header.json"), "w") do io
                JSON3.pretty(io, job_header; allow_inf = true)
            end
            state = save_load_snapshot_dir(step, jobout, worker_rng_str, state)
            copy!(worker_rng_copy, Random.default_rng())
            worker_rng_str[], worker_version_info
        end)
        status == :ok || return startup_error(list_file, status, result)
        worker_versioninfo = result[2]
        header_sha256 = open(joinpath(jobout,"header.json")) do io
            sha256(io)
        end
        println_list(list_file, "header_sha256 = $(bytes2hex(header_sha256))")
        snapshot0_sha256 = my_tree_hash(joinpath(snapshots_dir,"snapshot$step.zarr.zip"))
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
            snapshot_path = joinpath(jobout,"snapshots","snapshot$(snapshot_info.step_number).zarr.zip")
            if isfile(snapshot_path)
                snapshot_sha256 = my_tree_hash(snapshot_path)
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
        status == :ok || return startup_error(list_file, status, result)
        # set globals
        worker_rng_state = (snapshot_info.rngstate.s0, snapshot_info.rngstate.s1, snapshot_info.rngstate.s2, snapshot_info.rngstate.s3)
        status, result = run_with_timeout(worker, startup_timeout, quote
            global step = $step
            global job_idx = $job_idx
            global jobout = $jobout
            setup_logging(jobout)
            Random.seed!($job_seed)
            job_header, state =  UserCode.setup(job_idx)
            copy!(Random.default_rng(), Random.Xoshiro(($worker_rng_state)...))
            state = UserCode.load_snapshot(step, StorageTrees.load_dir(joinpath(jobout,"snapshots","snapshot$step.zarr.zip")), state)
            isdone::Bool, expected_final_step::Int64 = UserCode.done(step, state)
            copy!(worker_rng_copy, Random.default_rng())
            isdone, expected_final_step, worker_version_info
        end)
        status == :ok || return startup_error(list_file, status, result)

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
            yield()
            step += 1
            state = save_load_snapshot_dir(step, jobout, worker_rng_str, state)
            isdone::Bool, expected_final_step::Int64 = UserCode.done(step, state)
            copy!(worker_rng_copy, Random.default_rng())
            GC.gc() # TODO: remove this when Julia v1.9 is released
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
        snapshot_path = joinpath(jobout,"snapshots","snapshot$step.zarr.zip")
        snapshot_sha256 = my_tree_hash(snapshot_path)
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
        snapshot_disk_size = filesize(snapshot_path)
        if snapshot_disk_size > max_snapshot_MB*2^20
            @error "snapshot too large, $(snapshot_disk_size/2^20) MB"
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
