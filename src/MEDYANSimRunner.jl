module MEDYANSimRunner

using LoggingExtras
using Logging
using TOML
using Dates
using SHA
import Random

const JOB_TOML_VERSION = v"0.1"

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
function input_dir_valid(input_dir::AbstractString)
    if !isdir(input_dir)
        @error "input directory $input_dir not found."
        return false
    end
    required_toml_files = [
        "Manifest.toml",
        "Project.toml",
        "Job.toml",
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

    # check Job.toml version is compatible.
    jobconfig = TOML.parsefile(joinpath(input_dir,"Job.toml"))
    if !haskey(jobconfig, "version")
        @error "Job.toml missing version"
        return false
    end
    version = try
        parse(VersionNumber,(jobconfig["version"]))
    catch e
        if e isa ArgumentError
            @error "version in Job.toml could not be parsed as a VersionNumber"
            return false
        else
            rethrow()
        end
    end
    if version.major > JOB_TOML_VERSION.major
        @error """
        Job.toml was written in Job.toml version $(version),
        Currently in Job.toml version $(JOB_TOML_VERSION). Update the runner.
        """
        return false
    elseif version != JOB_TOML_VERSION && version < v"1.0.0"
        @error """
        Job.toml was written in Job.toml version $(version),
        Currently in Job.toml version $(JOB_TOML_VERSION).
        Backwards compatibility not implemented for versions pre 1.0.
        """
        return false
    end


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
    rngstate::Xoshiro
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
Return a symbol representing the state of the `list.txt` file.

If `list.txt` is corrupted this function will try and clean it, or delete it.

`jobout`, the job output directory must exist.
The options are:
1. `:done`: the simulation is over, either in success or error.
2. `:DNE`: the `list.txt` file does not exist.
3. `:partial`: the `list.txt` file has at least one saved snapshot, but isn't done.
"""
function parse_list_file(listpath::AbstractString)
    if !isfile(listpath)
        return ListFileV1()
    end
    @assert isfile(listpath)
    rawlines = readlines(listpath)
    good_rawlines = Iterators.filter(rawlines) do rawline
        l = rsplit(rawline, ", "; limit=2)
        length(l) == 2 || return false
        linestr, linesha = l
        reallinesha = bytes2hex(sha256(linestr))
        reallinesha == linesha
    end
    
    if length(good_rawlines) < 2
        return ListFileV1()
    end

    lines = map(good_rawlines) do good_rawline
        split(good_rawline, ", ")[begin:end-1]
    end
    firstlineparts = split.(lines[begin], " = ")
    if length(firstlineparts[1]) != 2 || firstlineparts[1][1] != "version"
        return ListFileV1()
    end
    if firstlineparts[1][2] != "1"
        return ListFileV1()
    end

    # now try and parse first line

end


function main(input_dir::AbstractString, output_dir::AbstractString, job_idx::Int)
    # first make the output folder
    jobout = mkpath(joinpath(output_dir,"out$job_idx"))

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
            exit()
        end
    end
    sleep(1.1)

    is_input_dir_valid = input_dir_valid(input_dir)
    if !is_input_dir_valid
    input_git_tree_sha1 = Pkg.GitTools.tree_hash(input_dir)
    

    # next check if input is valid
    if !input_dir_valid(input_dir)
    end

 

end



















end # module MEDYANSimRunner
