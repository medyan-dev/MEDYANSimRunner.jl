# MEDYANSimRunner.jl

[![Build Status](https://github.com/medyan-dev/MEDYANSimRunner.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/medyan-dev/MEDYANSimRunner.jl/actions/workflows/CI.yml?query=branch%3Amain)

Manage long running restartable MEDYAN.jl simulations.

Simulations run using julia code in a `main.jl` script and write outputs to an `output` directory.

Inspired by how build scripts work in https://github.com/JuliaPackaging/BinaryBuilder.jl

## Installation
First install and run Julia https://julialang.org/downloads/

Then in Julia install this repo as a regular Julia package.
```julia
import Pkg
Pkg.add("MEDYANSimRunner")
```

## Warning: MEDYANSimRunner may be incompatible with a future release of Julia.

Specifically `MEDYANSimRunner` uses `ccall` `:jl_fs_rename` and expects `copy(Random.default_rng())` to be `Xoshiro`. These are Julia internals.

## Example
Run the following in the root of this repo.
```sh
julia --project=test -e 'using Pkg; pkg"dev ."; pkg"instantiate";'
JULIA_LOAD_PATH="@" julia --project=test --startup-file=no test/example/main.jl --out=test/output --batch=1 --continue
```
This will run the 1st batch of the example simulation in `test/example/main.jl` 
with the `test/` environment and store the output in `test/output/`.

The output directory will be created if it doesn't already exist.

If the `"--batch=<job index>"` option is not included, all jobs specified in `main.jl` will be run.


### `main.jl` script

This file contains the julia functions used when running the simulation.
These functions can modify the input state variable, but in general should return the state.
These functions can also use the default random number generator, this will automatically saved and loaded.

At the end of `main.jl` there should be the lines:
```julia
if abspath(PROGRAM_FILE) == @__FILE__
    MEDYANSimRunner.run(ARGS; jobs, setup, loop, load, save, done)
end
```

To run the simulation if `main.jl` is called as a julia script.

#### Standard input parameters.
 - `step::Int`: starts out at 0 after setup and is auto incremented right before every `loop`.

#### `jobs::Vector{String}`
A vector of jobs to run. Each job represents one variant of the simulation that can be run.
This is useful if many simulations need to be run in parallel. The `"--batch=<job index>"` argument
can be used to pick just one job to run.

The selected `job` string gets passed to the `setup` function in `main.jl`.
The `job` string is also used to seed the default RNG right before `setup` is called.

#### `setup(job::String; kwargs...) -> header_dict, state`
Return the header dictionary to be written as the `header.json` file in output trajectory.
Also return the state that gets passed on to `loop` and the state that gets passed to `save` and `load`.

`job::String`: The job. This is used for multi job simulations.

#### `save(step::Int, state; kwargs...)-> group::SmallZarrGroups.ZGroup`
Return the state of the system as a `SmallZarrGroups.ZGroup`
This function should not mutate `state`
When saving the snapshot, this group will get saved as `"snap"`

#### `load(step::Int, group::SmallZarrGroups.ZGroup, state; kwargs...) -> state`
Load the state saved by `save`
This function can mutate `state`.
`state` may be the state returned from `setup` or the `state` returned by `loop`.
This function should return the same output if `state` is the state returned by `loop` or the 
state returned by `setup`.

#### `done(step::Int, state; kwargs...) -> done::Bool, expected_final_step::Int`
Return true if the simulation is done, or false if `loop` should be called again.

Also return the expected value of step when done will first be true, used for displaying the simulation progress.

This function should not mutate `state`

#### `loop(step::Int, state; output::SmallZarrGroups.ZGroup, kwargs...) -> state`
Return the state that gets passed to `save` and `load`

Optionally, mutate the `output` keyword argument.
When saving the snapshot, this group will get saved as `"out"`


### Main loop pseudo code

```
activate and instantiate the environment
include("main.jl")
create output directory based on job if it doesn't exist
Random.seed!(collect(reinterpret(UInt64, sha256(job))))
job_header, state =  setup(job)
save job_header
step = 0
group = ZGroup(childern=Dict("snap" => save(step, state))
SmallZarrGroups.save_zip(snapshot_zip_file, group)
state = load(step, SmallZarrGroups.load_zip(snapshot_zip_file)["snap"], state)
while true
    step = step + 1
    output = ZGroup()
    state = loop(step, state; output)
    group = ZGroup(childern=Dict("snap"=>save(step, state), "out"=>output)
    SmallZarrGroups.save_zip(snapshot_zip_file, group)
    state = load(step, SmallZarrGroups.load_zip(snapshot_zip_file)["snap"], state)
    if done(step::Int, state)[1]
        break
    end
end
```



## `output` directory

The output directory has a subdirectory for each job's output. 
The job string is the name of the subdirectory.

Each job's output subdirectory has the following files.

### `logs/<timestamp_randomstring>/{info|warn|error}.log`
Any logs, warnings, and errors generated by the simulation are saved in these files.

### `traj/header.json`
A description of the system.

### `traj/<i÷1000>/<i%1000 zero padded to 3 digits>.zip`
Contains the snapshot at the end of the i'th step of the simulation.
The state returned by `setup` is stored in `0/000.zip`
The user data is stored in the `"snap"` and `"out"` sub groups. The root group contains
some metadata used by `MEDYANSimRunner`.

### `traj/footer.json`
This is created to show a trajectory is complete.
It contains some metadata about the trajectory.
