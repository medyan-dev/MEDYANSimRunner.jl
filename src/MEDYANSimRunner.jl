module MEDYANSimRunner

using LoggingExtras
using Logging
using TOML
using Dates
using SHA
using Distributed
import Random

include("timeout.jl")



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
function str_2_rng(str::String)::Random.AbstractRNG
    parts = split(str, " ")
    parts[1] == "Xoshiro:" || error("rng type must be Xoshiro not $(parts[1])")
    state = parse.(UInt64, parts[2:end])
    Random.Xoshiro(state...)
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
Represents a snapshot in a parsed list.txt file.
"""
Base.@kwdef struct SnapshotInfoV1
    time_stamp::DateTime
    step_number::Int
    nthreads::Int
    julia_versioninfo::String
    rngstate::Random.Xoshiro
    snapshot_sha256::Vector{UInt8}
end


function parse_snapshot_info_v1(line::Vector{String})::SnapshotInfoV1
    SnapshotInfoV1(;
        time_stamp = DateTime(line[1], dateformat"yyyy-mm-dd HH:MM:SS"),
        step_number = parse(Int, line[2]),
        nthreads = parse(Int, line[3]),
        julia_versioninfo = line[4],
        rngstate = str_2_rng(line[5]),
        snapshot_sha256 = hex2bytes(lines[6]),
    )
end


"""
Represents a parsed list.txt file.
"""
Base.@kwdef struct ListFileV1
    job_idx::Int = 0
    input_git_tree_sha1::Vector{UInt8} = []
    header_sha256::Vector{UInt8} = []
    snapshots::Vector{SnapshotInfoV1} = []
    final_message::String = ""
end


"""
Parse a list file. 
Return a ListFileV1 if successful,
If the file doesn't exist or is too short, return an empty ListFileV1.
If there is some error parsing, throw an error.
"""
function parse_list_file(listpath::AbstractString)
    if !isfile(listpath)
        return ListFileV1()
    end
    @assert isfile(listpath)
    rawlines = readlines(listpath)
    # remove lines that don't have a good checksum.
    good_rawlines = Iterators.filter(rawlines) do rawline
        l = rsplit(rawline, ", "; limit=2)
        length(l) == 2 || return false
        linestr, linesha = l
        reallinesha = bytes2hex(sha256(linestr))
        reallinesha == linesha
    end
    
    # Return empty list file if too short
    if length(good_rawlines) < 2
        return ListFileV1()
    end

    lines = map(good_rawlines) do good_rawline
        split(good_rawline, ", ")[begin:end-1]
    end
    firstlineparts = split.(lines[begin], " = ")
    if firstlineparts[1] != ["version","1"]
        error("list file has bad version")
    end

    # now try and parse first line
    if firstlineparts[2][1] != "job_idx"
        error("expected \"job_idx\" got $(firstlineparts[2][1])")
    end
    job_idx = parse(Int, firstlineparts[2][2])
    if firstlineparts[3][1] != "input_git_tree_sha1"
        error("expected \"input_git_tree_sha1\" got $(firstlineparts[3][1])")
    end
    input_git_tree_sha1 = hex2bytes(firstlineparts[3][2])

    # check if last line is error or done
    maybemessage = lines[end][1]
    final_message = if startswith(maybemessage, "Error") || startswith(maybemessage, "Done")
        maybemessage
    else
        ""
    end

    # error before header file written
    if length(lines) == 2 && !isempty(final_message)
        return ListFileV1(;
            job_idx,
            input_git_tree_sha1,
            final_message,
        )
    end

    # too few snapshots, not finished
    if isempty(final_message) && length(lines) < 4
        return ListFileV1()
    end

    secondlineparts = split.(lines[begin+1], " = ")
    if secondlineparts[1][1] != "header_sha256"
        error("expected \"header_sha256\" got $(secondlineparts[1][1])")
    end

    header_sha256 = hex2bytes(secondlineparts[1][1])

    num_snapshots = length(lines) - 2 - !isempty(final_message)
    @assert num_snapshots ≥ 0
    snapshot_infos = map(1:num_snapshots) do i
        parse_snapshot_info_v1(lines[i+2])
    end
    return ListFileV1(;
        job_idx,
        input_git_tree_sha1,
        header_sha256,
        snapshot_infos,
        final_message,
    )    
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
"""
function main(input_dir::AbstractString, output_dir::AbstractString, job_idx::Int;
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
    info_logger = SimpleLogger(Base.Filesystem.open(joinpath(jobout,"info.log"), log_flags, log_perm), Logging.Info)
    warn_logger = SimpleLogger(Base.Filesystem.open(joinpath(jobout,"warn.log"), log_flags, log_perm), Logging.Warn)
    error_logger = SimpleLogger(Base.Filesystem.open(joinpath(jobout,"error.log"), log_flags, log_perm), Logging.Error)
    logger = TeeLogger(
        global_logger(),
        info_logger,
        warn_logger,
        error_logger,
    )
    global_logger(logger)

    # now start writing to a file every second to detect multiple processes trying to run the same job
    # any process that detects this should log an error and exit.
    detect_mult_runners_f = Base.Filesystem.open(joinpath(jobout, "detect-mult-process"), log_flags, log_perm)
    detect_mult_runners_size = Ref(filesize(detect_mult_process_f))
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
    
    list_info = try
        parse_list_file(joinpath(jobout,"list.txt"))
    catch ex
        @error "invalid list.txt syntax." exception=ex
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
    worker_versioninfo = remotecall_fetch(()->sprint(InteractiveUtils.versioninfo), worker)

    # list is empty start new job
    if iszero(list_info.job_idx)
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
        @gensym worker_rng_2_str
        @gensym worker_rng_str0
        @gensym worker_rng_str1
        status, result = run_with_timeout(worker, startup_timeout, quote
            using Pkg; Pkg.instantiate()
            import Dates
            import LoggingExtras
            import Logging
            import JSON3
            import HDF5
            import Random
            info_logger = Logging.SimpleLogger(Base.Filesystem.open(joinpath($jobout,"info.log"), log_flags, log_perm), Logging.Info)
            warn_logger = Logging.SimpleLogger(Base.Filesystem.open(joinpath($jobout,"warn.log"), log_flags, log_perm), Logging.Warn)
            error_logger = Logging.SimpleLogger(Base.Filesystem.open(joinpath($jobout,"error.log"), log_flags, log_perm), Logging.Error)
            logger = LoggingExtras.TeeLogger(
                global_logger(),
                info_logger,
                warn_logger,
                error_logger,
            )
            global_logger(logger)

            """
            Return a string describing the state of the rng without any newlines or commas
            """
            function $worker_rng_2_str(rng = Random.default_rng())::String
                myrng = copy(rng)
                if typeof(myrng)==Random.Xoshiro
                    "Xoshiro: $(repr(myrng.s0)) $(repr(myrng.s1)) $(repr(myrng.s2)) $(repr(myrng.s3))"
                else
                    error("rng of type $(typeof(myrng)) not supported yet")
                end
            end
            const $worker_rng_str0 = Ref("")
            const $worker_rng_str1 = Ref("")

            include("main.jl")
            job_header, state =  setup(job_idx)
            open(joinpath($jobout,"header.json"), "w") do io
                JSON3.pretty(io, job_header)
            end
            step = 0
            state = HDF5.h5open(joinpath($jobout,"snapshots","snapshot$step.h5"), "w") do job_file
                save_snapshot(step, job_file, state)
                $worker_rng_str0[] = $worker_rng_2_str()
                load_snapshot(step, job_file, state)
            end
            state = loop(step, state)
            step += 1
            state = HDF5.h5open(joinpath($jobout,"snapshots","snapshot$step.h5"), "w") do job_file
                save_snapshot(step, job_file, state)
                $worker_rng_str1[] = $worker_rng_2_str()
                load_snapshot(step, job_file, state)
            end
            isdone::Bool, expected_final_step::Int64 = done(step, state)
            isdone, expected_final_step, worker_rng_str0[], worker_rng_str1[]
        end)
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
        header_sha256 = open(joinpath(jobout,"header.json")) do io
            sha256(io)
        end
        println_list(list_file, "header_sha256 = $header_sha256")
        snapshot0_sha256 = open(joinpath(jobout,"snapshots","snapshot0.h5")) do io
            sha256(io)
        end
        println_list(list_file,
            "$(Dates.format(now(),dateformat"yyyy-mm-dd HH:MM:SS")), \
            0, \
            $worker_nthreads, \
            $worker_versioninfo, \
            $(result[3]), \
            $(bytes2hex(snapshot0_sha256))"
        )
        snapshot1_sha256 = open(joinpath(jobout,"snapshots","snapshot1.h5")) do io
            sha256(io)
        end
        println_list(list_file,
            "$(Dates.format(now(),dateformat"yyyy-mm-dd HH:MM:SS")), \
            1, \
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
        @info "Step 1 of $(results[2]) done"

        step = 1
        while step < max_steps
            status, result = run_with_timeout(worker, step_timeout, quote
                state = loop(step, state)
                step += 1
                state = HDF5.h5open(joinpath($jobout,"snapshots","snapshot$step.h5"), "w") do job_file
                    save_snapshot(step, job_file, state)
                    $worker_rng_str0[] = $worker_rng_2_str()
                    load_snapshot(step, job_file, state)
                end
                isdone::Bool, expected_final_step::Int64 = done(step, state)
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
                "$(Dates.format(now(),dateformat"yyyy-mm-dd HH:MM:SS")), \
                $step, \
                $worker_nthreads, \
                $worker_versioninfo, \
                $(result[3]), \
                $(bytes2hex(snapshot_sha256))"
            )
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

    # TODO Continue from an old job
    error("continuing a job not implemented yet")
end



















end # module MEDYANSimRunner
