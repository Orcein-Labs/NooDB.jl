# NCD.jl: Next-Concept Database

**High-Efficiency Multiscale Concept Store & Geometric Memory Substrate**

`NCD` (Next-Concept Database) is a lightweight, ultra-fast, dual-fidelity database engine designed for the post-transformer era. It functions seamlessly as a high-performance **standard Key-Value / Document database** for application workloads, while simultaneously serving as a **zero-overhead, native concept memory cache** for generative models and cognitive architectures.

Part of the **Orcein Stack**, `NCD` eliminates the costly "token and serialization tax" of modern vector databases by storing data directly in structured, multiscale concept coordinates.

---

## Why NCD?

Traditional databases force a painful tradeoff:
* **Relational / KV Stores (RocksDB, SQLite, Redis):** Fast and deterministic for exact keys, but completely blind to semantics, concepts, and high-dimensional relationships.
* **Vector Databases (Pinecone, Qdrant, Milvus):** Enable similarity search, but suffer from **massive memory overhead** (HNSW graph indexes often take 2×–4× the memory of the raw vectors), high query latencies, and an awkward 6-step translation pipeline (`Model Latent → Tokens → Text → Embedder API → Vector DB → Retokenize → Context Window`).

`NCD` unifies both worlds through **geometric concept indexing**:

| Capability | Traditional Vector DB | Traditional KV Store | **NCD.jl** |
| :--- | :--- | :--- | :--- |
| **Exact Key Lookup** | Slow / Hacky | Deterministic $\mathcal{O}(1)$ | **Deterministic $\mathcal{O}(1)$ / $\mathcal{O}(K)$ Trie** |
| **Semantic / Concept Retrieval** | Heavy $\mathcal{O}(N \cdot D)$ or HNSW | None | **Progressive Multiscale $\mathcal{O}(K)$** |
| **Model Latent Integration** | Broken (Requires text/tokens) | None | **Native L3 Concept Cache** |
| **Index Memory Overhead** | 200%–400% (HNSW edges) | 20%–50% (B-Trees) | **< 15% (Implicit Codebook Trie)** |
| **Vector Storage Footprint** | 3,072 bytes (768-dim FP32) | N/A | **20B serialized (5D) / 24B in-memory** |
| **Hardware Execution** | Floating-point matrix math | Byte compares | **6-Wide SIMD Lorentz FMA (Sub-ns)** |

---

## Core Innovations

1. **Multiscale Residual Concept Hierarchy:**  
   Inspired by Stanford's Next-Concept Modeling (NCM), data is organized across discrete hierarchical scale levels (Macro-Concept $\to$ Category $\to$ Sub-concept $\to$ Leaf). Pruning is logarithmic, deterministic, and acyclic.
2. **5D Hyperbolic Coordinate Embeddings ($\mathbb{H}^5$):**  
   Tree structures grow exponentially. Because hyperbolic space has exponential volume expansion, a 5-dimensional Lorentz space embeds complex hierarchical taxonomies with near-zero distortion. Points are stored in **20 bytes** serialized ($5 \times \text{Float32}$ spatial coordinates) and cached in **24 bytes** ($6 \times \text{Float32}$ including constrained time-like coordinate $x_0 = \sqrt{1 + \|x\|^2}$) for zero-overhead FMA inner products.
3. **Direct 6-Wide SIMD Lorentz FMA Pruning:**  
   Because $d=5$, Lorentzian inner products evaluate in a single clock cycle via 6-element FMA instructions (`vfmadd231ps` / `fmla`), eliminating the need for clumsy bounding-box pre-filters and running at hardware line rate.
4. **Clifford Rotor Relational Operators ($\mathcal{C}\ell(3,0)$):**  
   Semantic shifts, perspectives, and analogies are encoded as compact 8-component Clifford Rotors ($\mathrm{Spin}(3)$). Relationships compose seamlessly via rotor multiplication without coordinate drift or gimbal lock.
5. **Acyclic Hodge & Lyapunov Dissipation Invariant:**  
   By projecting transition flows onto curl-free exact potential gradients ($\delta J = 0$) and enforcing strict Lyapunov potential dissipation ($\phi(B) \le \phi(A) - \epsilon$), infinite search ping-pong loops are mathematically impossible. Exact recall is guaranteed via priority-queue Branch-and-Bound.

---

## Quickstart

### 1. Traditional Key-Value & Document Storage
`NCD` functions as an embeddable, zero-dependency database with sub-microsecond lookups:

```julia
using NCD

# Open or create a database
db = NCD.open("data/app.ncd"; create=true)

# Put standard structured records
NCD.put!(db, "users/matt", Dict(
    "name" => "Matt C",
    "role" => "Chief Architect",
    "stack" => ["Gesso", "PSNCM", "TTMetalium", "NCD"]
))

# Retrieve by exact key
record = NCD.get(db, "users/matt")
println(record["role"])  # "Chief Architect"
```

### 2. Semantic & Concept Retrieval
Store items with concept tags or high-dimensional embeddings. `NCD` projects them into compact 5D hyperbolic coordinates and indexes them along the multiscale trie:

```julia
# Insert items with semantic context
NCD.put!(db, "articles/superconductors", 
    "Room-temperature ambient pressure hydride synthesis",
    concept="physics/condensed-matter/superconductivity"
)

# Semantic search: finds nearest concepts in hyperbolic space
results = NCD.near(db, "physics/condensed-matter", limit=5)
for res in results
    println("$(res.key) (distance: $(res.dist))")
end
```

### 3. Native Model Latent Cache (Zero-Impedance)
AI models can query `NCD` directly using raw continuous latent vectors or discrete concept code prefixes:

```julia
# Model passes a raw latent state z (e.g. from a reasoning step)
z_latent = randn(Float32, 256)

# Query directly in latent space without text serialization
concept_path, payload = NCD.query_latent(db, z_latent)

# Or perform an analogical relationship shift via a Clifford Rotor
R_shift = NCD.rotor_between(db, "theory", "hardware_impl")
shifted_concept = NCD.apply_rotor(R_shift, concept_path)
```

---

## Repository Structure

```
NCD/
├── README.md               # You are here
├── DESIGN.md               # Detailed architectural specification & math proofs
├── Project.toml            # Julia package metadata
├── src/
│   ├── NCD.jl              # Main module entry point & public API
│   ├── format.jl           # .ncd binary layout & zero-copy mmap parser
│   ├── trie.jl             # Multiscale Concept Radix Trie
│   ├── hyperbolic.jl       # 5D Lorentz space metrics & projection
│   ├── tropical.jl         # Min-Plus SIMD arithmetic & polyhedral bounds
│   ├── clifford.jl         # Cl(3,0) rotor algebra & relational operators
│   └── engine.jl           # Unified storage engine & query dispatch
└── test/
    └── runtests.jl         # Verification test suite & benchmark gates
```

---

## Architectural Deep Dive

For the complete mathematical formalism, binary file format specifications, and memory invariants, see **[`DESIGN.md`](DESIGN.md)**.
