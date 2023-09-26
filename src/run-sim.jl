import InteractiveUtils
using LoggingExtras
using Logging
using Dates
using SHA
using ArgCheck
import Random

const THIS_PACKAGE_VERSION::String = string(pkgversion(@__MODULE__))

const DATE_FORMAT = dateformat"yyyy-mm-dd HH:MM:SS"

# amount to pad step count by with lpad
const STEP_PAD = 7




"""
    run_sim(ARGS; setup, loop, loadsnapshot, savesnapshot, done)

This function should be called at the end of a script to run a simulation.
It takes keyword arguments:

 - `jobs::AbstractVector{String}`
is a list of jobs. Each job is a string. 
The string should be a valid directory name because 
it will be used as the name of a subdirectory in the output directory.

 - `setup(job::String; kwargs...) -> header_dict, state`
is called once at the beginning of the simulation.

 - `loop(step::Int, state; kwargs...) -> state`
is called once per step of the simulation.

- `save_snapshot(step::Int, state; kwargs...) -> group::SmallZarrGroups.ZGroup`
is called to save a snapshot.

 - `load_snapshot(step::Int, group::SmallZarrGroups.ZGroup, state; kwargs...) -> state`
is called to load a snapshot.

 - `done(step::Int, state; kwargs...) -> done::Bool, expected_final_step::Int`
is called to check if the simulation is done.

`ARGS` is the command line arguments passed to the script.
This should be a list of strings.
It can include the following optional arguments:

 - `--out=<output directory>` defaults to cwd, where to save the output.
This directory will be created if it does not exist.

 - `--batch=<batch number>` defaults to "-1" which means run all jobs.
If a batch number is given, only run the jobs with that batch number.

 - `--continue` defaults to restart jobs. 
If set, try to continue jobs that were previously interrupted.
"""
function run_sim(cli_args;
        jobs::Vector{String},
        setup,
        loop,
        save_snapshot,
        load_snapshot,
        done,
        kwargs...
    )
    @argcheck !isempty(jobs)
    options = parse_cli_args(cli_args, jobs)
    if isnothing(options)
        return
    elseif options.batch == -1
        # TODO run all jobs in parallel
    else
        run_batch()
    end


end

@kwdef struct CLIOptions
    continue_sim::Bool
    batch::Int
    outdir::String
end

Base.:(==)(a::CLIOptions, b::CLIOptions) = all((isequal(getfield(a,k), getfield(b,k)) for k in 1:fieldcount(typeof(a))))



function parse_cli_args(cli_args, jobs::Vector{String})::Union{CLIOptions, Nothing}
    if any(startswith("--h"), cli_args) || any(startswith("-h"), cli_args)
        @info "TODO print help message"
        return
    end

    continue_sim = parse_flag!(cli_args, "--continue")

    outdir = something(parse_option!(cli_args, "--out"), ".")

    batch_str = something(parse_option!(cli_args, "--batch"), "-1")
    batch = tryparse(Int, batch_str)
    batch_range = 1:length(jobs)
    if isnothing(batch)
        @error "--batch must be a integer, instead got $(repr(batch_str))"
        return
    end
    if !(batch == -1 || batch ∈ batch_range)
        @error "--batch must be -1 or in $(batch_range), instead got $(batch)"
        return
    end

    unused_args = cli_args
    if !isempty(cli_args)
        @warn "not all ARGS used" unused_args
    end

    return CLIOptions(;
        continue_sim,
        batch,
        outdir,
    )
end

function parse_flag!(args, flag)::Bool
    r = flag ∈ args
    filter!(!=(flag), args)
    r
end

function parse_option!(args, option)::Union{Nothing, String}
    i = findlast(startswith(option*"="), args)
    isnothing(i) && return
    v = split(args[something(i)], '='; limit=2)[2]
    filter!(!startswith(option*"="), args)
    String(v)
end