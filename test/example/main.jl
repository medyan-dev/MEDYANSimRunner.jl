# Install dependencies with:
# julia --project=.. -e 'using Pkg; pkg"dev ../.."; pkg"instantiate";'

# Run this with:
# JULIA_LOAD_PATH="@" julia --project=.. --startup-file=no main.jl --out=output

# Continue crashed simulations this with:
# JULIA_LOAD_PATH="@" julia --project=.. --startup-file=no main.jl --out=output --continue


using SmallZarrGroups
using Random
using OrderedCollections: OrderedDict
import MEDYANSimRunner

jobs = [
    "a",
    "b",
    "c",
]

function setup(job::String; kwargs...)
    header = OrderedDict([
        "version" => "1.0.0",
        "model_name" => "fibonacci sequence"
    ])
    state = [0, 1]
    header, state
end

function save(step::Int, state; kwargs...)::ZGroup
    # @info "saving states" state
    group = ZGroup()
    group["states"] = state
    group
end

function load(step::Int, group, state; kwargs...)
    state .= collect(group["states"])
    state
end

function done(step::Int, state; kwargs...)
    step > 3000, 3001
end

function loop(step::Int, state; output::ZGroup, kwargs...)
    a = sum(state) + rand(0:1)
    state[1] = state[2]
    state[2] = a
    attrs(output)["sum"] = sum(state) + step
    state
end

if abspath(PROGRAM_FILE) == @__FILE__
    MEDYANSimRunner.run(ARGS; jobs, setup, loop, load, save, done)
end