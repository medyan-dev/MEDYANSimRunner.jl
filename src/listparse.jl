"""
Represents a snapshot in a parsed list.txt file.
"""
Base.@kwdef struct SnapshotInfoV1
    time_stamp::DateTime
    step_number::Int
    nthreads::Int
    julia_versioninfo::String
    rngstate::Random.Xoshiro
    snapshot_sha256::Vector{UInt8}
end


function parse_snapshot_info_v1(line::Vector{<:AbstractString})::SnapshotInfoV1
    SnapshotInfoV1(;
        time_stamp = DateTime(line[1], DATE_FORMAT),
        step_number = parse(Int, line[2]),
        nthreads = parse(Int, line[3]),
        julia_versioninfo = line[4],
        rngstate = str_2_rng(line[5]),
        snapshot_sha256 = hex2bytes(line[6]),
    )
end


"""
Represents a parsed list.txt file.
"""
Base.@kwdef struct ListFileV1
    isempty::Bool = true
    job_idx::String = ""
    input_tree_hash::Vector{UInt8} = []
    header_sha256::Vector{UInt8} = []
    snapshot_infos::Vector{SnapshotInfoV1} = []
    final_message::String = ""
end


"""
Parse a list file. 
Return a ListFileV1, and a vector of the good lines of the file, if successful,
If the file doesn't exist or is too short, return an empty ListFileV1.
If there is some error parsing, throw an error.

if `ignore_error == true` ignore the last good line if it starts with "Error"
"""
function parse_list_file(listpath::AbstractString; ignore_error::Bool=false)
    if !isfile(listpath)
        return ListFileV1(), String[]
    end
    @assert isfile(listpath)
    rawlines = readlines(listpath)
    # remove lines that don't have a good checksum.
    good_rawlines = filter(rawlines) do rawline
        l = rsplit(rawline, ", "; limit=2)
        length(l) == 2 || return false
        linestr, linesha = l
        reallinesha = bytes2hex(sha256(linestr))
        reallinesha == linesha
    end
    if ignore_error && !isempty(good_rawlines) && startswith(good_rawlines[end], "Error")
        pop!(good_rawlines)
    end
    
    # Return empty list file if too short
    if length(good_rawlines) < 2
        return ListFileV1(), String[]
    end

    lines = map(good_rawlines) do good_rawline
        split(good_rawline, ", ")[begin:end-1]
    end
    firstlineparts = split.(lines[begin], " = ")
    if firstlineparts[1] != ["version","1"]
        @error firstlineparts[1]
        error("list file has bad version")
    end

    # now try and parse first line
    if firstlineparts[2][1] != "job_idx"
        error("expected \"job_idx\" got $(firstlineparts[2][1])")
    end
    job_idx = join(firstlineparts[2][2:end]," = ")
    if firstlineparts[3][1] != "input_tree_hash"
        error("expected \"input_tree_hash\" got $(firstlineparts[3][1])")
    end
    input_tree_hash = hex2bytes(firstlineparts[3][2])

    # check if last line is error or done
    maybemessage = lines[end][1]
    final_message = if startswith(maybemessage, "Error") || startswith(maybemessage, "Done")
        maybemessage
    else
        ""
    end

    # error before header file written
    if length(lines) == 2 && !isempty(final_message)
        return ListFileV1(;
            isempty=false,
            job_idx,
            input_tree_hash,
            final_message,
        ), good_rawlines
    end

    # too few snapshots, not finished
    if isempty(final_message) && length(lines) < 4
        return ListFileV1(), String[]
    end
    
    if length(lines[begin+1]) != 1
        error("second line should just be header_sha265")
    end
    secondlineparts = split(lines[begin+1][1], " = ")
    if secondlineparts[1] != "header_sha256"
        error("expected \"header_sha256\" got $(secondlineparts[1])")
    end

    header_sha256 = hex2bytes(secondlineparts[2])

    num_snapshots = length(lines) - 2 - !isempty(final_message)
    @assert num_snapshots ≥ 0
    snapshot_infos = map(1:num_snapshots) do i
        parse_snapshot_info_v1(lines[i+2])
    end
    return ListFileV1(;
        isempty=false,
        job_idx,
        input_tree_hash,
        header_sha256,
        snapshot_infos,
        final_message,
    ), good_rawlines
end