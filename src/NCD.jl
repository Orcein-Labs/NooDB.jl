# NCD.jl - Legacy Compatibility Wrapper for NooDB.jl
# Automatically maps all NCD calls to NooDB.

module NCD

include("NooDB.jl")
using .NooDB

# Re-export everything from NooDB
for sym in names(NooDB; all=false)
    if sym !== :NooDB
        @eval export $sym
    end
end

import Base: put!, get, delete!
export put!, get, delete!, compact!, vacuum!

end # module NCD
