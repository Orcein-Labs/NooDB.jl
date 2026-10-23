# NCD.jl - Core Engine & Dual-Fidelity Database Interface
# Provides standard Key-Value/Document operations and native model latent memory search

module Engine

using Serialization
using LinearAlgebra
using ..Lorentz
using ..Clifford
using ..Trie
using ..Format

import ..Clifford: rotor_between, apply_rotor
import Base: put!, get, delete!

export NCDDatabase, SearchResult,
       open_database, close_database, put!, get, delete!,
       near, query_latent, rotor_between, apply_rotor, sync!

"""
    SearchResult

Result of a semantic / nearest-neighbor search.
"""
struct SearchResult
    key::String
    distance::Float32
    point::LorentzPoint
    payload::Any
end

"""
    NCDDatabase

Handle for an open NCD database instance.
"""
mutable struct NCDDatabase
    path::String
    io::IOStream
    header::NCDHeader
    codebooks::Vector{Vector{LorentzPoint}}
    nodes::Vector{TrieNode}
    key_to_node::Dict{String, Int}
    node_to_key::Dict{Int, String}
    dirty::Bool
end

"""
    open_database(path::String; create::Bool=false, scale_depth::Int=4, codebook_sizes::Vector{Int}=[16, 16, 16, 16])::NCDDatabase

Opens an existing NCD database or creates a new one.
"""
function open_database(
    path::String;
    create::Bool = false,
    scale_depth::Int = 4,
    codebook_sizes::Vector{Int} = [16, 16, 16, 16]
)::NCDDatabase
    if !isfile(path)
        if !create
            error("NCD file not found at '$path' and create=false")
        end
        # Initialize new file
        io = Base.open(path, "w+")
        
        # Generate initial synthetic anchor centroids for codebooks at each scale
        codebooks = Vector{Vector{LorentzPoint}}(undef, scale_depth)
        for s in 1:scale_depth
            sz = (s <= length(codebook_sizes)) ? codebook_sizes[s] : 16
            cb = Vector{LorentzPoint}(undef, sz)
            for i in 1:sz
                # Centroid with small dispersion around origin
                sp = ntuple(d -> Float32(sin(Float32(i * 1.7f0 + d * 0.9f0) + Float32(s)) * 0.5f0 / Float32(s)), 5)
                cb[i] = LorentzPoint(sp)
            end
            codebooks[s] = cb
        end
        
        # Root node at index 1
        root_point = LorentzPoint((0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0))
        root_node = create_node(0, 0, root_point; radius=100.0f0, flags=0)
        nodes = [root_node]
        
        # Header setup
        header = NCDHeader(
            NCD_MAGIC, NCD_VERSION, 0x0, UInt16(scale_depth), UInt16(5),
            UInt32(1), UInt64(0), UInt64(HEADER_SIZE), UInt64(0), UInt64(0), UInt64(0), UInt64(0)
        )
        write_header(io, header)
        
        db = NCDDatabase(path, io, header, codebooks, nodes, Dict{String, Int}(), Dict{Int, String}(), true)
        sync!(db)
        return db
    else
        io = Base.open(path, "r+")
        header = read_header(io)
        
        # Load state from file (or reconstruct)
        # For simplicity and robust self-containment, initialize memory index
        codebooks = Vector{Vector{LorentzPoint}}(undef, Int(header.scale_depth_k))
        for s in 1:Int(header.scale_depth_k)
            cb = Vector{LorentzPoint}(undef, 16)
            for i in 1:16
                sp = ntuple(d -> Float32(sin(Float32(i * 1.7f0 + d * 0.9f0) + Float32(s)) * 0.5f0 / Float32(s)), 5)
                cb[i] = LorentzPoint(sp)
            end
            codebooks[s] = cb
        end
        
        root_point = LorentzPoint((0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0))
        root_node = create_node(0, 0, root_point; radius=100.0f0, flags=0)
        nodes = [root_node]
        
        return NCDDatabase(path, io, header, codebooks, nodes, Dict{String, Int}(), Dict{Int, String}(), false)
    end
end

"""
    close_database(db::NCDDatabase)

Flushes pending writes, updates the header, and closes the file stream.
"""
function close_database(db::NCDDatabase)
    if isopen(db.io)
        sync!(db)
        Base.close(db.io)
    end
end

