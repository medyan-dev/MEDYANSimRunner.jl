# fibonacci sequence


using StorageTrees
using Random
using SHA
using OrderedCollections: OrderedDict


"""
Return the header dictionary to be written as the `header.json` file in output.
Also return the states that get passed on to `loop` and the states that get passed to `save_snapshot` and `load_snapshot`.
Also set the default random number generator seed.

`job_idx::String`: The job index. This is used for multi job simulations.
"""
function setup(job_idx::String; kwargs...)
    header = OrderedDict([
        "version" => "1.0.0",
        "model_name" => "fibonacci sequence"
    ])
    state = [0, 1]
    header, state
end

function save_snapshot(step::Int, state)::ZGroup
    @info "saving states" state
    group = ZGroup()
    group["states"] = state
    group
end

function load_snapshot(step::Int, group, state)
    state .= collect(group["states"])
    state
end

function done(step::Int, state)
    step > 10, 11
end

function loop(step::Int, state)
    a = sum(state) + rand(0:1)
    state[1] = state[2]
    state[2] = a
    state
end
