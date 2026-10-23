# NCD.jl - Binary File Format & Zero-Copy Mmap Module
# Manages .ncd on-disk layout, headers, codebook tables, and checksummed payloads

module Format

using Mmap
using CRC32c
using ..Lorentz
using ..Trie

export NCDHeader, NCD_MAGIC, NCD_VERSION, HEADER_SIZE,
       write_header, read_header, write_codebooks, read_codebooks,
       write_trie_nodes, read_trie_nodes, write_key_directory, read_key_directory,
       append_payload, read_payload, format_database

const NCD_MAGIC   = 0x3144434e  # "NCD1" in little-endian ASCII
const NCD_VERSION = 0x0001
const HEADER_SIZE = 128

"""
    NCDHeader

128-byte file header containing layout offsets and dimensions.
"""
struct NCDHeader
    magic::UInt32             # 0x00: "NCD1"
    version::UInt16           # 0x04: Version (1)
    flags::UInt16             # 0x06: Flags
    scale_depth_k::UInt16     # 0x08: Number of hierarchical concept scale levels
    ambient_dim::UInt16       # 0x0A: Spatial dimension (5)
    total_nodes::UInt32       # 0x0C: Total trie nodes
    total_records::UInt64     # 0x10: Total stored records
    offset_codebooks::UInt64  # 0x18: Byte offset to codebook tables
    offset_trie::UInt64       # 0x20: Byte offset to trie node table
    offset_keys::UInt64       # 0x28: Byte offset to string key directory
    offset_payloads::UInt64   # 0x30: Byte offset to payload storage
    file_size::UInt64         # 0x38: Total file size in bytes
end

function write_header(io::IO, h::NCDHeader)
    seek(io, 0)
    write(io, h.magic)
    write(io, h.version)
    write(io, h.flags)
    write(io, h.scale_depth_k)
    write(io, h.ambient_dim)
    write(io, h.total_nodes)
    write(io, h.total_records)
    write(io, h.offset_codebooks)
    write(io, h.offset_trie)
    write(io, h.offset_keys)
    write(io, h.offset_payloads)
    write(io, h.file_size)
    # Write 64 bytes of reserved padding (total 128 bytes)
    write(io, zeros(UInt8, 64))
    flush(io)
end

function read_header(io::IO)::NCDHeader
    seek(io, 0)
    magic = read(io, UInt32)
    @assert magic == NCD_MAGIC "Invalid NCD file: bad magic (expected 0x$(string(NCD_MAGIC, base=16)), got 0x$(string(magic, base=16)))"
    version = read(io, UInt16)
    @assert version <= NCD_VERSION "Unsupported NCD version: $version"
    flags = read(io, UInt16)
    scale_depth_k = read(io, UInt16)
    ambient_dim = read(io, UInt16)
    total_nodes = read(io, UInt32)
    total_records = read(io, UInt64)
    offset_codebooks = read(io, UInt64)
    offset_trie = read(io, UInt64)
    offset_keys = read(io, UInt64)
    offset_payloads = read(io, UInt64)
    file_size = read(io, UInt64)
    
    # Skip reserved 64 bytes
    skip(io, 64)
    
    return NCDHeader(
        magic, version, flags, scale_depth_k, ambient_dim,
        total_nodes, total_records, offset_codebooks, offset_trie,
        offset_keys, offset_payloads, file_size
    )
end

"""
    append_payload(io::IO, data::Vector{UInt8})::Tuple{UInt64, UInt32}

Appends a length-prefixed, CRC32c-checksummed payload block at the end of the file.
Returns (payload_offset, payload_size).
Format: [Length: UInt32][CRC32c: UInt32][Raw bytes: length...]
"""
function append_payload(io::IO, data::Vector{UInt8})::Tuple{UInt64, UInt32}
    seekend(io)
    offset = UInt64(position(io))
    len = UInt32(length(data))
    chk = crc32c(data)
    
    write(io, len)
    write(io, chk)
    write(io, data)
    flush(io)
    
    return (offset, len)
end

"""
    read_payload(io::IO, offset::UInt64, size::UInt32)::Vector{UInt8}

Reads and verifies a payload block at offset.
Throws an error if CRC32c checksum does not match.
"""
function read_payload(io::IO, offset::UInt64, size::UInt32)::Vector{UInt8}
    seek(io, offset)
    len = read(io, UInt32)
    @assert len == size "Payload size mismatch at offset $offset: expected $size, found $len"
    chk_stored = read(io, UInt32)
    data = read(io, len)
    chk_computed = crc32c(data)
    @assert chk_stored == chk_computed "CRC32c checksum failed for payload at offset $offset"
    return data
end

"""
    write_codebooks(io::IO, codebooks::Vector{Vector{LorentzPoint}})::UInt64

Serializes the hierarchical codebooks table to disk. Returns byte offset.
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

Deserializes the codebook tables from disk at offset.
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

Writes a 64-byte TrieNode field-by-field.
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

Reads a 64-byte TrieNode field-by-field.
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

Serializes packed 64-byte trie nodes and child adjacency table to disk. Returns byte offset.
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

Deserializes packed 64-byte trie nodes and child adjacency table from disk.
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

Serializes the string key directory to disk. Returns byte offset.
"""
function write_key_directory(io::IO, key_to_node::Dict{String, Int})::UInt64
    seekend(io)
    offset = UInt64(position(io))
    count = UInt32(length(key_to_node))
    write(io, count)
    for (k, node_idx) in key_to_node
        k_bytes = codeunits(k)
        write(io, UInt16(length(k_bytes)))
        write(io, k_bytes)
        write(io, UInt32(node_idx))
    end
    flush(io)
    return offset
end

"""
    read_key_directory(io::IO, offset::UInt64)::Dict{String, Int}

Deserializes the string key directory from disk.
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
