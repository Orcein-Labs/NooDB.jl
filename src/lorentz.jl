# NCD.jl - Lorentz Hyperbolic Geometry Module
# Implements 5D Lorentz (hyperboloid) geometry embedded in Minkowski space R^(5+1)

module Lorentz

using LinearAlgebra

export LorentzPoint, lorentz_inner, lorentz_dist, lorentz_norm_sq,
       reconstruct_x0, project_to_hyperboloid, project_highdim_to_h5,
       serialize_spatial, deserialize_spatial

"""
    LorentzPoint

A point in 5-dimensional hyperbolic space H^5 embedded in Minkowski space R^6
with signature (-1, +1, +1, +1, +1, +1).
Satisfies: -x0^2 + sum(x_sp.^2) = -1 with x0 >= 1.
"""
struct LorentzPoint
    x0::Float32
    x1::Float32
    x2::Float32
    x3::Float32
    x4::Float32
    x5::Float32

    function LorentzPoint(x0::Real, x1::Real, x2::Real, x3::Real, x4::Real, x5::Real)
        new(Float32(x0), Float32(x1), Float32(x2), Float32(x3), Float32(x4), Float32(x5))
    end
end

"""
    LorentzPoint(spatial::NTuple{5, Real})

Constructs a LorentzPoint from 5 spatial coordinates by reconstructing x0:
x0 = sqrt(1 + sum(spatial.^2))
"""
function LorentzPoint(spatial::NTuple{5, Real})
    s_sq = Float32(spatial[1]^2 + spatial[2]^2 + spatial[3]^2 + spatial[4]^2 + spatial[5]^2)
    x0 = sqrt(1.0f0 + s_sq)
    return LorentzPoint(x0, spatial[1], spatial[2], spatial[3], spatial[4], spatial[5])
end

function LorentzPoint(spatial::AbstractVector{<:Real})
    @assert length(spatial) == 5 "Spatial coordinates must have dimension 5"
    s_sq = Float32(spatial[1]^2 + spatial[2]^2 + spatial[3]^2 + spatial[4]^2 + spatial[5]^2)
    x0 = sqrt(1.0f0 + s_sq)
    return LorentzPoint(x0, spatial[1], spatial[2], spatial[3], spatial[4], spatial[5])
end

"""
    reconstruct_x0(spatial::NTuple{5, Float32})::Float32

Reconstructs x0 from 5 spatial coordinates.
"""
@inline function reconstruct_x0(spatial::NTuple{5, Float32})::Float32
    s_sq = spatial[1]^2 + spatial[2]^2 + spatial[3]^2 + spatial[4]^2 + spatial[5]^2
    return sqrt(1.0f0 + s_sq)
end

"""
    lorentz_norm_sq(p::LorentzPoint)::Float32

Computes the Minkowski quadratic form <p, p>_L = -x0^2 + sum(x_sp.^2).
For any valid point on the hyperboloid, this equals -1.0 within numerical precision.
"""
@inline function lorentz_norm_sq(p::LorentzPoint)::Float32
    return -p.x0^2 + p.x1^2 + p.x2^2 + p.x3^2 + p.x4^2 + p.x5^2
end

"""
    lorentz_inner(p::LorentzPoint, q::LorentzPoint)::Float32

Evaluates the Lorentzian inner product:
<p, q>_L = -p.x0 * q.x0 + sum(p_sp .* q_sp)
Optimized for 6-wide SIMD FMA execution.
"""
@inline function lorentz_inner(p::LorentzPoint, q::LorentzPoint)::Float32
    return -p.x0 * q.x0 + (p.x1 * q.x1 + p.x2 * q.x2 + p.x3 * q.x3 + p.x4 * q.x4 + p.x5 * q.x5)
end

"""
    lorentz_dist(p::LorentzPoint, q::LorentzPoint)::Float32

Computes the exact geodesic distance on H^5:
d_H(p, q) = arcosh(max(1.0, -<p, q>_L))
"""
@inline function lorentz_dist(p::LorentzPoint, q::LorentzPoint)::Float32
    neg_inner = -lorentz_inner(p, q)
    u = max(1.0f0, neg_inner)
    return acosh(u)
end

"""
    serialize_spatial(p::LorentzPoint)::NTuple{5, Float32}

Extracts the 5 spatial coordinates (20 bytes total).
"""
@inline function serialize_spatial(p::LorentzPoint)::NTuple{5, Float32}
    return (p.x1, p.x2, p.x3, p.x4, p.x5)
end

"""
    deserialize_spatial(coords::NTuple{5, Float32})::LorentzPoint

Reconstructs the full 6-coordinate LorentzPoint from 20-byte spatial tuple.
"""
@inline function deserialize_spatial(coords::NTuple{5, Float32})::LorentzPoint
    return LorentzPoint(coords)
end

"""
    project_to_hyperboloid(raw::AbstractVector{<:Real})::LorentzPoint

Projects an arbitrary vector in R^5 onto H^5.
"""
function project_to_hyperboloid(raw::AbstractVector{<:Real})::LorentzPoint
    @assert length(raw) >= 5 "Input vector must have at least 5 dimensions"
    return LorentzPoint(raw[1:5])
end

"""
    project_highdim_to_h5(v::AbstractVector{<:Real}; seed::Integer = 0x12345678)::LorentzPoint

Deterministic projection of a high-dimensional vector v in R^D (e.g. D=256 or 768)
into H^5 using a pseudo-random projection matrix followed by hyperboloid lifting.
"""
function project_highdim_to_h5(v::AbstractVector{<:Real}; seed::Integer = 0x12345678)::LorentzPoint
    d_in = length(v)
    if d_in == 5
        return project_to_hyperboloid(v)
    end
    
    # Deterministic linear projection down to 5 spatial dims
    out = zeros(Float32, 5)
    scale = 1.0f0 / sqrt(Float32(d_in))
    
    for i in 1:5
        acc = 0.0f0
        state = seed + UInt64(i * 10007)
        for j in 1:d_in
            # Simple fast deterministic PRNG (xorshift64)
            state ⊻= state << 13
            state ⊻= state >> 7
            state ⊻= state << 17
            val = Float32(Int32(state & 0x0000ffff) - 32768) / 32768.0f0
            acc += Float32(v[j]) * val
        end
        out[i] = acc * scale
    end
    
    return project_to_hyperboloid(out)
end

end # module Lorentz
