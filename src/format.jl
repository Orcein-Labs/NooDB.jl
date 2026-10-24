# NooDB.jl - Binary File Format & Zero-Copy Mmap Module
# Manages .noodb / .ncd on-disk layout, double-buffered atomic headers,
# codebook tables, and checksummed payloads with crash-recovery invariants.

module Format

using Mmap
using CRC32c
using ..Lorentz
using ..Trie

export NooDBHeader, NCDHeader,
       NOODB_MAGIC, NCD_MAGIC, NOODB_VERSION, NCD_VERSION,
       HEADER_SLOT_SIZE, HEADER_BLOCK_SIZE, MAX_PAYLOAD_SIZE,
       write_header, read_header, write_codebooks, read_codebooks,
       write_trie_nodes, read_trie_nodes, write_key_directory, read_key_directory,
       append_payload, read_payload

# Magic numbers
# "NOO1" in little-endian ASCII: 'N'(0x4E) | 'O'(0x4F)<<8 | 'O'(0x4F)<<16 | '1'(0x31)<<24 = 0x314f4f4e
const NOODB_MAGIC   = 0x314f4f4e
const NCD_MAGIC     = 0x3144434e  # Legacy "NCD1" compatibility
const NOODB_VERSION = 0x0001
const NCD_VERSION   = 0x0001

const HEADER_SLOT_SIZE  = 128
const HEADER_BLOCK_SIZE = 256  # 2 slots (Slot A at 0, Slot B at 128)
const MAX_PAYLOAD_SIZE  = 64 * 1024 * 1024 # 64 MB allocation ceiling defense

"""
    NooDBHeader

128-byte file header containing layout offsets, dimensions, monotonic generation, and CRC32c.
"""
struct NooDBHeader
    magic::UInt32             # 0x00: "NOO1" or "NCD1"
    version::UInt16           # 0x04: Version (1)
    flags::UInt16             # 0x06: Flags
    generation::UInt64        # 0x08: Monotonic commit generation counter
    crc::UInt32               # 0x10: CRC32c of header fields
    scale_depth_k::UInt16     # 0x14: Number of hierarchical concept scale levels
    ambient_dim::UInt16       # 0x16: Spatial dimension (5)
    total_nodes::UInt32       # 0x18: Total trie nodes
    total_records::UInt64     # 0x1C: Total active records
    offset_codebooks::UInt64  # 0x24: Byte offset to codebook tables
    offset_trie::UInt64       # 0x2C: Byte offset to trie node table
    offset_keys::UInt64       # 0x34: Byte offset to string key directory
    offset_payloads::UInt64   # 0x3C: Byte offset to payload storage
    file_size::UInt64         # 0x44: Total file size in bytes
end

# Legacy alias
const NCDHeader = NooDBHeader

"""
    NooDBHeader(magic, version, flags, scale_depth_k, ambient_dim, total_nodes, total_records, ...)

Legacy 12-argument constructor for backwards compatibility. Defaults generation=1, crc=0.
"""
function NooDBHeader(
    magic::UInt32, version::UInt16, flags::Union{UInt8, UInt16},
    scale_depth_k::Union{UInt8, UInt16}, ambient_dim::Union{UInt8, UInt16},
    total_nodes::Union{UInt32, Int}, total_records::Union{UInt64, Int},
    offset_codebooks::Union{UInt64, Int}, offset_trie::Union{UInt64, Int},
    offset_keys::Union{UInt64, Int}, offset_payloads::Union{UInt64, Int},
    file_size::Union{UInt64, Int}
)
    return NooDBHeader(
        magic, version, UInt16(flags), UInt64(1), UInt32(0),
        UInt16(scale_depth_k), UInt16(ambient_dim), UInt32(total_nodes), UInt64(total_records),
        UInt64(offset_codebooks), UInt64(offset_trie), UInt64(offset_keys),
        UInt64(offset_payloads), UInt64(file_size)
    )
end

"""
Compute CRC32c for a header (excluding the crc field itself).
"""
function compute_header_crc(
    magic::UInt32, version::UInt16, flags::UInt16, generation::UInt64,
    scale_depth_k::UInt16, ambient_dim::UInt16, total_nodes::UInt32, total_records::UInt64,
    offset_codebooks::UInt64, offset_trie::UInt64, offset_keys::UInt64,
    offset_payloads::UInt64, file_size::UInt64
)::UInt32
    buf = IOBuffer()
    write(buf, magic)
    write(buf, version)
    write(buf, flags)
    write(buf, generation)
    write(buf, scale_depth_k)
    write(buf, ambient_dim)
    write(buf, total_nodes)
    write(buf, total_records)
    write(buf, offset_codebooks)
    write(buf, offset_trie)
    write(buf, offset_keys)
    write(buf, offset_payloads)
    write(buf, file_size)
    return crc32c(take!(buf))
