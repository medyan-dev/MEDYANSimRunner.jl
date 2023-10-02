# fibonacci sequence


using SmallZarrGroups
using Random
using OrderedCollections: OrderedDict
import MEDYANSimRunner

jobs = [
    "1",
    "2",
    "3",
]

function setup(job::String; kwargs...)
    header = OrderedDict([
        "version" => "1.0.0",
        "model_name" => "fibonacci sequence"
    ])
    state = [0, 1]
    header, state
end

function save_snapshot(step::Int, state; kwargs...)::ZGroup
    @info "saving states" state
    group = ZGroup()
    group["states"] = state
    group
end

function load_snapshot(step::Int, group, state; kwargs...)
    state .= collect(group["states"])
    state
end

function done(step::Int, state; kwargs...)
    step > 10, 11
end

function loop(step::Int, state; kwargs...)
    a = sum(state) + rand(0:1)
    state[1] = state[2]
    state[2] = a
    state
end

if abspath(PROGRAM_FILE) == @__FILE__
    MEDYANSimRunner.run_sim(ARGS;jobs, setup, loop, load_snapshot, save_snapshot, done)
end