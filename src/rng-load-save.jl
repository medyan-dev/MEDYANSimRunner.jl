"""
Return a string describing the state of the rng without any newlines or commas
"""
function rng_2_str(rng = Random.default_rng())::String
    myrng = copy(rng)
    T = typeof(myrng)
    if T == Random.Xoshiro
        "Xoshiro: "*join((repr(getfield(myrng, i)) for i in 1:fieldcount(T)), " ")
    else
        error("rng of type $(typeof(myrng)) not supported yet")
    end
end

"""
Decode an rng stored in a string.
"""
function str_2_rng(str::AbstractString)::Random.AbstractRNG
    parts = split(str, " ")
    parts[1] == "Xoshiro:" || error("rng type must be Xoshiro not $(parts[1])")
    state = parse.(UInt64, parts[2:end])
    Random.Xoshiro(state...)
end