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
Return a symbol representing the state of the `list.txt` file
output_dir must exist.
The options are:
1. `:`
"""
function clean_list_file(jobout::AbstractString)

end


function main(input_dir::AbstractString, output_dir::AbstractString, job_idx::Int)
    # first make the output folder
    jobout = mkpath(joinpath(output_dir,"out$job_idx"))

    # next set up logging
    info_logger = MinLevelLogger(
        FileLogger(joinpath(jobout,"info.log"); append = true, always_flush = true),
        Logging.Info,
    )
    warn_logger = MinLevelLogger(
        FileLogger(joinpath(jobout,"warn.log"); append = true, always_flush = true),
        Logging.Warn,
    )
    error_logger = MinLevelLogger(
        FileLogger(joinpath(jobout,"error.log"); append = true, always_flush = true),
        Logging.Error,
    )
    logger = TeeLogger(
        global_logger(),
        info_logger,
        warn_logger,
        error_logger,
    )
    global_logger(logger)

    is_input_dir_valid = input_dir_valid(input_dir)
    if !is_input_dir_valid
    input_git_tree_sha1 = Pkg.GitTools.tree_hash(input_dir)
    

    # next check if input is valid
    if !input_dir_valid(input_dir)
    end

 

end



















end # module MEDYANSimRunner
