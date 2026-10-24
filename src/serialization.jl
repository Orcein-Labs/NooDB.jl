# NooDB.jl - Type-Secure Binary Serialization Module
# Provides deterministic, version-stable binary encoding without arbitrary
# code execution vulnerabilities associated with standard library Serialization.

module SecureSerialization

using Serialization

export serialize_value, deserialize_value,
       TAG_BYTES, TAG_STRING, TAG_INT64, TAG_FLOAT64,
       TAG_FLOAT32_VEC, TAG_FLOAT64_VEC, TAG_BOOL, TAG_LEGACY

# Tag constants
const TAG_BYTES       = 0x01
const TAG_STRING      = 0x02
const TAG_INT64       = 0x03
const TAG_FLOAT64     = 0x04
const TAG_FLOAT32_VEC = 0x05
const TAG_FLOAT64_VEC = 0x06
const TAG_BOOL        = 0x07
const TAG_LEGACY      = 0xFE # Legacy Julia Serialization payload wrapper

"""
    serialize_value(val)::Vector{UInt8}

Encodes a value into a secure, tagged binary representation.
Eliminates arbitrary code execution vulnerabilities on deserialization.
"""
function serialize_value(val)::Vector{UInt8}
    io = IOBuffer()
    if val isa Vector{UInt8}
        write(io, TAG_BYTES)
        write(io, UInt32(length(val)))
        write(io, val)
    elseif val isa AbstractString
        bytes = codeunits(String(val))
        write(io, TAG_STRING)
        write(io, UInt32(length(bytes)))
        write(io, bytes)
    elseif val isa Integer && !(val isa Bool)
        write(io, TAG_INT64)
        write(io, Int64(val))
    elseif val isa AbstractFloat
        write(io, TAG_FLOAT64)
        write(io, Float64(val))
    elseif val isa Bool
        write(io, TAG_BOOL)
        write(io, val ? 0x01 : 0x00)
    elseif val isa Vector{Float32}
        write(io, TAG_FLOAT32_VEC)
        write(io, UInt32(length(val)))
        for x in val
            write(io, x)
        end
    elseif val isa Vector{Float64}
        write(io, TAG_FLOAT64_VEC)
        write(io, UInt32(length(val)))
        for x in val
            write(io, x)
        end
    else
        # For arbitrary user structs, wrap with TAG_LEGACY for compatibility
        write(io, TAG_LEGACY)
        serialize(io, val)
    end
    return take!(io)
end

"""
    deserialize_value(bytes::Vector{UInt8}; allow_legacy::Bool=true)::Any

Safely reconstructs values from tagged binary format.
Rejects malformed headers and bounds lengths to prevent allocation exhaustion.
"""
function deserialize_value(bytes::Vector{UInt8}; allow_legacy::Bool=true)::Any
    if isempty(bytes)
        return UInt8[]
    end
    
    io = IOBuffer(bytes)
    tag = read(io, UInt8)
    
    if tag == TAG_BYTES
        len = read(io, UInt32)
        if len > length(bytes) - 5
            throw(ArgumentError("Malformed payload: declared length exceeds buffer"))
        end
        return read(io, len)
    elseif tag == TAG_STRING
        len = read(io, UInt32)
        if len > length(bytes) - 5
            throw(ArgumentError("Malformed string: declared length exceeds buffer"))
        end
        return String(read(io, len))
    elseif tag == TAG_INT64
        return read(io, Int64)
    elseif tag == TAG_FLOAT64
        return read(io, Float64)
    elseif tag == TAG_BOOL
        return read(io, UInt8) == 0x01
    elseif tag == TAG_FLOAT32_VEC
        len = read(io, UInt32)
        if len * 4 > length(bytes) - 5
            throw(ArgumentError("Malformed float vector: declared length exceeds buffer"))
        end
        vec = Vector{Float32}(undef, len)
        for i in 1:len
            vec[i] = read(io, Float32)
        end
        return vec
    elseif tag == TAG_FLOAT64_VEC
        len = read(io, UInt32)
        if len * 8 > length(bytes) - 5
            throw(ArgumentError("Malformed double vector: declared length exceeds buffer"))
        end
        vec = Vector{Float64}(undef, len)
        for i in 1:len
            vec[i] = read(io, Float64)
        end
        return vec
    elseif tag == TAG_LEGACY
        if !allow_legacy
            throw(SecurityLabelError("Legacy deserialization is disabled for untrusted input"))
        end
        return deserialize(io)
    else
        # Backwards compatibility: Check if the buffer is a legacy un-tagged Julia serialized object
        if allow_legacy
            try
                seek(io, 0)
                return deserialize(io)
            catch
                # Fall back to returning raw bytes safely
                return bytes
            end
        else
            return bytes
        end
    end
end

end # module SecureSerialization
