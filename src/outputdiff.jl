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
    snapshot1_steps = steps_traj_dir(snapshot1dir)
    snapshot2_steps = steps_traj_dir(snapshot2dir)
    for step in setdiff(snapshot1_steps, snapshot2_steps)
        println(io, jobout2, " missing step: ", step)
    end
    for step in setdiff(snapshot2_steps, snapshot1_steps)
        println(io, jobout1, " missing step: ", step)
    end
    for step in (snapshot1_steps ∩ snapshot2_steps)
        full_name1 = joinpath(snapshot1dir, step_path(step))
        full_name2 = joinpath(snapshot2dir, step_path(step))
        group1 = SmallZarrGroups.load_zip(full_name1)
        group2 = SmallZarrGroups.load_zip(full_name2)
        SmallZarrGroups.print_diff(io, group1, group2, full_name1, full_name2, "", startswith("#"))
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