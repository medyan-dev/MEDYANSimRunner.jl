# This simulation has an infinite loop.
using Random
using OrderedCollections: OrderedDict

# global a = 0.0
# while true
#     global a += randn()
# end



function setup()
    Random.seed!(1234)
    a = 0.0
    while true
        a += randn()
    end
    return OrderedDict("a"=>a)
end 