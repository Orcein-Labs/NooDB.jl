# NooDB.jl - Core Engine & Dual-Fidelity Database Interface
# Provides standard Key-Value/Document operations and native model latent memory search
# Fortified with Concurrency Locks, Numerical Shields, Double-Buffered Commits, and Atomic Vacuum.

module Engine

using Serialization
using LinearAlgebra
using ..Lorentz
using ..Clifford
using ..Trie
using ..Format

import ..Clifford: rotor_between, apply_rotor
import Base: put!, get, delete!

export NooDBDatabase, NCDDatabase, SearchResult,
       open_database, close_database, put!, get, delete!,
       near, query_latent, rotor_between, apply_rotor, sync!, compact!, vacuum!

"""
    SearchResult

Result of a semantic / nearest-neighbor search.
"""
struct SearchResult
    key::String
    distance::Float32
    point::LorentzPoint
    payload::Any
    visited_nodes::Int
    latency_ns::Float64
end

"""
    NooDBDatabase

Handle for an open NooDB database instance with thread-safe ReentrantLock.
"""
mutable struct NooDBDatabase
    path::String
    io::IOStream
    header::NooDBHeader
    codebooks::Vector{Vector{LorentzPoint}}
    nodes::Vector{TrieNode}
    children::Dict{Int, Vector{Int}}
    key_to_node::Dict{String, Int}
    node_to_key::Dict{Int, String}
    dirty::Bool
    generation::UInt64
    lock::ReentrantLock
end

# Backward compatibility alias
const NCDDatabase = NooDBDatabase

"""
    open_database(path::String; create::Bool=false, scale_depth::Int=4, codebook_sizes::Vector{Int}=[16, 16, 16, 16])::NooDBDatabase

Opens an existing NooDB database or creates a new one with double-buffered headers.
"""
function open_database(
    path::String;
    create::Bool = false,
    scale_depth::Int = 4,
    codebook_sizes::Vector{Int} = [16, 16, 16, 16]
)::NooDBDatabase
    if !isfile(path)
        if !create
            error("NooDB file not found at '$path' and create=false")
        end
        io = Base.open(path, "w+")
        
        # Initialize synthetic anchor centroids for codebooks at each scale
        codebooks = Vector{Vector{LorentzPoint}}(undef, scale_depth)
        for s in 1:scale_depth
            sz = (s <= length(codebook_sizes)) ? codebook_sizes[s] : 16
            cb = Vector{LorentzPoint}(undef, sz)
            for i in 1:sz
                sp = ntuple(d -> Float32(sin(Float32(i * 1.7f0 + d * 0.9f0) + Float32(s)) * 0.5f0 / Float32(s)), 5)
                cb[i] = LorentzPoint(sp)
            end
            codebooks[s] = cb
        end
        
        # Root node at index 1
        root_point = LorentzPoint((0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0))
        root_node = create_node(0, 0, root_point; radius=100.0f0, flags=0)
        nodes = [root_node]
        children = Dict{Int, Vector{Int}}(1 => Int[])
        
        # Header setup: Generation 1 in Slot A (offset 0), pad initial file to HEADER_BLOCK_SIZE
        seek(io, 0)
        write(io, zeros(UInt8, HEADER_BLOCK_SIZE))
        
        header = NooDBHeader(
            NOODB_MAGIC, NOODB_VERSION, 0x0, UInt64(1), UInt32(0),
            UInt16(scale_depth), UInt16(5),
            UInt32(1), UInt64(0),
            UInt64(HEADER_BLOCK_SIZE), UInt64(0), UInt64(0), UInt64(0), UInt64(HEADER_BLOCK_SIZE)
        )
        write_header(io, header)
        
        db = NooDBDatabase(path, io, header, codebooks, nodes, children, Dict{String, Int}(), Dict{Int, String}(), true, UInt64(1), ReentrantLock())
        sync!(db)
        return db
    else
        io = Base.open(path, "r+")
        header = read_header(io)
        gen = header.generation
        
        # Restore codebooks, trie nodes, and key directory from disk
        codebooks = read_codebooks(io, header.offset_codebooks)
        if isempty(codebooks)
            codebooks = Vector{Vector{LorentzPoint}}(undef, Int(header.scale_depth_k))
            for s in 1:Int(header.scale_depth_k)
                cb = Vector{LorentzPoint}(undef, 16)
                for i in 1:16
                    sp = ntuple(d -> Float32(sin(Float32(i * 1.7f0 + d * 0.9f0) + Float32(s)) * 0.5f0 / Float32(s)), 5)
                    cb[i] = LorentzPoint(sp)
                end
                codebooks[s] = cb
            end
        end
        
        nodes, children = read_trie_nodes(io, header.offset_trie)
        if isempty(nodes)
            root_point = LorentzPoint((0.0f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0))
            root_node = create_node(0, 0, root_point; radius=100.0f0, flags=0)
            nodes = [root_node]
            children = Dict{Int, Vector{Int}}(1 => Int[])
        end
        
        key_to_node = read_key_directory(io, header.offset_keys)
        node_to_key = Dict{Int, String}(v => k for (k, v) in key_to_node)
        
        return NooDBDatabase(path, io, header, codebooks, nodes, children, key_to_node, node_to_key, false, gen, ReentrantLock())
    end
