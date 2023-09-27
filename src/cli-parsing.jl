@kwdef struct CLIOptions
    continue_sim::Bool
    batch::Int
    out_dir::String
end

Base.:(==)(a::CLIOptions, b::CLIOptions) = all((isequal(getfield(a,k), getfield(b,k)) for k in 1:fieldcount(typeof(a))))



function parse_cli_args(cli_args, jobs::Vector{String})::Union{CLIOptions, Nothing}
    if any(startswith("--h"), cli_args) || any(startswith("-h"), cli_args)
        @info "TODO print help message"
        return
    end

    continue_sim = parse_flag!(cli_args, "--continue")

    out_dir = something(parse_option!(cli_args, "--out"), ".")

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