# This simulation has an infinite loop.
using Random
using OrderedCollections: OrderedDict



function setup()
    Random.seed!(1234)
    a = 0.0
    for i in 1:100
        a += randn()
    end
    return OrderedDict("a"=>a)
end 