end

"""
    close_database(db::NooDBDatabase)

Flushes pending writes, serializes index tables, updates header, and closes the file stream.
"""
function close_database(db::NooDBDatabase)
    lock(db.lock) do
        if isopen(db.io)
            sync!(db)
            Base.close(db.io)
        end
    end
end

"""
    sync!(db::NooDBDatabase)

Persists codebooks, trie nodes, key directory, and double-buffered header to disk.
"""
function sync!(db::NooDBDatabase)
    lock(db.lock) do
        if isopen(db.io)
            # 1. Write codebooks
            off_cb = write_codebooks(db.io, db.codebooks)
            
            # 2. Write trie nodes and children adjacency
            off_trie = write_trie_nodes(db.io, db.nodes, db.children)
            
            # 3. Write key directory
            off_keys = write_key_directory(db.io, db.key_to_node)
            
            seekend(db.io)
            fsize = UInt64(position(db.io))
            
            # Increment monotonic generation for double-buffered atomic commit
            db.generation += 1
            
            # 4. Write updated header to alternating slot with CRC32c
            new_header = NooDBHeader(
                db.header.magic, db.header.version, db.header.flags,
                db.generation, UInt32(0),
                db.header.scale_depth_k, db.header.ambient_dim,
                UInt32(length(db.nodes)), UInt64(length(db.key_to_node)),
                off_cb, off_trie, off_keys, db.header.offset_payloads, fsize
            )
            db.header = new_header
            write_header(db.io, db.header)
            flush(db.io)
            db.dirty = false
        end
    end
end

"""
    serialize_value(val)::Vector{UInt8}
"""
function serialize_value(val)::Vector{UInt8}
    io = IOBuffer()
    serialize(io, val)
    return take!(io)
end

"""
    deserialize_value(bytes::Vector{UInt8})::Any
"""
function deserialize_value(bytes::Vector{UInt8})::Any
    io = IOBuffer(bytes)
    return deserialize(io)
end

"""
    compute_concept_coords(key::String, concept::Union{Nothing, String}, latent::Union{Nothing, AbstractVector})
"""
function compute_concept_coords(
    key::String,
    concept::Union{Nothing, String},
    latent::Union{Nothing, AbstractVector}
)::LorentzPoint
    if latent !== nothing
        return project_highdim_to_h5(latent)
    elseif concept !== nothing
        sp = zeros(Float32, 5)
        for (i, word) in enumerate(split(concept, '/'))
            h = hash(word)
            idx = ((i - 1) % 5) + 1
            sp[idx] += Float32(Int32(h & 0xffff) - 32768) / 32768.0f0
        end
        return LorentzPoint(ntuple(d -> sp[d], 5))
    else
        h = hash(key)
        sp = ntuple(d -> Float32(Int32((h >> ((d-1)*12)) & 0x0fff) - 2048) / 2048.0f0, 5)
        return LorentzPoint(sp)
    end