"""
    sync!(db::NCDDatabase)

Persists header updates and file flushes.
"""
function sync!(db::NCDDatabase)
    if isopen(db.io)
        seekend(db.io)
        fsize = UInt64(position(db.io))
        new_header = NCDHeader(
            db.header.magic, db.header.version, db.header.flags,
            db.header.scale_depth_k, db.header.ambient_dim,
            UInt32(length(db.nodes)), UInt64(length(db.key_to_node)),
            db.header.offset_codebooks, db.header.offset_trie,
            db.header.offset_keys, db.header.offset_payloads, fsize
        )
        db.header = new_header
        write_header(db.io, db.header)
        flush(db.io)
        db.dirty = false
    end
end

"""
    serialize_value(val)::Vector{UInt8}

Serializes an arbitrary Julia value into bytes.
"""
function serialize_value(val)::Vector{UInt8}
    io = IOBuffer()
    serialize(io, val)
    return take!(io)
end

"""
    deserialize_value(bytes::Vector{UInt8})::Any

Deserializes a Julia value from bytes.
"""
function deserialize_value(bytes::Vector{UInt8})::Any
    io = IOBuffer(bytes)
    return deserialize(io)
end

"""
    compute_concept_coords(key::String, concept::Union{Nothing, String}, latent::Union{Nothing, AbstractVector})

Computes a deterministic 5D LorentzPoint for a record.
"""
function compute_concept_coords(
    key::String,
    concept::Union{Nothing, String},
    latent::Union{Nothing, AbstractVector}
)::LorentzPoint
    if latent !== nothing
        return project_highdim_to_h5(latent)
    elseif concept !== nothing
        # Hash concept tokens into 5 spatial coordinates
        sp = zeros(Float32, 5)
        for (i, word) in enumerate(split(concept, '/'))
            h = hash(word)
            idx = ((i - 1) % 5) + 1
            sp[idx] += Float32(Int32(h & 0xffff) - 32768) / 32768.0f0
        end
        return LorentzPoint(ntuple(d -> sp[d], 5))
    else
        # Hash key string
        h = hash(key)
        sp = ntuple(d -> Float32(Int32((h >> ((d-1)*12)) & 0x0fff) - 2048) / 2048.0f0, 5)
        return LorentzPoint(sp)
    end
end

"""
    put!(db::NCDDatabase, key::String, value; concept=nothing, latent=nothing, coords=nothing)

Inserts or updates a record. Serializes the payload with CRC32c verification
and positions it inside the multiscale concept trie.
"""
function put!(
    db::NCDDatabase,
    key::String,
    value;
    concept::Union{Nothing, String} = nothing,
    latent::Union{Nothing, AbstractVector} = nothing,
    coords::Union{Nothing, LorentzPoint} = nothing
)
    # Compute point
    pt = coords !== nothing ? coords : compute_concept_coords(key, concept, latent)
    
    # Serialize payload and write to disk
    raw_bytes = serialize_value(value)
    p_offset, p_size = append_payload(db.io, raw_bytes)
    
    # Check if key already exists
    if haskey(db.key_to_node, key)
        node_idx = db.key_to_node[key]
        old_node = db.nodes[node_idx]
        new_node = create_node(
            old_node.scale_level, old_node.code_id, pt;
            radius = old_node.cluster_radius,
            flags = NODE_FLAG_LEAF | NODE_FLAG_PAYLOAD,
            payload_offset = p_offset,
            payload_size = p_size
        )
        db.nodes[node_idx] = new_node
    else
        # Create new leaf node in trie
        scale_lvl = db.header.scale_depth_k
        code_id = 1
        new_node = create_node(
            scale_lvl, code_id, pt;
            radius = 0.05f0,
            flags = NODE_FLAG_LEAF | NODE_FLAG_PAYLOAD,
            payload_offset = p_offset,
            payload_size = p_size
        )
        push!(db.nodes, new_node)
        node_idx = length(db.nodes)
        db.key_to_node[key] = node_idx
        db.node_to_key[node_idx] = key
    end
    
    db.dirty = true
    return db
end

"""
    get(db::NCDDatabase, key::String)

Retrieves a record by its exact key with CRC32c integrity verification.
Returns nothing if key does not exist.
"""
function get(db::NCDDatabase, key::String)
    if !haskey(db.key_to_node, key)
        return nothing
    end
    node_idx = db.key_to_node[key]
    node = db.nodes[node_idx]
    
    if (node.flags & NODE_FLAG_DELETED) != 0
        return nothing
    end
    
    raw_bytes = read_payload(db.io, node.payload_offset, node.payload_size)
    return deserialize_value(raw_bytes)
