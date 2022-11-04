module MEDYANSimRunner

using LoggingExtras
using Logging
using TOML

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
        ex = TOML.tryparsefile(required_toml_file)
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
Return a symbol representing the state of the `list.txt` file.

If `list.txt` is corrupted this function will try and clean it, or delete it.

`jobout`, the job output directory must exist.
The options are:
1. `:done`: the simulation is over, either in success or error.
2. `:DNE`: the `list.txt` file does not exist.
3. `:partial`: the `list.txt` file has at least one saved snapshot, but isn't done.
"""
function clean_list_file(jobout::AbstractString)
    listpath = joinpath(jobout, "list.txt")
    if !isfile(listpath)
        return :DNE
    end
    @assert isfile(listpath)
    splitlines = map(readlines(listpath)) do line
        split(line, ", ")
    end
    if length(splitlines) < 2
        # list too short, delete and restart.
        rm(listpath)
        return :DNE
    end

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

    is_input_dir_valid = input_dir_valid(input_dir)
    if !is_input_dir_valid
    input_git_tree_sha1 = Pkg.GitTools.tree_hash(input_dir)
    

    # next check if input is valid
    if !input_dir_valid(input_dir)
    end

 

end



















end # module MEDYANSimRunner
