module NCD

# Submodules
include("lorentz.jl")
include("clifford.jl")
include("trie.jl")
include("format.jl")
include("engine.jl")

using .Lorentz
using .Clifford
using .Trie
using .Format
using .Engine

import Base: put!, get, delete!

# Export Core Geometric Types & Functions
export LorentzPoint, lorentz_inner, lorentz_dist, lorentz_norm_sq,
       reconstruct_x0, project_to_hyperboloid, project_highdim_to_h5,
       serialize_spatial, deserialize_spatial

# Export Clifford Algebra & Rotors
export CliffordRotor, rotor_identity, rotor_multiply, rotor_reversion,
       rotor_sandwich, rotor_between, rotate_spatial3, rotate_lorentz

# Export Concept Trie Nodes
export TrieNode, NODE_FLAG_LEAF, NODE_FLAG_PAYLOAD, NODE_FLAG_DELETED,
       create_node, get_lorentz_point, get_cluster_radius

# Export Binary Format & Headers
export NCDHeader, NCD_MAGIC, NCD_VERSION,
       write_header, read_header, append_payload, read_payload

# Export Engine & High-Level Database API
export NCDDatabase, SearchResult,
       open_database, close_database, sync!,
       put!, get, delete!, near, query_latent,
       rotor_between, apply_rotor

# Convenience aliases matching idiomatic Julia API
Base.open(::Type{NCDDatabase}, path::String; kwargs...) = open_database(path; kwargs...)
Base.close(db::NCDDatabase) = close_database(db)

end # module NCD