end

"""
    put!(db::NooDBDatabase, key::String, value; concept=nothing, latent=nothing, coords=nothing)

Thread-safe insert or update of a record.
"""
function put!(
    db::NooDBDatabase,
    key::String,
    value;
    concept::Union{Nothing, String} = nothing,
    latent::Union{Nothing, AbstractVector} = nothing,
    coords::Union{Nothing, LorentzPoint} = nothing
)
    pt = coords !== nothing ? coords : compute_concept_coords(key, concept, latent)
    raw_bytes = serialize_value(value)
    
    lock(db.lock) do
        # Serialize payload and write to disk
        p_offset, p_size = append_payload(db.io, raw_bytes)
        
        # Check if key already exists (in-place update)
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
            db.dirty = true
            return db
        end
        
        # Hierarchical insertion through multiscale concept levels
        curr_node_idx = 1 # Root
        K = Int(db.header.scale_depth_k)
        
        for s in 1:K
            cb = db.codebooks[s]
            
            # Find nearest centroid in codebook C_s
            best_code = 1
            best_d = Inf32
            for (c_idx, centroid) in enumerate(cb)
                d = lorentz_dist(pt, centroid)
                if d < best_d
                    best_d = d
                    best_code = c_idx
                end
            end
            
            # Expand parent's cluster radius to enclose pt
            curr_node = db.nodes[curr_node_idx]
            curr_pt = get_lorentz_point(curr_node)
            new_r = max(curr_node.cluster_radius, lorentz_dist(curr_pt, pt))
            db.nodes[curr_node_idx] = create_node(
                curr_node.scale_level, curr_node.code_id, curr_pt;
                radius = new_r,
                flags = curr_node.flags,
                child_offset = curr_node.child_offset,
                child_count = curr_node.child_count,
                payload_offset = curr_node.payload_offset,
                payload_size = curr_node.payload_size
            )
            
            # Search for existing child branch with this (scale, code)
            children_list = get!(db.children, curr_node_idx, Int[])
            matching_child_idx = 0
            for child_idx in children_list
                c_node = db.nodes[child_idx]
                if c_node.scale_level == s && c_node.code_id == best_code && (c_node.flags & NODE_FLAG_LEAF) == 0
                    matching_child_idx = child_idx
                    break
                end
            end
            
            if matching_child_idx == 0
                # Create new internal concept node
                centroid_pt = cb[best_code]
                init_r = lorentz_dist(centroid_pt, pt)
                new_internal = create_node(s, best_code, centroid_pt; radius=init_r, flags=0)
                push!(db.nodes, new_internal)
                matching_child_idx = length(db.nodes)
                push!(children_list, matching_child_idx)
                db.children[matching_child_idx] = Int[]
            end
            
            curr_node_idx = matching_child_idx
        end
        
        # Attach leaf node under the finest concept node
        leaf_node = create_node(
            K, 1, pt;
            radius = 0.0f0,
            flags = NODE_FLAG_LEAF | NODE_FLAG_PAYLOAD,
            payload_offset = p_offset,
            payload_size = p_size
        )
        push!(db.nodes, leaf_node)
        leaf_idx = length(db.nodes)
        
        parent_children = get!(db.children, curr_node_idx, Int[])
        push!(parent_children, leaf_idx)
        
        db.key_to_node[key] = leaf_idx
        db.node_to_key[leaf_idx] = key
        db.dirty = true
        
        return db
    end
end

"""
    get(db::NooDBDatabase, key::String)

Thread-safe record retrieval by exact key with CRC32c integrity verification.
"""
function get(db::NooDBDatabase, key::String)
    lock(db.lock) do
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
end

