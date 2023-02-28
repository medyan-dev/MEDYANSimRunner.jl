# MEDYANSimRunner.jl

[![Build Status](https://github.com/medyan-dev/MEDYANSimRunner.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/medyan-dev/MEDYANSimRunner.jl/actions/workflows/CI.yml?query=branch%3Amain)

Manage long running restartable MEDYAN.jl simulations.

Simulations run using code stored in an `input` directory and write outputs to an `output` directory.

## Installation
First install and run Julia https://julialang.org/downloads/

Then in Julia install this repo as a regular Julia package.
```julia
import Pkg

Pkg.add("https://github.com/medyan-dev/MEDYANSimRunner.jl")
```

This will add a `medyansimrunner` to `~/.julia/bin`, so add `~/.julia/bin` to your PATH.

Run:
```sh
medyansimrunner -h
```
To see the help.

## Example
Run the following in the root of this project.
```sh
cd test/examples/good
medyansimrunner run input output 1-2
```
This will run the example simulation in `test/examples/good/input` with job index `1-2` and store the output in `test/examples/good/output/out1-2`.

The `job_idx` string gets passed to the `setup` function in `main.jl`.

The job index must not contain any of the following characters:

```julia
[ ',', '\r', '\n', '\\', '/', '\0', '*', '|', ':', '<', '>', '?', '"',]
```

It also must not end in a period or dot.

Typically the job index is two strictly positive integers seperated by "-". The first is the parameter index, and the second is the replicate.

The output directory will be created if it doesn't already exist.

To run a job with a name in the third line of file `jobnames.txt` use:

```sh
medyansimrunner run input output jobnames.txt 3
```


## input kwargs

- `step-timeout`: the maximum amount of time in seconds each step is allowed to take before the job is killed, defaults to infinity.

- `max-steps`: the maximum number of steps a job is allowed to take before the job is killed.

- `startup-timeout`: the maximum amount of time in seconds to load everything and run the first loop, defaults to infinity.

- `max-snapshot-MB`: the maximum amount of hard drive space each snapshot is allowed to use in megabytes.

## `input` directory

The input directory must contain a `main.jl` file, a `Manifest.toml`, and a `Project.toml`.

The input directory will be the working directory of the simulation and can include other data needed for the simulation, including an `Artifacts.toml`

The input directory should not be mutated during or after a simulation.

### `main.jl` file

This file contains the julia functions used when running the simulation.
These functions can modify any input state variables, but in general should return the state.
These functions can also use the default random number generator, this will automatically saved and loaded.

#### Standard input parameters.
 - `step::Int`: starts out at 0 after setup and is auto incremented right after every `loop`.

#### `setup(job_idx::String; kwargs...) -> header_dict, state`
Return the header dictionary to be written as the `header.json` file in output.
Also return the state that gets passed on to `loop` and the state that gets passed to `save_snapshot` and `load_snapshot`.
Also set the default random number generator seed.

`job_idx::String`: The job index. This is used for multi job simulations.

#### `save_snapshot(step::Int, state; kwargs...)::StorageTrees.ZGroup`
Return the state of the system as a `StorageTrees.ZGroup`
This function should not mutate `state`

#### `load_snapshot(step::Int, group::StorageTrees.ZGroup, state; kwargs...) -> state`
Load the state saved by `save_snapshot`
This function can mutate `state`.
`state` may be the state returned from `setup` or the `state` returned by `loop`.
This function should return the same output if `state` is the state returned by `loop` or the 
state returned by `setup`.

#### `done(step::Int, state; kwargs...) -> done::Bool, expected_final_step::Int`
Return true if the simulation is done, or false if `loop` should be called again.

Also return the expected value of step when done will first be true, used for displaying the simulation progress.

This function should not mutate `state`

#### `loop(step::Int, state; kwargs...) -> state`
Return the state that gets passed to `save_snapshot`



### `Manifest.toml` and `Project.toml`

These contain the julia environment used when running the simulation. 
These must contain StorageTrees, JSON3, and LoggingExtras, because these are required for saving data.

### Main loop pseudo code

```
activate and instantiate the environment
include("main.jl")
create output directory if it doesn't exist
job_header, state =  setup(job_idx)
save job_header
step = 0
StorageTrees.save_dir(snapshot_zip_file, save_snapshot(step, state))
state = load_snapshot(step, StorageTrees.load_dir(snapshot_zip_file), state)
while true
    state = loop(step, state)
    step = step + 1
    StorageTrees.save_dir(snapshot_zip_file, save_snapshot(step, state))
    state = load_snapshot(step, StorageTrees.load_dir(snapshot_zip_file), state)
    if done(step::Int, state)[1]
        break
    end
end
```



## `output` directory

The output directory has an `out$job_idx` subdirectory for job `job_idx`'s output.

Each out subdirectory has the following files.

### `info.log`
Any logs, warnings, and errors generated by the simulation are saved in this file.

### `warn.log`
Any warnings, and errors generated by the simulation are saved in this file.

### `error.log`
Any errors generated by the simulation are saved in this file.

### `header.json`
A description of the system.

### `list.txt`
Data describing the saved snapshots, and if the simulation is done or errored, or needs to be continued.

The last element in each line is the sha256 of the line, not including the last comma space, and hash value.


The first line is.
```
version = 1, job_idx = 1, input_tree_hash = 5a936e..., 54bf8d69288...
```
- `version`: version of the info.txt format.
- `job_idx`: index of the job. 
- `input_tree_hash`: hash of input directory calculated with [`my_tree_hash`](src/treehash.jl)

The second line is:
```
header_sha256 = 2cf934..., 312f788...
```
- `header_sha256`: hash of header.json.
Or:
```
Error starting job, 8d69288...
```

After these lines each of the next lines correspond to a saved snapshot.

These have the format:
```
yyyy-mm-dd HH:MM:SS, step number, nthreads, julia versioninfo, rng state, snapshot sha256, line sha256
```

`snapshot sha256` is the sha256 of the snapshot zip file.

The final line explains how the simulation ended it can be one of the following:
```
Error starting job, line sha256
```

```
Error running job, line sha256
```

```
Error startup_timeout of $startup_timeout seconds reached, line sha256
```

```
Error step_timeout of $step_timeout seconds reached, line sha256
```

```
Error max_steps of $max_steps steps reached, line sha256
```

```
Error max_snapshot_MB of $max_snapshot_MB MB reached, line sha256
```

```
Done, line sha256
```

See the log files for more details and error messages.


### `snapshots` subdirectory
Contains `snapshot$i.zarr.zip` files where `i` is the step of the simulation.
The state returned by `setup` is stored in `snapshot0.zarr.zip`
