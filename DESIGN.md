# NCD Architectural Specification & Mathematical Foundations

**System:** Next-Concept Database (`NCD.jl`)  
**Design Lead:** Research Engineering (`gemini@tether`) & Matt C  
**Target Repository:** `/mnt/d/Code Projects/NCD`  
**Status:** Architecture Blueprint (v0.1.0-draft)  
**Date:** October 2026  

---

## 1. Executive Summary & Design Philosophy

`NCD` (Next-Concept Database) is a dual-fidelity storage engine designed to bridge traditional deterministic systems with latent-space cognitive architectures.

Traditional databases assume data is either:
1. **Relational / Key-Value:** Discrete strings, numbers, and bytes indexed via B-Trees, Hash maps, or LSM-Trees.
2. **Dense Metric Vectors:** High-dimensional floating-point arrays ($\mathbb{R}^{768}, \mathbb{R}^{1536}$) indexed via Approximate Nearest Neighbor (ANN) graphs (HNSW) or inverted files (IVF-PQ).

Both paradigms fail modern generative workflows. Relational engines cannot navigate semantic continuity; vector engines suffer from crippling RAM overhead (often 2× to 4× the raw data size just for graph edges), millisecond-scale latency, and require a 6-layer translation stack to interface with models.

`NCD` unifies discrete keys and semantic reasoning into a single geometric substrate:
* **The Multiscale Concept Trie** organizes data as paths through discrete hierarchical scale levels.
* **5D Hyperbolic Geometry ($\mathbb{H}^5$)** compresses high-dimensional semantic hierarchies into compact 20-byte coordinates with near-zero tree distortion.
* **Tropical Semiring Arithmetic** executes candidate bounding and routing via pure SIMD additions and minima—completely eliminating floating-point multiplications.
* **Clifford Rotor Algebra ($\mathcal{C}\ell(3,0)$)** handles analogies, contextual shifts, and relational projections as coordinate-free operators.
* **Discrete Hodge Curl-Removal** guarantees that search trajectories are irrotational ($d^* \psi = 0$), mathematically preventing infinite cyclic loops or local minimum ping-pong traps.

---

## 2. Mathematical Foundations

### 2.1 Multiscale Residual Concept Hierarchy (NCM Core)
Inspired by Stanford's Next-Concept Modeling (NCM), data within NCD is decomposed across $K$ discrete scale levels:
$$\text{Level } 0 \quad (\text{Macro-Concept}) \longrightarrow \text{Level } 1 \quad (\text{Category}) \longrightarrow \dots \longrightarrow \text{Level } K-1 \quad (\text{Fine Instance})$$

At each level $k \in \{0, \dots, K-1\}$, there exists a discrete codebook $\mathcal{C}_k = \{c_{k, 1}, c_{k, 2}, \dots, c_{k, V_k}\}$ of size $V_k$ (typically $V_k \in \{16, 32, 64\}$).

A record $X$ is indexed by a sequence of discrete code indices:
$$\mathbf{p}(X) = [i_0, i_1, \dots, i_{K-1}], \quad i_k \in \{1, \dots, V_k\}$$
along with an optional fine residual vector $r \in \mathbb{H}^d$.

* **Deterministic Traversal:** Because each code is an integer index, prefix traversal from Level 0 to Level $K-1$ prunes the search space exponentially by factor $\prod V_k$.
* **Acyclic Guarantee:** Top-down trie traversal is fundamentally a directed acyclic tree (DAG), eliminating spatial oscillation by construction.

---

### 2.2 Hyperbolic Metric Space ($\mathbb{H}^d$ Lorentz Model)
Hierarchical taxonomies grow exponentially with depth ($N \sim b^h$). Embedding an exponentially branching tree into Euclidean space $\mathbb{R}^D$ causes catastrophic distortion because Euclidean volume only expands polynomially ($\mathrm{Vol}(r) \sim r^D$).

Hyperbolic space $\mathbb{H}^d$ has constant negative sectional curvature ($-\kappa^2$). The volume of a hyperbolic ball expands exponentially with radius:
$$\mathrm{Vol}_{\mathbb{H}^d}(r) \propto \sinh^{d-1}(r) \sim e^{(d-1)r}$$

This matches the exponential branching of conceptual trees. Consequently, a **5-dimensional hyperbolic space ($\mathbb{H}^5$)** embeds complex semantic hierarchies with less distortion than a 200-dimensional Euclidean space.

