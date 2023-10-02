#=
Helper functions to try to reliably save trajectories on distributed file systemssrc/file-saving.jl

None of these functions try to be thread safe, or prevent file system attacks.
=#


using SHA: sha256
using Random: RandomDevice
import Dates
import LoggingExtras
using Logging
using ArgCheck

const DATE_FORMAT = Dates.dateformat"yyyy-mm-ddTHH:MM:SS"

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


function in_new_log_dir(f, job_out::String)
    date_part = Dates.format(Dates.today(),"yyyy-mm-dd")
    rand_part = Random.randstring(RandomDevice(), 12)
    new_name = date_part*"_"*rand_part
    all_logs = mkpath(joinpath(job_out, "logs"))
    logs = mkdir(joinpath(all_logs, "logs", new_name))
    logger = LoggingExtras.TeeLogger(
        global_logger(),
        timestamp_logger(joinpath(logs, "info.log"), Logging.Info),
        timestamp_logger(joinpath(logs, "warn.log"), Logging.Warn),
        timestamp_logger(joinpath(logs, "error.log"), Logging.Error),
    )
    with_logger(f, logger)
end



"""
Ensure a file with the contents `data` exists at the path `joinpath(dir_name, file_name)`

This function can fail or be interrupted, in that case, an existing file 
or other thing at the path
will either not be modified, or will be replaced with a file with contents of `data`.

If there is no existing file at path,
there will either be a file with contents of `data`, or no file.

If interrupted, there may be a temporary file left behind in `dir_name`.
"""
function write_traj_file(
        dir_name::String,
        file_name::String,
        data::AbstractVector{UInt8},
    )::Nothing
    basic_name_check(file_name)
    new_hash = sha256(data)
    file_path = joinpath(dir_name, file_name)
    if isfile(file_path)
        if filesize(file_path) == length(data)
            existing_hash = open(sha256, file_path)
            if new_hash == existing_hash
                # file exists and is correct, return
                return
            end
        end
    end
    # safely create the new file.
    mktemp(dir_name) do temp_path, temp_out
        nb = write(temp_out, data)
        if nb != length(data)
            error("short write of $(repr(file_name)) data")
        end
        close(temp_out)
        # mv(temp_path, file_path; force=true)
        err = ccall(:jl_fs_rename, Int32, (Cstring, Cstring), temp_path, file_path)
        # on error, check if file was made by another process, and is still valid.
        if err < 0
            if isfile(file_path)
                if filesize(file_path) == length(data)
                    existing_hash = open(sha256, file_path)
                    if new_hash == existing_hash
                        # file exists and is correct, return
                        return
                    end
                end
            end
            # otherwise error
            error("$(repr(file_path)) is corrupted")
        end
        nothing
    end
end





function basic_name_check(name::String)::Nothing
    @argcheck !isempty(name)
    @argcheck isvalid(name)
    @argcheck !contains(name, '/')
    @argcheck !contains(name, '\0')
    @argcheck !contains(name, '\\')
    @argcheck !contains(name, ':')
    @argcheck !contains(name, '"')
    @argcheck !contains(name, '*')
    @argcheck !contains(name, '<')
    @argcheck !contains(name, '>')
    @argcheck !contains(name, '?')
    @argcheck !contains(name, '|')
    @argcheck !contains(name, '\x7f')
    @argcheck all(>('\x1f'), name) # \n, \t, \e and other control chars are not allowed
    @argcheck !endswith(name, ".")
    @argcheck !endswith(name, " ")
    # TODO check for reserved DOS names maybe
    # From some testing on windows 11, the names seem "fine".
    # if they are written as absolute paths with a prefix of \\?\
end