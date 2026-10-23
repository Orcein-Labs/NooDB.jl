# NCD.jl - Clifford Rotor Algebra Module
# Implements Cl(3,0) even subalgebra (Spin(3)) for coordinate-free relational dynamics

module Clifford

using LinearAlgebra

export CliffordRotor, rotor_identity, rotor_multiply, rotor_reversion,
       rotor_sandwich, rotor_between, rotate_spatial3, apply_rotor

function apply_rotor end

"""
    CliffordRotor

A rotor in the even subalgebra Cl+(3,0) of the geometric algebra Cl(3,0).
Isomorphic to Spin(3) and unit quaternions:
R = s + b1*e23 + b2*e31 + b3*e12
where e23, e31, e12 are unit bivectors satisfying e_ij^2 = -1.
"""
struct CliffordRotor
    s::Float32   # Scalar (grade 0)
    b1::Float32  # e23 component (grade 2)
    b2::Float32  # e31 component (grade 2)
    b3::Float32  # e12 component (grade 2)

    function CliffordRotor(s::Real, b1::Real, b2::Real, b3::Real)
        mag = sqrt(Float32(s)^2 + Float32(b1)^2 + Float32(b2)^2 + Float32(b3)^2)
        if mag > 0.0f0
            inv_mag = 1.0f0 / mag
            new(Float32(s) * inv_mag, Float32(b1) * inv_mag, Float32(b2) * inv_mag, Float32(b3) * inv_mag)
        else
            new(1.0f0, 0.0f0, 0.0f0, 0.0f0)
        end
    end
end

"""
    rotor_identity()

Returns the identity rotor R = 1.
"""
@inline function rotor_identity()::CliffordRotor
    return CliffordRotor(1.0f0, 0.0f0, 0.0f0, 0.0f0)
end

"""
    rotor_reversion(r::CliffordRotor)

Returns the reversion ~R = s - b1*e23 - b2*e31 - b3*e12.
For unit rotors, ~R = R^(-1).
"""
@inline function rotor_reversion(r::CliffordRotor)::CliffordRotor
    return CliffordRotor(r.s, -r.b1, -r.b2, -r.b3)
end

"""
    rotor_multiply(p::CliffordRotor, q::CliffordRotor)

Computes the geometric product of two rotors R = P * Q.
Follows Cl+(3,0) algebra (quaternion multiplication).
"""
@inline function rotor_multiply(p::CliffordRotor, q::CliffordRotor)::CliffordRotor
    s = p.s * q.s - (p.b1 * q.b1 + p.b2 * q.b2 + p.b3 * q.b3)
    b1 = p.s * q.b1 + q.s * p.b1 + (p.b2 * q.b3 - p.b3 * q.b2)
    b2 = p.s * q.b2 + q.s * p.b2 + (p.b3 * q.b1 - p.b1 * q.b3)
    b3 = p.s * q.b3 + q.s * p.b3 + (p.b1 * q.b2 - p.b2 * q.b1)
    return CliffordRotor(s, b1, b2, b3)
end

"""
    rotor_sandwich(r::CliffordRotor, v::NTuple{3, Float32})

Applies the rotor transformation v' = R * v * ~R to a 3D vector.
Uses the optimized Rodrigues formula:
v' = v + 2*B x (B x v + s*v)
"""
function rotor_sandwich(r::CliffordRotor, v::NTuple{3, Float32})::NTuple{3, Float32}
    vx, vy, vz = v
    bx, by, bz = r.b1, r.b2, r.b3
    s = r.s
    
    # t = 2 * (B x v)
    tx = 2.0f0 * (by * vz - bz * vy)
    ty = 2.0f0 * (bz * vx - bx * vz)
    tz = 2.0f0 * (bx * vy - by * vx)
    
    # v' = v + s*t + (B x t)
    vpx = vx + s * tx + (by * tz - bz * ty)
    vpy = vy + s * ty + (bz * tx - bx * tz)
    vpz = vz + s * tz + (bx * ty - by * tx)
    
    return (vpx, vpy, vpz)
end

"""
    rotor_between(u::NTuple{3, Float32}, v::NTuple{3, Float32})::CliffordRotor

Constructs the shortest-arc rotor R that rotates unit vector u to unit vector v.
"""
function rotor_between(u::NTuple{3, Float32}, v::NTuple{3, Float32})::CliffordRotor
    # Normalize inputs
    norm_u = sqrt(u[1]^2 + u[2]^2 + u[3]^2)
    norm_v = sqrt(v[1]^2 + v[2]^2 + v[3]^2)
    if norm_u == 0.0f0 || norm_v == 0.0f0
        return rotor_identity()
    end
    ux, uy, uz = u[1]/norm_u, u[2]/norm_u, u[3]/norm_u
    vx, vy, vz = v[1]/norm_v, v[2]/norm_v, v[3]/norm_v
    
    dot_prod = ux * vx + uy * vy + uz * vz
    if dot_prod >= 0.999999f0
        return rotor_identity()
    elseif dot_prod <= -0.999999f0
        # 180 degree rotation around arbitrary orthogonal axis
        ortho_x, ortho_y, ortho_z = abs(ux) < 0.8f0 ? (1.0f0, 0.0f0, 0.0f0) : (0.0f0, 1.0f0, 0.0f0)
        # cross(u, ortho)
        cx = uy * ortho_z - uz * ortho_y
        cy = uz * ortho_x - ux * ortho_z
        cz = ux * ortho_y - uy * ortho_x
        return CliffordRotor(0.0f0, cx, cy, cz)
    end
    
    # Half-angle rotor R = (1 + v*u) / |1 + v*u|
    # Cross product gives the bivector plane of rotation
    bx = uy * vz - uz * vy
    by = uz * vx - ux * vz
    bz = ux * vy - uy * vx
    s = 1.0f0 + dot_prod
    
    return CliffordRotor(s, bx, by, bz)
end

"""
    rotate_spatial3(r::CliffordRotor, spatial::NTuple{5, Float32})::NTuple{5, Float32}

Rotates the first 3 spatial dimensions using rotor r, leaving the 4th and 5th dimensions unchanged.
Preserves the spatial norm sum(x_sp.^2).
"""
function rotate_spatial3(r::CliffordRotor, spatial::NTuple{5, Float32})::NTuple{5, Float32}
    v3 = (spatial[1], spatial[2], spatial[3])
    rv3 = rotor_sandwich(r, v3)
    return (rv3[1], rv3[2], rv3[3], spatial[4], spatial[5])
end

end # module Clifford
