module MEDYANSimRunner

using LoggingExtras
using Logging

"""
Return true if the input_dir is valid.

Otherwise log errors and return false.
"""
function check_if_input_valid(input_dir::AbstractString)
end

"""
Return the output directory status.

Can be one of:
1. :dne
2. :empty
3. :
"""
function check_if_ouput_status(output_dir::AbstractString, job_idx::Int)
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
