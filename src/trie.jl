# NCD.jl - Multiscale Concept Radix Trie Module
# Implements cache-line aligned (64-byte) trie nodes and deterministic hierarchical traversal

module Trie

using ..Lorentz

export TrieNode, NODE_FLAG_LEAF, NODE_FLAG_PAYLOAD, NODE_FLAG_DELETED,
       create_node, get_lorentz_point, get_cluster_radius

const NODE_FLAG_LEAF     = 0x00000001
const NODE_FLAG_PAYLOAD  = 0x00000002
const NODE_FLAG_DELETED  = 0x00000004

"""
    TrieNode

Exactly 64-byte cache-line aligned struct for concept trie nodes.
Ordered to ensure zero compiler padding holes:
- 8-byte fields at offsets 0, 8 (16 bytes)
- 4-byte fields at offsets 16, 20 (8 bytes)
- 2-byte fields at offsets 24, 26, 28, 30 (8 bytes)
- 4-byte Float32 coords at offsets 32, 36, 40, 44, 48, 52 (24 bytes)
- 4-byte radius & padding at offsets 56, 60 (8 bytes)
Total = 64 bytes exactly.
"""
struct TrieNode
    child_offset::UInt64      # Offset 0..7: Byte offset or node index to children (8 bytes)
    payload_offset::UInt64    # Offset 8..15: Byte offset to raw payload data in .ncd (8 bytes)
    flags::UInt32             # Offset 16..19: Node status flags (4 bytes)
    payload_size::UInt32      # Offset 20..23: Payload length in bytes (4 bytes)
    scale_level::UInt16       # Offset 24..25: Scale level k in [0, K-1] (2 bytes)
    code_id::UInt16           # Offset 26..27: Centroid index in codebook C_k (2 bytes)
    child_count::UInt16       # Offset 28..29: Number of active child branches (2 bytes)
    reserved1::UInt16         # Offset 30..31: Alignment padding (2 bytes)
    x0::Float32               # Offset 32..35: Cached Lorentz x0 (4 bytes)
    x1::Float32               # Offset 36..39: Lorentz x1 (4 bytes)
    x2::Float32               # Offset 40..43: Lorentz x2 (4 bytes)
    x3::Float32               # Offset 44..47: Lorentz x3 (4 bytes)
    x4::Float32               # Offset 48..51: Lorentz x4 (4 bytes)
    x5::Float32               # Offset 52..55: Lorentz x5 (4 bytes)
    cluster_radius::Float32   # Offset 56..59: Cluster geodesic bounding radius R (4 bytes)
    reserved2::UInt32         # Offset 60..63: Alignment padding to reach 64 bytes (4 bytes)
end

"""
    create_node(scale_level, code_id, point::LorentzPoint; radius=0.0f0, flags=0x0, child_offset=0, child_count=0, payload_offset=0, payload_size=0)

Constructs a new 64-byte TrieNode with cached Lorentz coordinates.
"""
function create_node(
    scale_level::Integer,
    code_id::Integer,
    p::LorentzPoint;
    radius::Real = 0.0f0,
    flags::Integer = 0,
    child_offset::Integer = 0,
    child_count::Integer = 0,
    payload_offset::Integer = 0,
    payload_size::Integer = 0
)::TrieNode
    return TrieNode(
        UInt64(child_offset),
        UInt64(payload_offset),
        UInt32(flags),
        UInt32(payload_size),
        UInt16(scale_level),
        UInt16(code_id),
        UInt16(child_count),
        UInt16(0),
        p.x0, p.x1, p.x2, p.x3, p.x4, p.x5,
        Float32(radius),
        UInt32(0)
    )
end

@inline function get_lorentz_point(node::TrieNode)::LorentzPoint
    return LorentzPoint(node.x0, node.x1, node.x2, node.x3, node.x4, node.x5)
end

@inline function get_cluster_radius(node::TrieNode)::Float32
    return node.cluster_radius
end

end # module Trie