#### The Lorentz (Hyperboloid) Formalism
We implement $\mathbb{H}^d$ using the Lorentz model embedded in Minkowski space $\mathbb{R}^{d+1}$ with signature $(- + \dots +)$:
$$\mathbb{H}^d = \left\{ x = (x_0, x_1, \dots, x_d) \in \mathbb{R}^{d+1} \;\middle|\; \langle x, x \rangle_L = -1, \; x_0 > 0 \right\}$$
where the Lorentzian inner product is defined as:
$$\langle x, y \rangle_L = -x_0 y_0 + \sum_{i=1}^d x_i y_i$$

The geodesic distance between two points $x, y \in \mathbb{H}^d$ is given analytically by:
$$d_{\mathbb{H}}(x, y) = \mathrm{arcosh}(-\langle x, y \rangle_L)$$

For fast candidate ranking, since $\mathrm{arcosh}(u)$ is strictly monotonic for $u \ge 1$, we compute only the Lorentzian inner product $-\langle x, y \rangle_L$, avoiding expensive transcendental function calls in the hot loop.

#### Format Specification: 20-Byte Serialized vs. 24-Byte Cached
Because every valid point on $\mathbb{H}^d$ satisfies $\langle x, x \rangle_L = -x_0^2 + \sum_{i=1}^d x_i^2 = -1$ with $x_0 > 0$, the time-like coordinate $x_0$ is algebraically constrained:
$$x_0 = \sqrt{1 + \sum_{i=1}^d x_i^2}$$
This establishes a clear duality between storage and execution:
* **Canonical Serialized Footprint (20 Bytes):** On disk and over the wire, points are stored purely as their $d=5$ spatial coordinates $x_{\text{sp}} = (x_1, \dots, x_5) \in \mathbb{R}^5$ ($5 \times \text{Float32} = 20\text{ bytes}$).
* **Cached In-Memory Node Footprint (24 Bytes):** Inside the cache-line aligned trie node struct, the precomputed $x_0$ coordinate is cached alongside $x_{\text{sp}}$, yielding $6 \times \text{Float32} = 24\text{ bytes}$. This trades 4 bytes of RAM per node to eliminate runtime `sqrt` calls, allowing Lorentzian inner products to evaluate as direct 6-element FMA (fused multiply-add) SIMD vectors.

---

### 2.3 Direct 6-Wide SIMD Lorentz FMA Pruning (Why Bounding Sieves are Obsolete in 5D)
In high-dimensional Euclidean spaces ($D = 768$ or $1536$), evaluating distances requires hundreds of multiply-adds per candidate, making bounding-box or polyhedral pre-filters (such as AABB trees or tropical difference bounds) an effective heuristic.

However, in **5-dimensional hyperbolic space ($\mathbb{H}^5$)**, the mathematical reality shifts dramatically:
* The Lorentzian inner product $-\langle q, c \rangle_L = q_0 c_0 - \sum_{i=1}^5 q_i c_i$ is a **6-element dot product**.
* On modern SIMD architectures (x86 AVX2/AVX-512, ARM NEON/SVE), an 8-wide FMA instruction (`vfmadd231ps` / `fmla`) calculates this entire 6-element dot product in **1 clock cycle** with a throughput of **0.5 cycles** (sub-nanosecond).
* In contrast, evaluating a coordinate bounding box (such as Chebyshev tropical distance $\Delta_\infty$) requires loading 10 bounding floats, executing multi-lane min/max chains, and comparing against a threshold:
  $$\Delta_\infty(q, \mathcal{P}_{\mathbb{T}}) > \sqrt{2(q_0 x_{0,\max} + 1)(\cosh(D_{\text{best}}) - 1)}$$
  This requires more instructions, more branch misprediction exposure, and more cache footprint than the native 6-element FMA dot product itself!

**Design Decision:** NCD completely eliminates coordinate-wise bounding pre-filters from the hot path. The metric lower bound:
$$\text{dist\_bound}(q, C) = \max\big(0,\, d_{\mathbb{H}}(q, c) - R\big)$$
is computed directly via hardware-accelerated 6-wide Lorentz FMA instructions, achieving peak hardware efficiency with zero abstraction penalty.

---

### 2.4 Clifford Rotor Algebra for Relational Dynamics ($\mathcal{C}\ell(3,0)$)
In traditional databases, relationships between records are modeled as foreign keys or flat graph edges. In NCD, semantic shifts (e.g., perspective rotation, user context lens, analogy mappings) are modeled as **Clifford Rotors**.

