# functions to show the difference between two job outputs

import DeepDiffs
using SmallZarrGroups
import JSON3


"""
    print_json_diff(io::IO, json1::AbstractString, json2::AbstractString)

Print the difference in two json strings.
If there is no difference, nothing gets printed.
"""
function print_json_diff(io::IO, json1::AbstractString, json2::AbstractString)
    json1_pretty = sprint(io -> JSON3.pretty(io, JSON3.read(json1; allow_inf=true); allow_inf=true))
    json2_pretty = sprint(io -> JSON3.pretty(io, JSON3.read(json2; allow_inf=true); allow_inf=true))
    if json1_pretty != json2_pretty
        println(io, DeepDiffs.deepdiff(json1_pretty, json2_pretty))
    end
end


"""
Prints the difference between two job output directories.

Ignores log files.

Ignores anything in the snapshot files that has a name starting with a #

# Args

- `jobout1`: The first output directory.
- `jobout2`: The second output directory.

"""
function print_traj_diff(jobout1::AbstractString, jobout2::AbstractString)
    print_traj_diff(stdout, jobout1, jobout2)
end


function print_traj_diff(io::IO, jobout1::AbstractString, jobout2::AbstractString)
    isdir(jobout1) || throw(ArgumentError("$jobout1 path not found"))
    isdir(jobout2) || throw(ArgumentError("$jobout2 path not found"))

    # header.json
    header1 = joinpath(jobout1, "traj", "header.json")
    header2 = joinpath(jobout2, "traj", "header.json")
    if isfile(header1) & isfile(header2)
        print_json_diff(io, read(header1, String), read(header2, String))
    elseif isfile(header1) & !isfile(header2)
        println(io, header2, " file missing")
    elseif !isfile(header1) & isfile(header2)
        println(io, header1, " file missing")
    else
    end

    # snapshots sub dir
    snapshot1dir = joinpath(jobout1, "traj")
    snapshot2dir = joinpath(jobout2, "traj")
    snapshot1dir_exists = isdir(snapshot1dir) && !isempty(readdir(snapshot1dir; sort=false))
    snapshot2dir_exists = isdir(snapshot2dir) && !isempty(readdir(snapshot2dir; sort=false))
    if snapshot1dir_exists && snapshot2dir_exists
        snapshots1 = filter(startswith(SNAP_PREFIX), sort(readdir(snapshot1dir; sort=false); by=(x->(length(x),x))))
        snapshots2 = filter(startswith(SNAP_PREFIX), sort(readdir(snapshot2dir; sort=false); by=(x->(length(x),x))))
        for snapshotname in setdiff(snapshots1, snapshots2)
            println(io, joinpath(jobout2, "snapshots"), " missing: ", snapshotname)
        end
        for snapshotname in setdiff(snapshots2, snapshots1)
            println(io, joinpath(jobout1, "snapshots"), " missing: ", snapshotname)
        end
        for snapshotname in (snapshots1 ∩ snapshots2)
            full_name1 = joinpath(snapshot1dir, snapshotname)
            full_name2 = joinpath(snapshot2dir, snapshotname)
            group1 = SmallZarrGroups.load_dir(full_name1)
            group2 = SmallZarrGroups.load_dir(full_name2)
            SmallZarrGroups.print_diff(io, group1, group2, full_name1, full_name2, "", startswith("#"))
        end
    elseif snapshot1dir_exists && !snapshot2dir_exists
        println(io, snapshot2dir, " dir missing or empty")
    elseif !snapshot1dir_exists && snapshot2dir_exists
        println(io, snapshot1dir, " dir missing or empty")
    else
    end

    # header.json
    footer1 = joinpath(jobout1, "traj", "footer.json")
    footer2 = joinpath(jobout2, "traj", "footer.json")
    if isfile(footer1) & isfile(footer2)
        print_json_diff(io, read(footer1, String), read(footer2, String))
    elseif isfile(footer1) & !isfile(footer2)
        println(io, footer2, " file missing")
    elseif !isfile(footer1) & isfile(footer2)
        println(io, footer1, " file missing")
    else
    end
end