module MEDYANSimRunner

using LoggingExtras
using Logging

"""
Return true if the input_dir is valid.

Otherwise log errors and return false.
"""
function check_if_input_valid(input_dir::AbstractString)
    if !isdir(input_dir)
        @error "input directory $input_dir not found."
        return false
    end
    if !isfile(joinpath(input_dir,"Manifest.toml"))
        @error "Manifest.toml missing from $input_dir."
        return false
    end
    if !isfile(joinpath(input_dir,"Project.toml"))
        @error "Project.toml missing from $input_dir."
        return false
    end

    try
        isdir(input_dir)
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

    # next check if input is valid
    check_if_input_valid(input_dir) || exit()

 

end



















end # module MEDYANSimRunner
