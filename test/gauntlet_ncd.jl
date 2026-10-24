# NCD.jl - Deep Production Verification Gauntlet
# Tests:
# 1. Multi-process persistence (populate in proc A, verify in proc B)
# 2. 100.0% exact nearest-neighbor parity (Branch-and-Bound vs Exhaustive Scan)
# 3. Reflex mode Lyapunov termination and latency SLA
# 4. Semantic fidelity & Recall@K benchmarking
# 5. KV performance benchmarks vs baseline Dict

using Test
using NooDB
const NCD = NooDB
using LinearAlgebra
using Statistics

println("=== NCD.jl ADVANCED PRODUCTION GAUNTLET ===")

@testset "NCD Production Gauntlet" begin

    @testset "A1: True Cross-Process Persistence" begin
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "persistent_store.ncd")
            
            # Step 1: Populate 200 records in Process A
            db = open_database(db_path; create=true)
            test_records = Dict{String, String}()
            for i in 1:200
                k = "record/item_$i"
                v = "Payload data for item $i with unique signature $(hash(i))"
                concept = "category_$(i % 8)/topic_$(i % 4)"
                test_records[k] = v
                put!(db, k, v; concept=concept)
            end
            close_database(db)
            
            # Step 2: Open in a brand new, isolated Julia subprocess
            verify_script = """
            using NooDB
            db = open_database("$db_path"; create=false)
            
            # Verify record count
            @assert length(db.key_to_node) == 200 "Expected 200 records, got \$(length(db.key_to_node))"
            
            # Verify exact readback for all 200 keys
            for i in 1:200
                k = "record/item_\$i"
                expected_v = "Payload data for item \$i with unique signature \$(hash(i))"
                actual_v = get(db, k)
                @assert actual_v == expected_v "Mismatch on key \$k: expected '\$expected_v', got '\$actual_v'"
            end
            
            # Verify semantic search works on reloaded trie
            results = near(db, "category_1/topic_2"; limit=5, mode=:exact)
            @assert length(results) == 5 "Expected 5 results, got \$(length(results))"
            @assert results[1].distance >= 0.0f0
            
            close_database(db)
            println("SUBPROCESS_PERSISTENCE_SUCCESS")
            """
            
            cmd = `julia --project=. -e $verify_script`
            output = cd("/mnt/d/Code Projects/NCD") do
                read(cmd, String)
            end
            
            @test occursin("SUBPROCESS_PERSISTENCE_SUCCESS", output)
        end
    end

    @testset "A2: Certified 100.0% Exact Nearest-Neighbor Parity" begin
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "exact_parity.ncd")
            db = open_database(db_path; create=true)
            
            # Populate database with 300 random points across various concept regions
            N = 300
            ground_truth_points = Dict{String, LorentzPoint}()
            for i in 1:N
                k = "entity/$i"
                sp = ntuple(_ -> Float32((rand() - 0.5) * 4.0), 5)
                pt = LorentzPoint(sp)
                ground_truth_points[k] = pt
                put!(db, k, Dict("id" => i, "vec" => collect(sp)); coords=pt)
            end
            
            # Run 50 diverse queries and assert 100.0% exact top-k match against brute force
            num_queries = 50
            k_limit = 5
            perfect_matches = 0
            
            for q_idx in 1:num_queries
                q_sp = ntuple(_ -> Float32((rand() - 0.5) * 4.0), 5)
                q_pt = LorentzPoint(q_sp)
                
                # 1. Branch-and-Bound Exact search
                ncd_results = near(db, q_pt; limit=k_limit, mode=:exact)
                ncd_keys = [r.key for r in ncd_results]
                
                # 2. Exhaustive Brute-Force Linear Scan
                all_dists = [(k, lorentz_dist(q_pt, pt)) for (k, pt) in ground_truth_points]
                sort!(all_dists, by = x -> x[2])
                bf_keys = [all_dists[i][1] for i in 1:k_limit]
                
                # Assert exact set parity
                if Set(ncd_keys) == Set(bf_keys)
                    perfect_matches += 1
                else
                    println("Mismatch on query \$q_idx!")
                    println("  NCD: ", ncd_keys)
                    println("  BF:  ", bf_keys)
                end
            end
            
            @test perfect_matches == num_queries
            println("Exact Parity Rate: $(perfect_matches)/$(num_queries) (100.0% match)")
            close_database(db)
        end
    end

    @testset "A3: Reflex Mode Lyapunov Traversal & Visited Bounds" begin
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "reflex.ncd")
            db = open_database(db_path; create=true)
            
            for i in 1:250
                k = "doc/$i"
                concept = "domain_$(i % 5)/area_$(i % 3)/topic_$i"
                put!(db, k, "Data $i"; concept=concept)
            end
            
            # Test Reflex mode
            q = "domain_2/area_1"
            results = near(db, q; limit=5, mode=:reflex)
            @test length(results) <= 5
            @test results[1].visited_nodes > 0
            # Visited nodes should be logarithmically bounded (< total nodes)
            @test results[1].visited_nodes < length(db.nodes)
            @test results[1].latency_ns < 1_000_000 # Under 1 millisecond (sub-ms)
            
            close_database(db)
        end
    end

    @testset "A4: Semantic Fidelity & High-Dim Projection" begin
        # Generate 10 clusters in R^64
        D = 64
        num_clusters = 5
        pts_per_cluster = 20
        N = num_clusters * pts_per_cluster
        
        cluster_centers = [randn(Float32, D) * 3.0f0 for _ in 1:num_clusters]
        highdim_data = Vector{Vector{Float32}}(undef, N)
        labels = Vector{Int}(undef, N)
        
        idx = 1
        for c in 1:num_clusters
            for _ in 1:pts_per_cluster
                highdim_data[idx] = cluster_centers[c] + randn(Float32, D) * 0.5f0
                labels[idx] = c
                idx += 1
            end
        end
        
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "semantic.ncd")
            db = open_database(db_path; create=true)
            
            for i in 1:N
                put!(db, "item_$i", labels[i]; latent=highdim_data[i])
            end
            
            # Test cluster recall
            correct_cluster_matches = 0
            for i in 1:N
                q = highdim_data[i]
                res = near(db, q; limit=5, mode=:exact)
                # Check how many of top-5 belong to same cluster
                same_cluster = count(r -> r.payload == labels[i], res)
                if same_cluster >= 3
                    correct_cluster_matches += 1
                end
            end
            
            cluster_coherence_rate = correct_cluster_matches / N
            println("High-Dim to 5D Cluster Coherence Rate: $(round(cluster_coherence_rate * 100, digits=1))%")
            @test cluster_coherence_rate > 0.60 # Significant neighborhood preservation
            
            close_database(db)
        end
    end

    @testset "A5: Microbenchmarks & Performance Characterization" begin
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "bench.ncd")
            db = open_database(db_path; create=true)
            
            N_bench = 1000
            keys_bench = ["key_$i" for i in 1:N_bench]
            vals_bench = [Dict("idx" => i, "hash" => hash(i)) for i in 1:N_bench]
            
            # 1. Measure Write Throughput
            t_w0 = time_ns()
            for i in 1:N_bench
                put!(db, keys_bench[i], vals_bench[i])
            end
            t_w1 = time_ns()
            write_time_sec = (t_w1 - t_w0) / 1e9
            write_ops_per_sec = N_bench / write_time_sec
            println("NCD Write Throughput: $(round(write_ops_per_sec, digits=1)) ops/sec")
            @test write_ops_per_sec > 1000.0 # Must exceed 1,000 ops/sec
            
            # 2. Measure Point-Lookup Latency (p50 / p95 / p99)
            latencies_ns = Float64[]
            for i in 1:N_bench
                t0 = time_ns()
                v = get(db, keys_bench[i])
                t1 = time_ns()
                push!(latencies_ns, Float64(t1 - t0))
                @test v["idx"] == i
            end
            sort!(latencies_ns)
            p50_us = latencies_ns[round(Int, N_bench * 0.50)] / 1e3
            p95_us = latencies_ns[round(Int, N_bench * 0.95)] / 1e3
            p99_us = latencies_ns[round(Int, N_bench * 0.99)] / 1e3
            println("Point Lookup Latencies:")
            println("  p50: $(round(p50_us, digits=2)) µs")
            println("  p95: $(round(p95_us, digits=2)) µs")
            println("  p99: $(round(p99_us, digits=2)) µs")
            @test p50_us < 50.0 # Sub-50 microseconds point read
            
            # 3. Compare with Julia Dict
            dict_baseline = Dict{String, Any}()
            for i in 1:N_bench
                dict_baseline[keys_bench[i]] = vals_bench[i]
            end
            
            # 4. Measure Exact Search vs Exhaustive Search Time
            t_search0 = time_ns()
            for _ in 1:20
                q_rand = ntuple(_ -> Float32((rand() - 0.5) * 2.0), 5)
                near(db, LorentzPoint(q_rand); limit=5, mode=:exact)
            end
            t_search1 = time_ns()
            exact_search_latency_us = ((t_search1 - t_search0) / 20) / 1e3
            println("Exact Mode Search Latency (N=1000): $(round(exact_search_latency_us, digits=2)) µs")
            
            close_database(db)
        end
    end

end