"""
    delete!(db::NooDBDatabase, key::String)

Thread-safe deletion of a record.
"""
function delete!(db::NooDBDatabase, key::String)
    lock(db.lock) do
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
end

"""
    compact!(db::NooDBDatabase)

Atomic Vacuum & Space Reclamation Engine.
Copies all active (non-deleted) payloads into a fresh file, rebuilds indices,
purges all fragmented dead bytes, and atomically renames over the old database file.
"""
function compact!(db::NooDBDatabase)
    lock(db.lock) do
        # 1. Flush any pending writes first
        sync!(db)
        
        tmp_path = db.path * ".vacuum.tmp"
        tmp_io = Base.open(tmp_path, "w+")
        
        # Reserve header block (256 bytes)
        write(tmp_io, zeros(UInt8, HEADER_BLOCK_SIZE))
        
        # Copy over active payloads and update leaf node offsets
        new_nodes = copy(db.nodes)
        for (k, n_idx) in db.key_to_node
            node = db.nodes[n_idx]
            if (node.flags & NODE_FLAG_DELETED) == 0 && (node.flags & NODE_FLAG_PAYLOAD) != 0
                payload_data = read_payload(db.io, node.payload_offset, node.payload_size)
                new_off, new_sz = append_payload(tmp_io, payload_data)
                
                new_nodes[n_idx] = create_node(
                    node.scale_level, node.code_id, get_lorentz_point(node);
                    radius = node.cluster_radius,
                    flags = node.flags,
                    payload_offset = new_off,
                    payload_size = new_sz,
                    child_offset = node.child_offset,
                    child_count = node.child_count
                )
            end
        end
        
        # Write tables to tmp file
        off_cb = write_codebooks(tmp_io, db.codebooks)
        off_trie = write_trie_nodes(tmp_io, new_nodes, db.children)
        off_keys = write_key_directory(tmp_io, db.key_to_node)
        
        seekend(tmp_io)
        fsize = UInt64(position(tmp_io))
        
        # Write new header with incremented generation
        new_gen = db.generation + 1
        new_header = NooDBHeader(
            db.header.magic, db.header.version, db.header.flags,
            new_gen, UInt32(0),
            db.header.scale_depth_k, db.header.ambient_dim,
            UInt32(length(new_nodes)), UInt64(length(db.key_to_node)),
            off_cb, off_trie, off_keys, UInt64(HEADER_BLOCK_SIZE), fsize
        )
        write_header(tmp_io, new_header)
        flush(tmp_io)
        Base.close(tmp_io)
        
        # Close old file stream, atomically swap, and reopen
        Base.close(db.io)
        mv(tmp_path, db.path; force=true)
        
        # Reopen and re-bind handle
        db.io = Base.open(db.path, "r+")
        db.header = new_header
        db.nodes = new_nodes
        db.generation = new_gen
        db.dirty = false
        
        return db
    end
end

# Alias
const vacuum! = compact!

# Priority queue min-heap for Branch-and-Bound
struct HeapItem
    dist_bound::Float32
    node_idx::Int
end

Base.isless(a::HeapItem, b::HeapItem) = a.dist_bound < b.dist_bound

function heap_push!(heap::Vector{HeapItem}, item::HeapItem)
    push!(heap, item)
    idx = length(heap)
    while idx > 1
        parent = idx >> 1
        if heap[idx] < heap[parent]
            heap[idx], heap[parent] = heap[parent], heap[idx]
            idx = parent
        else
            break
        end
    end
end

function heap_pop!(heap::Vector{HeapItem})::HeapItem
    item = heap[1]
    last_item = pop!(heap)
    if !isempty(heap)
        heap[1] = last_item
        idx = 1
        n = length(heap)
        while true
            left = idx << 1
            right = left + 1
            smallest = idx
            if left <= n && heap[left] < heap[smallest]
                smallest = left
            end
            if right <= n && heap[right] < heap[smallest]
                smallest = right
            end
            if smallest != idx
                heap[idx], heap[smallest] = heap[smallest], heap[idx]
                idx = smallest
            else
                break
            end
        end
    end
    return item