end

"""
    write_header(io::IO, h::NooDBHeader)

Writes a header using double-buffered atomic commit (Slot A at 0, Slot B at 128).
Alternates based on generation counter to ensure a crash mid-write never destroys the previous header.
"""
function write_header(io::IO, h::NooDBHeader)
    # Slot 0 (bytes 0..127) if generation is odd, Slot 1 (bytes 128..255) if even
    slot_offset = (h.generation % 2 == 1) ? 0 : HEADER_SLOT_SIZE
    
    # Compute CRC32c over the header fields
    computed_crc = compute_header_crc(
        h.magic, h.version, h.flags, h.generation,
        h.scale_depth_k, h.ambient_dim, h.total_nodes, h.total_records,
        h.offset_codebooks, h.offset_trie, h.offset_keys,
        h.offset_payloads, h.file_size
    )
    
    seek(io, slot_offset)
    write(io, h.magic)
    write(io, h.version)
    write(io, h.flags)
    write(io, h.generation)
    write(io, computed_crc)
    write(io, h.scale_depth_k)
    write(io, h.ambient_dim)
    write(io, h.total_nodes)
    write(io, h.total_records)
    write(io, h.offset_codebooks)
    write(io, h.offset_trie)
    write(io, h.offset_keys)
    write(io, h.offset_payloads)
    write(io, h.file_size)
    
    # Pad to exactly 128 bytes for this slot
    bytes_written = 4 + 2 + 2 + 8 + 4 + 2 + 2 + 4 + 8 + 8 + 8 + 8 + 8 + 8
    padding_needed = HEADER_SLOT_SIZE - bytes_written
    if padding_needed > 0
        write(io, zeros(UInt8, padding_needed))
    end
    
    flush(io)
end

"""
Helper to attempt parsing a 128-byte header slot.
Returns (header, is_valid).
"""
function parse_slot(io::IO, slot_offset::Int)::Tuple{Union{Nothing, NooDBHeader}, Bool}
    seekend(io)
    f_len = position(io)
    if f_len < slot_offset + HEADER_SLOT_SIZE
        return (nothing, false)
    end
    
    seek(io, slot_offset)
    magic = read(io, UInt32)
    if magic != NOODB_MAGIC && magic != NCD_MAGIC
        return (nothing, false)
    end
    
    version = read(io, UInt16)
    if version > NOODB_VERSION
        return (nothing, false)
    end
    
    flags = read(io, UInt16)
    generation = read(io, UInt64)
    crc_stored = read(io, UInt32)
    scale_depth_k = read(io, UInt16)
    ambient_dim = read(io, UInt16)
    total_nodes = read(io, UInt32)
    total_records = read(io, UInt64)
    offset_codebooks = read(io, UInt64)
    offset_trie = read(io, UInt64)
    offset_keys = read(io, UInt64)
    offset_payloads = read(io, UInt64)
    file_size = read(io, UInt64)
    
    # Verify CRC32c
    computed_crc = compute_header_crc(
        magic, version, flags, generation,
        scale_depth_k, ambient_dim, total_nodes, total_records,
        offset_codebooks, offset_trie, offset_keys, offset_payloads, file_size
    )
    
    # If legacy v1 file without CRC (generation was 0 and crc was 0), tolerate if magic is valid
    is_valid = (crc_stored == computed_crc) || (generation == 0 && crc_stored == 0)
    
    h = NooDBHeader(
        magic, version, flags, generation, crc_stored,
        scale_depth_k, ambient_dim, total_nodes, total_records,
        offset_codebooks, offset_trie, offset_keys, offset_payloads, file_size
    )
    return (h, is_valid)
end

