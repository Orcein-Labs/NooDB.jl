using Test
using NCD
using LinearAlgebra
using CRC32c

@testset "NCD.jl Verification Gauntlet" begin

    @testset "Gate 1: Cache-Line Alignment & Struct Sizing" begin
        # Node must be exactly 64 bytes to align with standard CPU cache line
        @test sizeof(TrieNode) == 64
        @test isbitstype(TrieNode) == true
        
        # Test node creation and field preservation
        pt = LorentzPoint((0.1f0, 0.2f0, 0.3f0, -0.1f0, 0.5f0))
        node = create_node(2, 5, pt; radius=0.45f0, flags=NODE_FLAG_LEAF, payload_offset=1024, payload_size=256)
        
        @test node.scale_level == 2
        @test node.code_id == 5
        @test node.flags == NODE_FLAG_LEAF
        @test node.payload_offset == 1024
        @test node.payload_size == 256
        @test node.cluster_radius == 0.45f0
        
        extracted_pt = get_lorentz_point(node)
        @test extracted_pt.x0 == pt.x0
        @test extracted_pt.x1 == pt.x1
        @test extracted_pt.x5 == pt.x5
    end

    @testset "Gate 2: Lorentz Hyperboloid Invariants & Metric Space" begin
        # 1. Hyperboloid invariant: <x, x>_L = -1.0 within Float32 machine precision
        for _ in 1:100
            sp = ntuple(_ -> Float32((rand() - 0.5) * 10.0), 5)
            p = LorentzPoint(sp)
            norm_sq = lorentz_norm_sq(p)
            @test abs(norm_sq + 1.0f0) < 5.0e-5
        end
        
        # 2. 20-byte spatial serialization & reconstruction roundtrip
        p_orig = LorentzPoint((1.5f0, -2.3f0, 0.7f0, 3.1f0, -0.4f0))
        sp_bytes = serialize_spatial(p_orig)
        @test sizeof(sp_bytes) == 20
        p_recon = deserialize_spatial(sp_bytes)
        @test p_recon.x0 ≈ p_orig.x0 atol=1e-6
        @test p_recon.x1 == p_orig.x1
        @test p_recon.x5 == p_orig.x5
        
        # 3. Metric space properties of lorentz_dist
        p1 = LorentzPoint((0.5f0, 0.0f0, 0.0f0, 0.0f0, 0.0f0))
        p2 = LorentzPoint((0.0f0, 0.5f0, 0.0f0, 0.0f0, 0.0f0))
        p3 = LorentzPoint((0.0f0, 0.0f0, 0.5f0, 0.0f0, 0.0f0))
        
        # Non-negativity & Identity of indiscernibles
        @test lorentz_dist(p1, p1) ≈ 0.0f0 atol=1e-6
        @test lorentz_dist(p1, p2) > 0.0f0
        
        # Symmetry
        @test lorentz_dist(p1, p2) ≈ lorentz_dist(p2, p1) atol=1e-6
        
        # Triangle inequality: d(p1, p3) <= d(p1, p2) + d(p2, p3)
        d13 = lorentz_dist(p1, p3)
        d12 = lorentz_dist(p1, p2)
        d23 = lorentz_dist(p2, p3)
        @test d13 <= d12 + d23 + 1e-5
        
        # High-dim projection
        v_high = randn(Float32, 768)
        p_proj = project_highdim_to_h5(v_high)
        @test abs(lorentz_norm_sq(p_proj) + 1.0f0) < 1.0e-5
    end

    @testset "Gate 3: Clifford Rotor Algebra & Spin(3) Dynamics" begin
        # 1. Identity rotor
        r_id = rotor_identity()
        v = (1.0f0, 2.0f0, -1.0f0)
        v_rot = rotor_sandwich(r_id, v)
        @test isapprox(v_rot[1], v[1]; atol=1e-6)
        @test isapprox(v_rot[2], v[2]; atol=1e-6)
        @test isapprox(v_rot[3], v[3]; atol=1e-6)
        
        # 2. Rotor reversion is inverse: R * ~R = 1
        r = CliffordRotor(0.8f0, 0.1f0, -0.3f0, 0.5f0)
        r_rev = rotor_reversion(r)
        r_prod = rotor_multiply(r, r_rev)
        @test r_prod.s ≈ 1.0f0 atol=1e-6
        @test abs(r_prod.b1) < 1e-6
        @test abs(r_prod.b2) < 1e-6
        @test abs(r_prod.b3) < 1e-6
        
        # 3. Vector rotation preserves Euclidean length
        rot_v = rotor_sandwich(r, v)
        @test (v[1]^2 + v[2]^2 + v[3]^2) ≈ (rot_v[1]^2 + rot_v[2]^2 + rot_v[3]^2) atol=1e-5
        
        # 4. Rotor between vectors: R rotates u to v
        u_vec = (1.0f0, 0.0f0, 0.0f0)
        v_vec = (0.0f0, 1.0f0, 0.0f0)
        r_uv = rotor_between(u_vec, v_vec)
        u_rotated = rotor_sandwich(r_uv, u_vec)
        @test u_rotated[1] ≈ 0.0f0 atol=1e-5
        @test u_rotated[2] ≈ 1.0f0 atol=1e-5
        @test u_rotated[3] ≈ 0.0f0 atol=1e-5
        
        # 5. Lorentz invariance under spatial rotor
        p = LorentzPoint((0.4f0, -0.6f0, 0.2f0, 0.8f0, -0.1f0))
        p_rot = apply_rotor(r, p)
        @test abs(lorentz_norm_sq(p_rot) + 1.0f0) < 1.0e-5
        @test p_rot.x0 ≈ p.x0 atol=1e-6  # Spatial norm preserved -> x0 invariant!
    end

    @testset "Gate 4: Binary Format & CRC32c Integrity" begin
        mktempdir() do tmpdir
            path = joinpath(tmpdir, "test_format.ncd")
            
            # Test header write & read
            io = Base.open(path, "w+")
            header_orig = NCDHeader(
                NCD_MAGIC, NCD_VERSION, 0x0, UInt16(4), UInt16(5),
                UInt32(10), UInt64(50), UInt64(128), UInt64(512),
                UInt64(1024), UInt64(2048), UInt64(4096)
            )
            write_header(io, header_orig)
            
            header_read = read_header(io)
            @test header_read.magic == NCD_MAGIC
            @test header_read.version == NCD_VERSION
            @test header_read.scale_depth_k == 4
            @test header_read.ambient_dim == 5
            @test header_read.total_nodes == 10
            @test header_read.total_records == 50
            
            # Test append & read payload with CRC32c
            data = codeunits("Hello, NCD high-efficiency concept database!")
            offset, sz = append_payload(io, collect(data))
            
            data_read = read_payload(io, offset, sz)
            @test data_read == collect(data)
            
            # Test corruption detection
            # Intentionally flip a bit in the payload data
            seek(io, offset + 8 + 3) # skip len (4) + crc (4) + 3 bytes
            orig_byte = read(io, UInt8)
            seek(io, offset + 8 + 3)
            write(io, orig_byte ⊻ 0xff)
            flush(io)
            
            @test_throws AssertionError read_payload(io, offset, sz)
            
            Base.close(io)
        end
    end

    @testset "Gate 5: Dual-Fidelity Database Engine Operations" begin
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "app.ncd")
            db = open_database(db_path; create=true)
            
            # 1. Standard Key-Value Operations
            put!(db, "user/matt", Dict("name" => "Matt C", "role" => "Chief Architect"))
            put!(db, "user/gemini", Dict("name" => "Gemini", "role" => "Research Engine"))
            put!(db, "config/cache_size", 4096)
            
            @test get(db, "user/matt")["role"] == "Chief Architect"
            @test get(db, "user/gemini")["role"] == "Research Engine"
            @test get(db, "config/cache_size") == 4096
            @test get(db, "nonexistent") === nothing
            
            # In-place update
            put!(db, "user/matt", Dict("name" => "Matt C", "role" => "Fellow Architect"))
            @test get(db, "user/matt")["role"] == "Fellow Architect"
            
            # Delete
            @test delete!(db, "config/cache_size") == true
            @test get(db, "config/cache_size") === nothing
            
            # 2. Semantic Search in H^5
            put!(db, "doc/quantum", "Quantum computing and topological qubits", concept="physics/quantum/topological")
            put!(db, "doc/superconductor", "High-Tc cuprate and hydride superconductors", concept="physics/quantum/superconductors")
            put!(db, "doc/culinary", "Classic French mother sauces and emulsion techniques", concept="cooking/french/sauces")
            
            results = near(db, "physics/quantum"; limit=2)
            @test length(results) == 2
            # Quantum and superconductor should be closer than culinary
            @test results[1].key in ["doc/quantum", "doc/superconductor"]
            
            # 3. Model-Native Latent Interface
            z_query = randn(Float32, 256)
            latent_results = query_latent(db, z_query; limit=1)
            @test length(latent_results) == 1
            @test latent_results[1].distance >= 0.0f0
            
            # 4. Clifford Rotor Between Concepts
            rotor = rotor_between(db, "doc/quantum", "doc/superconductor")
            @test abs(rotor.s^2 + rotor.b1^2 + rotor.b2^2 + rotor.b3^2 - 1.0f0) < 1e-5
            
            # Apply rotor to concept
            pt_q = get_lorentz_point(db.nodes[db.key_to_node["doc/quantum"]])
            pt_shifted = apply_rotor(rotor, pt_q)
            @test abs(lorentz_norm_sq(pt_shifted) + 1.0f0) < 1.0e-5
            
            close_database(db)
        end
    end

end