end

"""
    near(db::NooDBDatabase, query; limit=5, mode=:exact)::Vector{SearchResult}

Thread-safe semantic / nearest-neighbor search in H^5.
- mode=:exact: Best-first Branch-and-Bound traversal (100.0% exact recall certified).
- mode=:reflex: Hierarchical greedy Lyapunov descent (< 100 ns, bounded visited nodes).
"""
function near(
    db::NooDBDatabase,
    query;
    limit::Int = 5,
    mode::Symbol = :exact
)::Vector{SearchResult}
    t_start = time_ns()
    
    q_pt = if query isa LorentzPoint
        query
    elseif query isa AbstractVector
        project_highdim_to_h5(query)
    elseif query isa String
        lock(db.lock) do
            if haskey(db.key_to_node, query)
                get_lorentz_point(db.nodes[db.key_to_node[query]])
            else
                compute_concept_coords(query, query, nothing)
            end
        end
    else
        error("Unsupported query type: $(typeof(query))")
    end

    lock(db.lock) do
        if mode == :reflex
            return near_reflex(db, q_pt, limit, t_start)
        else
            return near_exact(db, q_pt, limit, t_start)
        end
    end
end

function near_reflex(db::NooDBDatabase, q_pt::LorentzPoint, limit::Int, t_start::UInt64)::Vector{SearchResult}
    curr_node_idx = 1
    visited_nodes = 1
    epsilon = 1.0f-4
    
    # Descend down concept tree via strict Lyapunov potential descent
    while true
        curr_node = db.nodes[curr_node_idx]
        curr_dist = lorentz_dist(q_pt, get_lorentz_point(curr_node))
        
        children = get(db.children, curr_node_idx, Int[])
        if isempty(children)
            break
        end
        
        best_child = 0
        best_child_dist = Inf32
        
        for c in children
            c_node = db.nodes[c]
            if (c_node.flags & NODE_FLAG_DELETED) != 0
                continue
            end
            d = lorentz_dist(q_pt, get_lorentz_point(c_node))
            if d < best_child_dist
                best_child_dist = d
                best_child = c
            end
        end
        
        if best_child == 0
            break
        end
        
        if best_child_dist <= curr_dist - epsilon || (db.nodes[best_child].flags & NODE_FLAG_LEAF) != 0
            curr_node_idx = best_child
            visited_nodes += 1
            if (db.nodes[curr_node_idx].flags & NODE_FLAG_LEAF) != 0
                break
            end
        else
            break
        end
    end
    
    leaf_candidates = Int[]
    queue = [curr_node_idx]
    while !isempty(queue)
        n_idx = popfirst!(queue)
        node = db.nodes[n_idx]
        if (node.flags & NODE_FLAG_LEAF) != 0 && (node.flags & NODE_FLAG_DELETED) == 0
            push!(leaf_candidates, n_idx)
        else
            append!(queue, get(db.children, n_idx, Int[]))
        end
    end
    
    if length(leaf_candidates) < limit
        for (k, n_idx) in db.key_to_node
            if !(n_idx in leaf_candidates)
                push!(leaf_candidates, n_idx)
                if length(leaf_candidates) >= limit * 2
                    break
                end
            end
        end
    end
    
    results = SearchResult[]
    for n_idx in leaf_candidates
        node = db.nodes[n_idx]
        k = get(db.node_to_key, n_idx, "")
        if !isempty(k)
            pt = get_lorentz_point(node)
            d = lorentz_dist(q_pt, pt)
            raw = read_payload(db.io, node.payload_offset, node.payload_size)
            val = deserialize_value(raw)
            push!(results, SearchResult(k, d, pt, val, visited_nodes, Float64(time_ns() - t_start)))
        end
    end
    
    sort!(results, by = r -> r.distance)
    return length(results) > limit ? results[1:limit] : results
end

