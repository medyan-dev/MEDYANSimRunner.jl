@kwdef struct CLIOptions
    continue_sim::Bool
    batch_range::StepRange{Int, Int}
    out_dir::String
end

Base.:(==)(a::CLIOptions, b::CLIOptions) = all((isequal(getfield(a,k), getfield(b,k)) for k in 1:fieldcount(typeof(a))))

const CLI_HELP = (
    """
    Usage: julia main.jl --out=output_dir --batch=1 --continue

    Options:

        --out=<dir>         Save the trajectories and logs to this directory.
                            This directory will be created if it does not exist.
                            Defaults to the current working directory.

        --batch=<job index range> Job index or range of indexes to run.
                            By default, ":" to run all jobs.

        --continue          Try to continue from existing trajectories
                            in the output.
                            By default existing trajectories will be deleted
                            and the jobs will start from scratch.

        --help              Print out this message.
    """
)

function parse_cli_args(cli_args, jobs::Vector{String})::Union{CLIOptions, Nothing}
    if any(startswith("--h"), cli_args) || any(startswith("-h"), cli_args)
        println(CLI_HELP)
        return
    end

    continue_sim = parse_flag!(cli_args, "--continue")

    out_dir = something(parse_option!(cli_args, "--out"), ".")

    batch_str = something(parse_option!(cli_args, "--batch"), ":")
    function batch_error()
        @error "--batch must be an integer or a range, instead got $(repr(batch_str))"
        nothing
    end
    function tryparse_batchpart(part)
        if part == "end"
            length(jobs)
        elseif part == "begin"
            1
        else
            tryparse(Int, part)
        end
    end
    # Backwards compat
    if batch_str == "-1"
        batch_str = ":"
    end
    batch_parts = strip.(split(batch_str, ":"))
    batchns = tryparse_batchpart.(batch_parts)
    batch_range = if length(batch_parts) == 1
        if isnothing(only(batchns))
            return batch_error()
        end
        batchns[1]:length(jobs):length(jobs)
    elseif length(batch_parts) == 2
        if all(isempty, batch_parts)
            # plain :
            1:1:length(jobs)
        elseif any(isnothing, batchns)
            return batch_error()
        else
            batchns[1]:1:batchns[2]
        end
    elseif length(batch_parts) == 3
        if any(isnothing, batchns)
            return batch_error()
        else
            batchns[1]:batchns[2]:batchns[3]
        end
    else
        return batch_error()
    end::StepRange{Int, Int}
    if !issubset(batch_range, 1:length(jobs))
        @error "--batch must be a subset of $(1:length(jobs)), instead got $(batch_range)"
        return
    end

    unused_args = cli_args
    if !isempty(cli_args)
        @warn "not all ARGS used" unused_args
    end

    return CLIOptions(;
        continue_sim,
        batch_range,
        out_dir,
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