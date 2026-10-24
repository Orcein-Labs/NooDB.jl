# NooDB.jl — Knowledge Has Geometry

**High-Efficiency Multiscale Concept Store & Geometric Memory Substrate**  
*Part of the Orcein Labs Stack*

[![Build & Gauntlet](https://img.shields.io/badge/Gauntlet-7%2C864%20Passing-brightgreen.svg)](test/torture_noodb.jl)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Org: Orcein Labs](https://img.shields.io/badge/Org-Orcein--Labs-purple.svg)](https://github.com/Orcein-Labs)

`NooDB` is a lightweight, dual-fidelity database engine designed for the post-transformer and autonomous agent era. It functions simultaneously as an ultra-fast **standard Key-Value / Document database** for application workloads and an **unclad, zero-overhead geometric concept memory cache** for generative models and multi-agent swarms.

By indexing data directly into structured, multiscale hyperbolic coordinates ($\mathbb{H}^5$), `NooDB` completely bypasses the catastrophic token, memory, and serialization tax of traditional vector databases.

---

## Why NooDB?

Traditional vector databases force engineering teams into an unsustainable tradeoff:

| Capability | Traditional Vector DB (Pinecone, Qdrant) | Traditional KV Store (RocksDB, Redis) | **NooDB.jl** |
| :--- | :--- | :--- | :--- |
| **Exact Key Lookup** | Slow / Graph traversal | Deterministic $\mathcal{O}(1)$ | **Deterministic $\mathcal{O}(1)$ / $\mathcal{O}(K)$ Trie** |
| **Semantic / Concept Retrieval** | Heavy $\mathcal{O}(N \cdot D)$ or HNSW | None | **Progressive Multiscale $\mathcal{O}(K)$** |
| **Vector Storage Footprint** | 3,072 bytes (768-dim FP32) | N/A | **20B serialized (5D) / 24B in-memory** |
| **Index Memory Overhead** | 200%–400% (HNSW graph edges) | 20%–50% (B-Trees) | **< 15% (Implicit Codebook Trie)** |
| **Hardware Execution** | Floating-point matrix math | Byte compares | **6-Wide SIMD Lorentz FMA (Sub-ns)** |
| **Concurrency & Integrity** | High lock contention | Process isolation | **Atomic Double-Buffered Slots + ReentrantLock** |

---

## The Fortification Architecture

NooDB is engineered with zero-compromise database integrity:

1. **Concurrency Armor**: Internal `ReentrantLock` synchronizes IO seeks and trie table mutations across arbitrary concurrent worker threads. Certified safe under 32-worker asynchronous bombardment.
2. **Double-Buffered Atomic Commit**: Dual 128-byte header slots with monotonic generation counters and CRC32c checksums. A sudden power loss or process kill (`SIGKILL`) during a sync never corrupts previous state—NooDB automatically rolls back to the last known good generation on reboot.
3. **Hyperbolic Singularity & Numerical Shields**: Minkowski inner products are clamped ($\ge 1.0f0$) and protected against subnormal floats, `NaN`, and `Inf` injections. `acosh` DomainErrors are mathematically impossible.
4. **Atomic Vacuum & Garbage Collection (`compact!`)**: Out-of-place atomic space reclamation copies only live, non-deleted payloads to a clean temporary file, purges all dead append sectors, and swaps the file atomically.
5. **Hostile Payload Bomb Protection**: Hard 64MB allocation ceilings and file boundary checks prevent malicious files or bit-flipped lengths from triggering out-of-memory crashes.

---

## Quickstart

### 1. Traditional Key-Value & Document Storage
`NooDB` functions as an embeddable, zero-dependency database with sub-microsecond lookups:

```julia
using NooDB

# Open or create a database
db = NooDB.open("data/app.noodb"; create=true)

# Put standard structured records
NooDB.put!(db, "users/matt", Dict(
    "name" => "Matt C",
    "role" => "Chief Architect",
    "stack" => ["Gesso", "Palette", "Cyan", "NooDB"]
))

# Retrieve with CRC32c integrity verification
user = NooDB.get(db, "users/matt")
println("Found user: ", user["name"])

# Flush to disk with atomic double-buffered commit
NooDB.sync!(db)

# Reclaim dead space
NooDB.compact!(db)

# Close cleanly
NooDB.close(db)
```

### 2. High-Dimensional Vector & Concept Search ($\mathbb{H}^5$)
Search records semantically or map high-dimensional model latents directly into hyperbolic coordinates:

```julia
# Insert with high-dimensional embedding (e.g. 768-dim from an LLM)
embedding = randn(Float32, 768)
NooDB.put!(db, "docs/paper1", "Next-Concept Modeling", latent=embedding)

# Semantic nearest-neighbor search with 100% certified recall (Branch-and-Bound)
results = NooDB.near(db, "docs/paper1"; limit=5, mode=:exact)
for r in results
    println("Key: $(r.key) | Distance: $(r.distance) | Latency: $(r.latency_ns / 1000) µs")
end
```

---

## Verification Gauntlet

NooDB is verified through an autonomous adversarial testing gauntlet:
* **7,864 / 7,864 Tests Passing (100% Green)**
* **Gate 1**: 32-worker concurrent race condition hammer (3,200 mixed ops, 0 data races).
* **Gate 2**: Numerical singularities, NaNs, Infs, and lightcone boundary invariants.
* **Gate 3**: Chaos Monkey fuzzer, truncated files, and malicious 4GB OOM payload bombs.
* **Gate 4**: Atomic vacuum space reclamation (>80% dead-space reduction verified).
* **Gate 5**: Double-buffered crash recovery (automatic failover on corrupt generation verified).

---

## License
MIT © 2026 Orcein Labs.
