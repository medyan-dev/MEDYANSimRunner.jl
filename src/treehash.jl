# custom tree hash function


"""
Return a vector of bytes representing the hash of a directory.

This is just used as a weak kind of checksum, not for cryptographic purposes.

Any sub-directories or files with names equal to ".DS_Store" will be ignored.
Empty directories will NOT be ignored.
Any link will be ignored.
File permission and other metadata will be ignored.
"""
function my_tree_hash(path::AbstractString)::Vector{UInt8}
    if isfile(path)
        open(path) do f
            sha256(f)
        end
    elseif isdir(path)
        names = filter(readdir(path; sort=true)) do name
            namepath = joinpath(path,name)
            !islink(namepath) && name != ".DS_Store"
        end
        content_hashs = UInt8[]
        for name in names
            append!(content_hashs, my_tree_hash(joinpath(path,name)))
            append!(content_hashs, sha256(name))
        end
        sha256(content_hashs)
    else
        error("$path must be a file or directory")
    end
end
