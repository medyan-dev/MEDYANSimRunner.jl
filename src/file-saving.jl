#=
Helper functions to try to reliably save trajectories on distributed file systems

None of these functions try to be thread safe, or prevent file system attacks.
=#


using SHA: sha256
using Random: RandomDevice


struct VersionDir
    incr_part::UInt64
    rand_part::UInt64
end

"""
Return all found versions in a directory sorted with newest last.
"""
function get_versions(dname)::Vector{VersionDir}
    used_names = filter(readdir(dname)) do subname
        local cu = codeunits(String(subname))
        length(cu) == 33 || return false
        cu[17] == UInt8('_') || return false
        valid_lower_hex = [UInt8('0'):UInt8('9'); UInt8('a'):UInt8('f');]
        all(∈(valid_lower_hex), cu[1:16]) || return false
        all(∈(valid_lower_hex), cu[18:33]) || return false
        return true
    end
    VersionDir[
        VersionDir(
            parse(UInt64, s[1:16], base=16), 
            parse(UInt64, s[18:33], base=16)
        ) for s in used_names
    ]
end

"""
Return the path to a new versioned directory in dname.
Also sets logging to the new directory.
"""
function make_new_version(dname)
    versions = get_versions(dname)
    i = if isempty(versions)
        UInt64(1)
    else
        Base.checked_add(versions[end].incr_part, UInt64(1))
    end
    # TODO should this retry if mkdir fails?
    incr_part = string(i, base=16, pad=16)
    rand_part = string(rand(RandomDevice(), UInt64), base=16, pad=16)
    new_name = incr_part*"_"*rand_part
    return mkdir(joinpath(dname, new_name))
end

"""
Write a snapshot is it doesn't already exist.
Return the name of the file written.
If a snapshot file exists it must have its SHA256 hash in its name.
The default write first truncates the file and then writes, so if julia crashes
the file will be empty, corrupting the snapshot directory.
"""
function write_hashfile(
        dname,
        step::Int,
        data::AbstractVector{UInt8},
        postfix::String,
    )::String
    basic_name_check(postfix)
    sha256_str = bytes2hex(sha256(data))
    file_name = string(step, pad=STEP_PAD)*"_"*sha256_str*postfix
    file_path = joinpath(dname, file_name)
    if ispath(file_path)
        isfile(file_path) || error("$(repr(file_path)) is corrupted")
        existing_hash = bytes2hex(open(sha256, file_path))
        if sha256_str == existing_hash
            # file exists and is correct, return
            return file_name
        else
            error("$(repr(file_path)) is corrupted")
        end
    else
        # safely create the new file.
        mktemp(dname) do temp_path, temp_out
            nb = write(temp_out, data)
            if nb != length(data)
                error("short write of $(repr(file_name)) data")
            end
            close(temp_out)
            # mv may fail if the dest exists
            # this could happen if another process creates the file
            # in the intermediate time.
            # for now just error out, because something weird is probably happening.
            try
                mv(temp_path, file_path; force=false)
            catch
                isfile(file_path) || error("$(repr(file_path)) is corrupted")
                existing_hash = bytes2hex(open(sha256, file_path))
                if sha256_str == existing_hash
                    # file exists and is correct, return
                    return file_name
                else
                    error("$(repr(file_path)) is corrupted")
                end
            end
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