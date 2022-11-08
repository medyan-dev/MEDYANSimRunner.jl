# fibonacci sequence


using HDF5
using Random
using SHA
using OrderedCollections: OrderedDict


"""
Return the header dictionary to be written as the `header.json` file in output.
Also return the states that get passed on to `loop` and the states that get passed to `save_snapshot` and `load_snapshot`.
Also set the default random number generator seed.

`job_idx::Int`: The job index starting with job 1. This is used for multi job simulations.
"""
function setup(job_idx::Int)
    Random.seed!(job_idx)
    header = OrderedDict([
        "version" => "1.0.0",
        "model_name" => "fibonacci sequence"
    ])
    state = [0, 1]
    header, state
end

function save_snapshot(step::Int, hdf5_group, state)
    hdf5_group["states"] = state
    @info "saving states" state
end

function load_snapshot(step::Int, hdf5_group, state)
    state .= read(hdf5_group["states"])
    state
end

function done(step::Int, state)
    step > 100, 101
end

function loop(step::Int, state)
    a = sum(state) + rand(0:1)
    state[1] = state[2]
    state[2] = a
    state
end