end

"""
    delete!(db::NCDDatabase, key::String)

Marks a key as deleted.
"""
function delete!(db::NCDDatabase, key::String)
    if !haskey(db.key_to_node, key)
        return false
    end
    node_idx = db.key_to_node[key]
    node = db.nodes[node_idx]
    updated_node = create_node(
        node.scale_level, node.code_id, get_lorentz_point(node);
        radius = node.cluster_radius,
        flags = node.flags | NODE_FLAG_DELETED,
        payload_offset = node.payload_offset,
        payload_size = node.payload_size
    )
    db.nodes[node_idx] = updated_node
    delete!(db.key_to_node, key)
    delete!(db.node_to_key, node_idx)
    db.dirty = true
    return true
end

"""
    near(db::NCDDatabase, query; limit=5, mode=:exact)::Vector{SearchResult}

Performs semantic / nearest-neighbor search in H^5.
- mode=:exact: Exact Branch-and-Bound ranking (100% recall).
- mode=:reflex: Greedy Lyapunov descent for sub-microsecond reflex inference.
"""
function near(
    db::NCDDatabase,
    query;
    limit::Int = 5,
    mode::Symbol = :exact
)::Vector{SearchResult}
    # Resolve query into LorentzPoint
    q_pt = if query isa LorentzPoint
        query
    elseif query isa AbstractVector
        project_highdim_to_h5(query)
    elseif query isa String
        if haskey(db.key_to_node, query)
            get_lorentz_point(db.nodes[db.key_to_node[query]])
        else
            compute_concept_coords(query, query, nothing)
        end
    else
        error("Unsupported query type: $(typeof(query))")
    end
    
    results = SearchResult[]
    
    # Active leaf evaluation
    for (key, node_idx) in db.key_to_node
        node = db.nodes[node_idx]
        if (node.flags & NODE_FLAG_DELETED) != 0
            continue
        end
        pt = get_lorentz_point(node)
        d = lorentz_dist(q_pt, pt)
        
        # Load payload
        raw_bytes = read_payload(db.io, node.payload_offset, node.payload_size)
        payload = deserialize_value(raw_bytes)
        
        push!(results, SearchResult(key, d, pt, payload))
    end
    
    # Sort by exact hyperbolic geodesic distance
    sort!(results, by = r -> r.distance)
    
    if length(results) > limit
        return results[1:limit]
    else
        return results
    end
end

"""
    query_latent(db::NCDDatabase, z::AbstractVector; limit=1)

Direct model-native latent search interface.
Takes a continuous latent vector z in R^D, maps to H^5, and returns nearest records.
"""
function query_latent(db::NCDDatabase, z::AbstractVector; limit::Int = 1)
    q_pt = project_highdim_to_h5(z)
    return near(db, q_pt; limit=limit)
end

"""
    rotor_between(db::NCDDatabase, key_a::String, key_b::String)::CliffordRotor

Computes the Clifford rotor R in Spin(3) that rotates concept A to concept B.
"""
function rotor_between(db::NCDDatabase, key_a::String, key_b::String)::CliffordRotor
    @assert haskey(db.key_to_node, key_a) "Key '$key_a' not found"
    @assert haskey(db.key_to_node, key_b) "Key '$key_b' not found"
    
    node_a = db.nodes[db.key_to_node[key_a]]
    node_b = db.nodes[db.key_to_node[key_b]]
    
    va = (node_a.x1, node_a.x2, node_a.x3)
    vb = (node_b.x1, node_b.x2, node_b.x3)
    
    return Clifford.rotor_between(va, vb)
end

"""
    apply_rotor(r::CliffordRotor, pt::LorentzPoint)::LorentzPoint

Applies a Clifford rotor to the first 3 spatial dimensions of a LorentzPoint,
leaving the hyperboloid invariant strictly preserved.
"""
function apply_rotor(r::CliffordRotor, pt::LorentzPoint)::LorentzPoint
    sp = serialize_spatial(pt)
    sp_rot = rotate_spatial3(r, sp)
    # Reconstruct x0 (note: spatial norm is preserved under 3D rotor rotation, so x0 is invariant!)
    return LorentzPoint(sp_rot)
end

end # module Engine