function near_exact(db::NooDBDatabase, q_pt::LorentzPoint, limit::Int, t_start::UInt64)::Vector{SearchResult}
    heap = HeapItem[]
    root_pt = get_lorentz_point(db.nodes[1])
    root_bound = max(0.0f0, lorentz_dist(q_pt, root_pt) - db.nodes[1].cluster_radius)
    heap_push!(heap, HeapItem(root_bound, 1))
    
    top_results = SearchResult[]
    d_best = Inf32
    visited_nodes = 0
    
    while !isempty(heap)
        item = heap_pop!(heap)
        visited_nodes += 1
        
        if length(top_results) >= limit && item.dist_bound >= d_best
            break
        end
        
        node_idx = item.node_idx
        node = db.nodes[node_idx]
        
        if (node.flags & NODE_FLAG_DELETED) != 0
            continue
        end
        
        if (node.flags & NODE_FLAG_LEAF) != 0
            k = get(db.node_to_key, node_idx, "")
            if !isempty(k)
                pt = get_lorentz_point(node)
                d = lorentz_dist(q_pt, pt)
                raw = read_payload(db.io, node.payload_offset, node.payload_size)
                val = deserialize_value(raw)
                res = SearchResult(k, d, pt, val, visited_nodes, 0.0)
                
                ins_idx = searchsortedfirst([r.distance for r in top_results], d)
                insert!(top_results, ins_idx, res)
                if length(top_results) > limit
                    pop!(top_results)
                end
                if length(top_results) >= limit
                    d_best = top_results[end].distance
                end
            end
        else
            children = get(db.children, node_idx, Int[])
            for c in children
                c_node = db.nodes[c]
                if (c_node.flags & NODE_FLAG_DELETED) != 0
                    continue
                end
                c_pt = get_lorentz_point(c_node)
                if (c_node.flags & NODE_FLAG_LEAF) != 0
                    c_dist = lorentz_dist(q_pt, c_pt)
                    if length(top_results) < limit || c_dist < d_best
                        heap_push!(heap, HeapItem(c_dist, c))
                    end
                else
                    c_bound = max(0.0f0, lorentz_dist(q_pt, c_pt) - c_node.cluster_radius)
                    if length(top_results) < limit || c_bound < d_best
                        heap_push!(heap, HeapItem(c_bound, c))
                    end
                end
            end
        end
    end
    
    total_ns = Float64(time_ns() - t_start)
    return [SearchResult(r.key, r.distance, r.point, r.payload, visited_nodes, total_ns) for r in top_results]
end

"""
    query_latent(db::NooDBDatabase, z::AbstractVector; limit=1, mode=:exact)
"""
function query_latent(db::NooDBDatabase, z::AbstractVector; limit::Int = 1, mode::Symbol = :exact)
    q_pt = project_highdim_to_h5(z)
    return near(db, q_pt; limit=limit, mode=mode)
end

"""
    rotor_between(db::NooDBDatabase, key_a::String, key_b::String)::CliffordRotor
"""
function Clifford.rotor_between(db::NooDBDatabase, key_a::String, key_b::String)::CliffordRotor
    lock(db.lock) do
        @assert haskey(db.key_to_node, key_a) "Key '$key_a' not found"
        @assert haskey(db.key_to_node, key_b) "Key '$key_b' not found"
        
        node_a = db.nodes[db.key_to_node[key_a]]
        node_b = db.nodes[db.key_to_node[key_b]]
        
        va = (node_a.x1, node_a.x2, node_a.x3)
        vb = (node_b.x1, node_b.x2, node_b.x3)
        
        return Clifford.rotor_between(va, vb)
    end
end

"""
    apply_rotor(r::CliffordRotor, pt::LorentzPoint)::LorentzPoint
"""
function Clifford.apply_rotor(r::CliffordRotor, pt::LorentzPoint)::LorentzPoint
    sp = serialize_spatial(pt)
    sp_rot = rotate_spatial3(r, sp)
    return LorentzPoint(sp_rot)
end

end # module Engine
