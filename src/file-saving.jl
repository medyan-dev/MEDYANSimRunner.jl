#=
Helper functions to try to reliably save trajectories on unreliable file systems

None of these functions try to be thread safe, or prevent file system attacks.

readdir(::Path) -> Vector{String}
joinpath(::Path, ::String) -> ::Path
mkdir(::Path) -> ::Path
=#

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
    incr_part = string(i, base=16, pad=16)
    rand_part = string(rand(RandomDevice(), UInt64), base=16, pad=16)
    new_name = incr_part*"_"*rand_part
    return mkdir(joinpath(dname, new_name))
end