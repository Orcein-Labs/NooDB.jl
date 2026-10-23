# NCD.jl - Binary File Format & Zero-Copy Mmap Module
# Manages .ncd on-disk layout, headers, codebook tables, and checksummed payloads

module Format

using Mmap
using CRC32c
using ..Lorentz
using ..Trie

export NCDHeader, NCD_MAGIC, NCD_VERSION, HEADER_SIZE,
       write_header, read_header, write_codebooks, read_codebooks,
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

end # module Format
