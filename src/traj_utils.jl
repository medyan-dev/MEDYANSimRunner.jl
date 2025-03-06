"""
    step_path(step::Int)::String

    Return the relative path where the snapshot after `step` is in the "traj" directory.
"""
function step_path(step::Int)::String
    step ≥ 0 || error("step must be positive. Got: $(step)")
    string(fld(step, 10^SUBDIR_PAD)) * "/" * string(mod(step, 10^SUBDIR_PAD); pad=SUBDIR_PAD) * SNAP_POSTFIX
end

function is_valid_subpath(x::AbstractString)
    (
        ncodeunits(x) == ncodeunits(SNAP_POSTFIX) + SUBDIR_PAD &&
        isascii(x) &&
        all(isdigit, x[1:SUBDIR_PAD]) &&
        endswith(x, SNAP_POSTFIX)
    )
end

function is_valid_superpath(x::AbstractString)
    (
        all(isdigit, x) &&
        ncodeunits(x) ≤ 12 &&
        (x[begin] != '0' || isone(ncodeunits(x)))
    )
end

"""
    status_traj_dir(traj::String)::Union{Symbol, Int}

Return the status or latest step of the `traj` directory.
"""
function status_traj_dir(traj::String)::Union{Symbol, Int}
    dirs = readdir(traj)
    if "footer.json" ∈ dirs
        return :done
    end
    if "header.json" ∈ dirs
        for dir_name in sort(filter(is_valid_superpath, dirs); by = x -> parse(Int, x), rev=true)
            snaps = sort(filter(is_valid_subpath, readdir(joinpath(traj, dir_name))))
            isempty(snaps) && continue
            snap = snaps[end]
            step_part = snap[begin:end-ncodeunits(SNAP_POSTFIX)]
            return parse(Int, step_part) + parse(Int, dir_name)*10^SUBDIR_PAD
        end
        return -1
    else
        return -2
    end
end

function steps_traj_dir(traj::String)::Vector{Int}
    dirs = readdir(traj)
    steps = Int[]
    if "header.json" ∈ dirs
        for dir_name in sort(filter(is_valid_superpath, dirs); by = x -> parse(Int, x))
            offset = parse(Int, dir_name)*1000
            for snap in sort(filter(is_valid_subpath, readdir(joinpath(traj, dir_name))))
                step_part = snap[begin:end-ncodeunits(SNAP_POSTFIX)]
                push!(steps, parse(Int, step_part) + offset)
            end
        end
    end
    steps
end