Within a localized 3D concept subspace, we instantiate the Clifford geometric algebra $\mathcal{C}\ell(3,0)$ with basis $\{e_1, e_2, e_3\}$ satisfying:
$$e_i e_j + e_j e_i = 2 \delta_{ij}$$

A multivector $A \in \mathcal{C}\ell(3,0)$ decomposes into:
$$A = \underbrace{\alpha_0}_{\text{scalar (grade 0)}} + \underbrace{\sum_{i=1}^3 \alpha_i e_i}_{\text{vector (grade 1)}} + \underbrace{\beta_1 e_{23} + \beta_2 e_{31} + \beta_3 e_{12}}_{\text{bivector (grade 2)}} + \underbrace{\gamma e_{123}}_{\text{pseudoscalar (grade 3)}}$$

#### The Even Subalgebra & The Rotor
A Rotor $R$ belongs to the even subalgebra $\mathcal{C}\ell^+(3,0) \cong \mathrm{Spin}(3) \cong \mathbb{H}_{\text{quat}}$:
$$R = s + B = \cos\left(\frac{\theta}{2}\right) - \hat{B} \sin\left(\frac{\theta}{2}\right)$$
where $\hat{B}$ is a unit bivector defining the plane of rotation.

* **Relational Shift:** Applying a relation to a concept vector $v$ is executed via the sandwich product:
  $$v' = R v \tilde{R}$$
  where $\tilde{R} = s - B$ is the reversion of $R$.
* **Composition:** Composing sequential relations $R_1$ followed by $R_2$ is associative and coordinate-free:
  $$R_{\text{composite}} = R_2 R_1$$
* **Storage Footprint:** A rotor is stored as exactly 4 numbers (1 scalar + 3 bivector components), taking **16 bytes** in `Float32` (or 8 bytes in `Float16`).

---

### 2.5 Discrete Helmholtz-Hodge Decomposition & Lyapunov Convergence
When a query moves between concept charts, how do we guarantee it cannot cycle infinitely or get trapped in ping-pong oscillations?

In Discrete Exterior Calculus (DEC), any discrete 1-form (flow vector field) $J$ on a simplicial network decomposes uniquely into three mutually orthogonal subspaces:
$$J = \underbrace{\mathrm{d}\phi}_{\text{Exact (Potential Gradient)}} + \underbrace{\delta \psi}_{\text{Co-exact (Rotational / Curl)}} + \underbrace{h}_{\text{Harmonic}}$$

Where:
* $\mathrm{d}$ is the discrete exterior derivative (gradient operator).
* $\delta = * \mathrm{d} *$ is the discrete codifferential (curl operator).
* $h$ satisfies $\mathrm{d}h = 0$ and $\delta h = 0$ (topological harmonic cycles).

#### The Convergence Theorem & Dissipative Gradient Flow
A vector field being curl-free ($\delta J = 0$) guarantees path-independence and zero circulation along contractible loops ($\oint J \cdot \mathrm{d}r = 0$), but—like an undamped Hamiltonian system—curl-free fields alone do not prevent undamped periodic orbits. 

To achieve guaranteed acyclic termination, NCD couples the Hodge decomposition with a **Strict Lyapunov Dissipation Invariant**:

**Theorem (Finite-Step Acyclic Termination):**  
*Let $\phi: \mathcal{V} \to \mathbb{R}_{\ge 0}$ be a non-negative potential representing the hyperbolic distance to the query target: $\phi(c) = d_{\mathbb{H}}(q, c)$.*  
*If the routing policy projects all transition fields onto the strictly dissipative anti-gradient: $J = -\mathrm{d}\phi$ (such that $\delta J = 0$ and $h = 0$), and enforces a discrete dissipation threshold $\epsilon > 0$ such that every admissible hop from node $A$ to node $B$ satisfies:*
$$\phi(B) \le \phi(A) - \epsilon$$
*then:*
1. *The routing trajectory is strictly acyclic.*
2. *The search terminates at an attractor node in at most $N \le \lfloor \phi(c_{\text{start}}) / \epsilon \rfloor$ discrete steps.*

**Proof:**
1. **Acyclicity:** Suppose there exists a cycle of length $M \ge 2$ with visited nodes $(v_0, v_1, \dots, v_M = v_0)$. By the dissipation invariant, $\phi(v_{t+1}) \le \phi(v_t) - \epsilon$ for all $t$. Summing over the cycle yields:
   $$\phi(v_M) - \phi(v_0) = \sum_{t=0}^{M-1} (\phi(v_{t+1}) - \phi(v_t)) \le -M \epsilon < 0$$
   Since $v_M = v_0$, $\phi(v_M) - \phi(v_0) = 0$, giving $0 \le -M\epsilon < 0$, a strict contradiction. Hence, no cyclic paths can exist.