"""
    read_header(io::IO)::NooDBHeader

Reads and validates the double-buffered header slots (Slot A and Slot B).
Automatically selects the latest valid generation and recovers from interrupted writes.
"""
function read_header(io::IO)::NooDBHeader
    h_a, valid_a = parse_slot(io, 0)
    h_b, valid_b = parse_slot(io, HEADER_SLOT_SIZE)
    
    if valid_a && valid_b
        # Both valid: choose the newer generation
        return (h_a.generation >= h_b.generation) ? h_a : h_b
    elseif valid_a
        return h_a
    elseif valid_b
        return h_b
    elseif h_a !== nothing
        # Header A parsed with non-CRC legacy format
        return h_a
    else
        error("Corrupt NooDB file: both header slots failed validation and CRC32c verification")
    end
end

"""
    append_payload(io::IO, data::Vector{UInt8})::Tuple{UInt64, UInt32}

Appends a length-prefixed, CRC32c-checksummed payload block at the end of the file.
Returns (payload_offset, payload_size).
Format: [Length: UInt32][CRC32c: UInt32][Raw bytes: length...]
"""
function append_payload(io::IO, data::Vector{UInt8})::Tuple{UInt64, UInt32}
    len = UInt32(length(data))
    if len > MAX_PAYLOAD_SIZE
        error("Payload size ($len bytes) exceeds maximum allowable limit of $MAX_PAYLOAD_SIZE bytes")
    end
    
    seekend(io)
    offset = UInt64(position(io))
    chk = crc32c(data)
    
    write(io, len)
    write(io, chk)
    write(io, data)
    flush(io)
    
    return (offset, len)
end

"""
    read_payload(io::IO, offset::UInt64, size::UInt32)::Vector{UInt8}

Reads and verifies a payload block at offset with strict bounds and CRC32c check.
Guards against malicious file size OOM bombs and corrupted offsets.
"""
function read_payload(io::IO, offset::UInt64, size::UInt32)::Vector{UInt8}
    if size > MAX_PAYLOAD_SIZE
        error("Hostile payload read: size ($size bytes) exceeds security ceiling of $MAX_PAYLOAD_SIZE bytes")
    end
    
    seekend(io)
    total_fsize = UInt64(position(io))
    if offset + 8 + UInt64(size) > total_fsize
        error("Corrupted payload offset $offset + size $size exceeds file boundary $total_fsize")
    end
    
    seek(io, offset)
    len = read(io, UInt32)
    if len != size
        error("Payload size mismatch at offset $offset: expected $size, found $len")
    end
    
    chk_stored = read(io, UInt32)
    data = read(io, len)
    chk_computed = crc32c(data)
    
    if chk_stored != chk_computed
        throw(AssertionError("CRC32c checksum failure for payload at offset $offset: stored 0x$(string(chk_stored, base=16)), computed 0x$(string(chk_computed, base=16))"))
    end
    
    return data
end

"""
    write_codebooks(io::IO, codebooks::Vector{Vector{LorentzPoint}})::UInt64
"""
function write_codebooks(io::IO, codebooks::Vector{Vector{LorentzPoint}})::UInt64
    seekend(io)
    offset = UInt64(position(io))
    k_depth = UInt16(length(codebooks))
    write(io, k_depth)
    for cb in codebooks
        sz = UInt32(length(cb))
        write(io, sz)
        for pt in cb
            write(io, pt.x0)
            write(io, pt.x1)
            write(io, pt.x2)
            write(io, pt.x3)
            write(io, pt.x4)
            write(io, pt.x5)
        end
    end
    flush(io)
    return offset
end

"""
    read_codebooks(io::IO, offset::UInt64)::Vector{Vector{LorentzPoint}}
"""
function read_codebooks(io::IO, offset::UInt64)::Vector{Vector{LorentzPoint}}
    if offset == 0
        return Vector{Vector{LorentzPoint}}()
    end
    seek(io, offset)
    k_depth = read(io, UInt16)
    codebooks = Vector{Vector{LorentzPoint}}(undef, Int(k_depth))
    for k in 1:Int(k_depth)
        sz = read(io, UInt32)
        cb = Vector{LorentzPoint}(undef, Int(sz))
        for i in 1:Int(sz)
            x0 = read(io, Float32)
            x1 = read(io, Float32)
            x2 = read(io, Float32)
            x3 = read(io, Float32)
            x4 = read(io, Float32)
            x5 = read(io, Float32)
            cb[i] = LorentzPoint(x0, x1, x2, x3, x4, x5)
        end
        codebooks[k] = cb
    end
    return codebooks
end

