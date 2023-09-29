#=
Helper functions to try to reliably save trajectories on distributed file systemssrc/file-saving.jl

None of these functions try to be thread safe, or prevent file system attacks.
=#


using SHA: sha256
using Random: RandomDevice
import Dates
import LoggingExtras
using Logging

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


function in_new_log_dir(f, logs_parent_dir::String)
    date_part = Dates.format(Dates.today(),"yyyy-mm-dd")
    rand_part = Random.randstring(RandomDevice(), 12)
    new_name = date_part*"_"*rand_part
    logs = mkdir(joinpath(logs_parent_dir, new_name))
    logger = LoggingExtras.TeeLogger(
        global_logger(),
        timestamp_logger(joinpath(logs, "info.log"), Logging.Info),
        timestamp_logger(joinpath(logs, "warn.log"), Logging.Warn),
        timestamp_logger(joinpath(logs, "error.log"), Logging.Error),
    )
    with_logger(f, logger)
end



"""
Write a file if it doesn't already exist.
If a file exists it must have the same content as `data`.
The default write first truncates the file and then writes, so if julia crashes
the file will be empty, corrupting the traj directory.
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
        existing_hash = open(sha256, file_path)
        if new_hash == existing_hash
            # file exists and is correct, return
            return
        end
    end
    # safely create the new file.
    mktemp(dir_name) do temp_path, temp_out
        nb = write(temp_out, data)
        if nb != length(data)
            error("short write of $(repr(file_name)) data")
        end
        close(temp_out)
        err = ccall(:jl_fs_rename, Int32, (Cstring, Cstring), temp_path, file_path)
        # on error, check if file was made by another process, and is still valid.
        if err < 0
            if isfile(file_path)
                existing_hash = open(sha256, file_path)
                if new_hash == existing_hash
                    # file exists and is correct, return
                    return
                end
            end
            # otherwise error
            error("$(repr(file_path)) is corrupted")
        end
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