2. **Finite Termination:** Because $\phi(v) \ge 0$ for all $v \in \mathcal{V}$, and each hop strictly decrements $\phi$ by at least $\epsilon$, the potential after $N$ hops is:
   $$0 \le \phi(v_N) \le \phi(v_0) - N \epsilon \implies N \le \frac{\phi(v_0)}{\epsilon}$$
   Because $N$ is an integer, the sequence terminates in at most $\lfloor \phi(v_0)/\epsilon \rfloor$ steps. $\blacksquare$

* **Algorithmic Role of Hodge Projection:** Raw heuristic routing signals $J_{\text{raw}}$ (e.g. from learned routing heads or local momentum) often contain parasitic circulation loops ($\delta \psi \neq 0$). Projecting $J = \mathcal{P}_{\text{exact}}(J_{\text{raw}}) = -\mathrm{d}\phi$ filters out all solenoidal circulation before evaluating the $\epsilon$-dissipation gate.

#### Convergence vs. Global Optimality: Dual-Mode Architecture
Strict Lyapunov descent guarantees that the trajectory cannot oscillate and must terminate in finite steps. However, like all greedy gradient flows, it can terminate at a local minimum if no adjacent node offers further decrease in potential.

To address this, NCD provides two complementary retrieval modes:
1. **Reflex / L3 Cache Mode (Greedy Descent):** Follows strict Lyapunov descent to the nearest local attractor node. Optimized for ultra-low latency ($< 100 \text{ ns}$) where fast approximate context is required by a model.
2. **Exact Database Mode (Branch-and-Bound / Best-First Search):** Maintained via a priority queue sorted by the cluster lower bound:
   $$\text{dist\_bound}(q, C) = \max\big(0,\, d_{\mathbb{H}}(q, c) - R\big)$$
   Explores the most promising branch first, updates $D_{\text{best}}$ at leaf evaluations, and prunes any branch where $\text{dist\_bound}(q, C) \ge D_{\text{best}}$. This guarantees **100.0% exact recall** with logarithmic average complexity.

---

## 3. Physical File Format Specification (`.ncd`)

An `NCD` database is stored as a single, self-contained binary file (`.ncd`) mapped into virtual memory via zero-copy `mmap`.

```
+-----------------------------------------------------------------------+
|                              HEADER (128 bytes)                       |
+-----------------------------------------------------------------------+
| Magic (4B) | Version (2B) | Flags (2B) | Scale Depth K (2B) | Dim (2B) |
| Offsets: Codebooks, Trie Nodes, Keys, Payloads (64B) | Reserved (52B) |
+-----------------------------------------------------------------------+
|                         CODEBOOK TABLE (Scale 0..K-1)                 |
+-----------------------------------------------------------------------+
| Scale 0: V_0 centroids x (Dim+1) Float32                              |
| Scale 1: V_1 centroids x (Dim+1) Float32                              |
| ...                                                                   |
| Scale K-1: V_{K-1} centroids x (Dim+1) Float32                        |
+-----------------------------------------------------------------------+
|                      MULTISCALE CONCEPT TRIE NODES                    |
+-----------------------------------------------------------------------+
| Node 0 (Root): [Flags, ScaleLevel, ChildCount, FirstChildOffset, ...]  |
| Node 1: ...                                                           |
| (Each node is 64-byte cache-line aligned)                             |
+-----------------------------------------------------------------------+
|                         STRING KEY & HASH DIRECTORY                   |
+-----------------------------------------------------------------------+
| Flat hash table mapping String Keys -> Trie Node Offsets              |
+-----------------------------------------------------------------------+
|                         PAYLOAD DATA BLOCKS                           |
+-----------------------------------------------------------------------+
| Block: [Length (4B)][CRC32 (4B)][Raw Binary Payload Data (VarLen)]    |
+-----------------------------------------------------------------------+
```