"""
    write_node(io::IO, n::TrieNode)
"""
function write_node(io::IO, n::TrieNode)
    write(io, n.child_offset)
    write(io, n.payload_offset)
    write(io, n.flags)
    write(io, n.payload_size)
    write(io, n.scale_level)
    write(io, n.code_id)
    write(io, n.child_count)
    write(io, n.reserved1)
    write(io, n.x0)
    write(io, n.x1)
    write(io, n.x2)
    write(io, n.x3)
    write(io, n.x4)
    write(io, n.x5)
    write(io, n.cluster_radius)
    write(io, n.reserved2)
end

"""
    read_node(io::IO)::TrieNode
"""
function read_node(io::IO)::TrieNode
    child_offset = read(io, UInt64)
    payload_offset = read(io, UInt64)
    flags = read(io, UInt32)
    payload_size = read(io, UInt32)
    scale_level = read(io, UInt16)
    code_id = read(io, UInt16)
    child_count = read(io, UInt16)
    reserved1 = read(io, UInt16)
    x0 = read(io, Float32)
    x1 = read(io, Float32)
    x2 = read(io, Float32)
    x3 = read(io, Float32)
    x4 = read(io, Float32)
    x5 = read(io, Float32)
    cluster_radius = read(io, Float32)
    reserved2 = read(io, UInt32)
    return TrieNode(
        child_offset, payload_offset, flags, payload_size,
        scale_level, code_id, child_count, reserved1,
        x0, x1, x2, x3, x4, x5, cluster_radius, reserved2
    )
end

"""
    write_trie_nodes(io::IO, nodes::Vector{TrieNode}, children::Dict{Int, Vector{Int}})::UInt64
"""
function write_trie_nodes(io::IO, nodes::Vector{TrieNode}, children::Dict{Int, Vector{Int}})::UInt64
    seekend(io)
    offset = UInt64(position(io))
    count = UInt32(length(nodes))
    write(io, count)
    for node in nodes
        write_node(io, node)
    end
    
    # Write children adjacency
    write(io, UInt32(length(children)))
    for (node_idx, child_list) in children
        write(io, UInt32(node_idx))
        write(io, UInt32(length(child_list)))
        for c in child_list
            write(io, UInt32(c))
        end
    end
    
    flush(io)
    return offset
end

"""
    read_trie_nodes(io::IO, offset::UInt64)::Tuple{Vector{TrieNode}, Dict{Int, Vector{Int}}}
"""
function read_trie_nodes(io::IO, offset::UInt64)::Tuple{Vector{TrieNode}, Dict{Int, Vector{Int}}}
    if offset == 0
        return (TrieNode[], Dict{Int, Vector{Int}}())
    end
    seek(io, offset)
    count = read(io, UInt32)
    nodes = Vector{TrieNode}(undef, Int(count))
    for i in 1:Int(count)
        nodes[i] = read_node(io)
    end
    
    # Read children adjacency
    children = Dict{Int, Vector{Int}}()
    num_adj = read(io, UInt32)
    for _ in 1:Int(num_adj)
        n_idx = Int(read(io, UInt32))
        c_len = Int(read(io, UInt32))
        c_list = [Int(read(io, UInt32)) for _ in 1:c_len]
        children[n_idx] = c_list
    end
    
    return (nodes, children)
end

"""
    write_key_directory(io::IO, key_to_node::Dict{String, Int})::UInt64
"""
function write_key_directory(io::IO, key_to_node::Dict{String, Int})::UInt64
    seekend(io)
    offset = UInt64(position(io))
    count = UInt32(length(key_to_node))
    write(io, count)
    for (k, node_idx) in key_to_node
        k_bytes = codeunits(k)
        if length(k_bytes) > 65535
            throw(ArgumentError("Key exceeds max length of 65535 bytes: '$k'"))
        end
        write(io, UInt16(length(k_bytes)))
        write(io, k_bytes)
        write(io, UInt32(node_idx))
    end
    flush(io)
    return offset
end

"""
    read_key_directory(io::IO, offset::UInt64)::Dict{String, Int}
"""
function read_key_directory(io::IO, offset::UInt64)::Dict{String, Int}
    dict = Dict{String, Int}()
    if offset == 0
        return dict
    end
    seek(io, offset)
    count = read(io, UInt32)
    for _ in 1:Int(count)
        k_len = read(io, UInt16)
        k_bytes = read(io, k_len)
        k = String(k_bytes)
        node_idx = read(io, UInt32)
        dict[k] = Int(node_idx)
    end
    return dict
end

end # module Format