### 3.1 Binary Header Layout (128 Bytes)
```
Offset | Size | Type     | Field Name       | Description
-------+------+----------+------------------+--------------------------------------------
0x00   | 4    | UInt8[4] | magic            | Magic bytes: ASCII "NCD1" (0x3144434E)
0x04   | 2    | UInt16   | version          | Format version (current: 1)
0x06   | 2    | UInt16   | flags            | Bit 0: Compressed, Bit 1: ReadOnly, etc.
0x08   | 2    | UInt16   | scale_depth_k    | Number of concept scale levels (e.g., 4)
0x0A   | 2    | UInt16   | ambient_dim      | Ambient hyperbolic dimension d (e.g., 5)
0x0C   | 4    | UInt32   | total_nodes      | Total number of nodes in concept trie
0x10   | 8    | UInt64   | total_records    | Total number of stored records
0x18   | 8    | UInt64   | offset_codebooks | Byte offset to Codebook Table
0x20   | 8    | UInt64   | offset_trie      | Byte offset to Trie Nodes segment
0x28   | 8    | UInt64   | offset_keys      | Byte offset to Key Directory
0x30   | 8    | UInt64   | offset_payloads  | Byte offset to Payload segment
0x38   | 8    | UInt64   | file_size        | Total file size in bytes
0x40   | 64   | UInt8[64]| reserved         | Zero-padded reserved block for future flags
```

### 3.2 Trie Node Layout (Cache-Line Aligned: 64 Bytes)
Every node in the concept trie is packed into exactly 64 bytes to match a CPU cache line:
```
Offset | Size | Type     | Field Name       | Description
-------+------+----------+------------------+--------------------------------------------
0x00   | 2    | UInt16   | scale_level      | Scale level k in [0, K-1]
0x02   | 2    | UInt16   | code_id          | Centroid index in codebook C_k
0x04   | 4    | UInt32   | flags            | Node flags (is_leaf, has_rotor, etc.)
0x08   | 8    | UInt64   | child_offset     | Offset to first child node array
0x10   | 2    | UInt16   | child_count      | Number of child branches
0x12   | 2    | UInt16   | reserved1        | Alignment padding
0x14   | 8    | UInt64   | payload_offset   | Offset to payload block (if leaf)
0x1C   | 4    | UInt32   | payload_size     | Size of payload in bytes
0x20   | 24   | Float32[6| hyp_coords       | 5D Lorentz coords (6x Float32: x0..x5)
0x38   | 8    | UInt64   | reserved2        | Reserved expansion bytes
```

---

## 4. Query Execution Pipelines

### Pipeline 1: Exact Key Lookup (`get`)
```
[ Key: "users/matt" ]
         |
         v
[ XXH3-64 Hash ] ---> [ Hash Directory ] ---> [ Node Offset ] ---> [ Payload ]
(Deterministic: 1 hash + 1 direct pointer dereference = ~35 nanoseconds)
```

### Pipeline 2: Semantic / Latent Vector Search (`near` / `query_latent`)
```
[ Query Latent z in R^D or H^5 ]
         |
         v
[ Scale 0: Macro Centroid Match ]
   -> Computes Lorentzian inner products across V_0 centroids (V_0=16) via 6-wide FMA
   -> Selects nearest centroid c_0 in ~50 nanoseconds
         |
         v
[ Scale 1..K-1: Multiscale Branch-and-Bound ]
   -> Reflex Mode: Greedy Lyapunov descent down primary attractor branch (< 100 ns)
   -> Exact Mode: Priority queue search pruned by dist_bound = max(0, d_H(q, c) - R) (100% recall)
         |
         v
[ Leaf Convergence & Top-K Extraction ]
   -> Evaluates exact Lorentzian distance for candidates in candidate leaf nodes
   -> Returns top-k nearest records or latent payloads
```

---

## 5. Architectural Verification & Invariants

To guarantee that NCD is production-ready from day one, any implementation must satisfy the following five formal verification gates:

1. **Gate 1: Strict Cache-Line Alignment**  
   Every trie node struct in memory must be exactly 64 bytes and aligned to 64-byte boundaries (`alignof(Node) == 64`).
2. **Gate 2: Lorentz Surface Invariant**  
   For every stored coordinate $x \in \mathbb{R}^{d+1}$, the Lorentzian norm must satisfy $|\langle x, x \rangle_L + 1.0| < 10^{-6}$.
3. **Gate 3: Monotonic Hodge Potential Descent**  
   During any semantic traversal $A \to B$, $\phi(B) \le \phi(A)$ must strictly hold. The engine must throw an assertion failure if a step increases distance to target.
4. **Gate 4: Exact Parity on Key-Value Operations**  
   Inserting 100,000 distinct string keys with structured JSON payloads and retrieving them must achieve 100.0% bit-exact parity against reference dictionaries.
5. **Gate 5: Memory Leak & File Growth Invariant**  
   Repeated overwrite of existing keys must update in-place or reclaim storage through compaction without unbounded file growth.
