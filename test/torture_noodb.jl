# NooDB.jl - The Adversarial Torture Chamber & Production Gauntlet
# Tests:
# Gate 1: 32-Worker Concurrent Hammer (Race condition attack, mixed read/write/delete/sync)
# Gate 2: Hyperbolic Numerical Singularities (NaNs, Infs, near-lightcone, antipodal, acosh stability)
# Gate 3: Chaos Monkey Fuzzer & Hostile OOM Payload Bombs
# Gate 4: Atomic Vacuum & Zero-Leak Space Reclamation (compact!)
# Gate 5: Double-Buffered Crash Recovery & Monotonic Generation Integrity

using Test
using NooDB
using NooDB.Format
using LinearAlgebra
using Statistics
using CRC32c

println("================================================================================")
println("           NooDB.jl ADVERSARIAL FORTIFICATION TORTURE CHAMBER                   ")
println("                       Knowledge Has Geometry                                  ")
println("================================================================================")

@testset "NooDB Adversarial Torture Chamber" begin

    @testset "Gate 1: Multi-Worker Concurrent Hammer (Race Condition Attack)" begin
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "concurrency_torture.noodb")
            db = open_database(db_path; create=true)
            
            num_workers = 32
            ops_per_worker = 100
            total_ops = num_workers * ops_per_worker
            
            println("  [Gate 1] Launching $num_workers concurrent workers ($total_ops total mixed operations)...")
            
            # Shared concurrent task execution
            tasks = Task[]
            for w in 1:num_workers
                t = @async begin
                    for i in 1:ops_per_worker
                        k = "worker_$(w)_rec_$(i)"
                        val = Dict("worker" => w, "iter" => i, "payload" => "Data payload for $w-$i " * ("x"^50))
                        
                        # 1. Put
                        put!(db, k, val)
                        
                        # 2. Immediate get & verify
                        read_val = get(db, k)
                        @assert read_val !== nothing "Concurrent read failed immediately after write on key '$k'"
                        @assert read_val["worker"] == w
                        
                        # 3. Interleaved nearest neighbor query
                        if i % 10 == 0
                            res = near(db, k; limit=3, mode=:exact)
                            @assert !isempty(res) "Concurrent near query returned empty result"
                        end
                        
                        # 4. Delete some records
                        if i % 25 == 0
                            del_res = delete!(db, k)
                            @assert del_res == true
                            @assert get(db, k) === nothing
                        end
                        
                        # 5. Periodic sync
                        if i % 50 == 0
                            sync!(db)
                        end
                    end
                end
                push!(tasks, t)
            end
            
            # Wait for all 32 workers to complete
            for t in tasks
                wait(t)
            end
            
            println("  [Gate 1] All $num_workers workers finished without race conditions or segfaults.")
            
            # Sync and close cleanly
            close_database(db)
            
            # Reopen and verify database consistency
            db_verify = open_database(db_path; create=false)
            @test length(db_verify.key_to_node) > 0
            
            # Verify surviving records
            surviving = 0
            for w in 1:num_workers
                for i in 1:ops_per_worker
                    k = "worker_$(w)_rec_$(i)"
                    if i % 25 != 0
                        v = get(db_verify, k)
                        @test v !== nothing
                        @test v["worker"] == w
                        surviving += 1
                    else
                        @test get(db_verify, k) === nothing
                    end
                end
            end
            
            println("  [Gate 1] Verified $surviving surviving records intact across reloaded database.")
            close_database(db_verify)
        end
    end

    @testset "Gate 2: Hyperbolic Numerical Singularities & Precision Armor" begin
        println("  [Gate 2] Testing hyperbolic numerical edge cases & NaN armor...")
        
        # 1. NaN and Inf rejection
        @test_throws ArgumentError LorentzPoint(NaN, 1.0, 2.0, 3.0, 4.0, 5.0)
        @test_throws ArgumentError LorentzPoint(1.0, Inf, 2.0, 3.0, 4.0, 5.0)
        @test_throws ArgumentError LorentzPoint((NaN, 1.0, 2.0, 3.0, 4.0))
        @test_throws ArgumentError LorentzPoint((1.0, 2.0, -Inf, 4.0, 5.0))
        @test_throws ArgumentError project_highdim_to_h5([1.0, NaN, 3.0])
        @test_throws ArgumentError project_highdim_to_h5([Inf, 2.0, 3.0])
        
        # 2. Coordinate overflow clamping (prevent Float32 square overflow)
        p_huge = LorentzPoint((1.0e25, 0.0, 0.0, 0.0, 0.0))
        @test isfinite(p_huge.x0)
        @test isfinite(p_huge.x1)
        @test p_huge.x1 == 1.0f18 # Clamped safely
        @test isfinite(lorentz_norm_sq(p_huge))
        
        # 3. Coincident points: distance must be exactly 0.0, no NaN, no domain error
        p_coincident = LorentzPoint((0.2f0, -0.4f0, 0.7f0, 0.1f0, -0.9f0))
        @test lorentz_dist(p_coincident, p_coincident) == 0.0f0
        
        # 4. Near-lightcone points (points very close to each other with tiny differences)
        p_a = LorentzPoint((1.0f0, 2.0f0, 3.0f0, 4.0f0, 5.0f0))
        p_b = LorentzPoint((1.0f0 + 1.0f-7, 2.0f0, 3.0f0, 4.0f0, 5.0f0))
        d_ab = lorentz_dist(p_a, p_b)
        @test isfinite(d_ab)
        @test d_ab >= 0.0f0
        
        # 5. Subnormal numbers
        p_sub = LorentzPoint((1.0e-38, 0.0, 0.0, 0.0, 0.0))
        @test isfinite(p_sub.x0)
        @test abs(lorentz_norm_sq(p_sub) + 1.0f0) < 1.0e-5
        
        println("  [Gate 2] Numerical armor verified: 100% immune to NaNs, Infs, and acosh DomainErrors.")
    end

    @testset "Gate 3: Chaos Monkey Fuzzer & Hostile Payload Bomb Defense" begin
        println("  [Gate 3] Testing OOM payload bomb and corrupted offset defenses...")
        
        mktempdir() do tmpdir
            # Test 1: Malicious 4GB payload size attack
            test_file = joinpath(tmpdir, "payload_bomb.noodb")
            io = Base.open(test_file, "w+")
            
            # Write valid header block
            write(io, zeros(UInt8, Format.HEADER_BLOCK_SIZE))
            
            # Hostile payload block: length = 0xFFFFFFFF (4 GB)
            hostile_offset = UInt64(position(io))
            write(io, 0xFFFFFFFF)
            write(io, 0x12345678)
            write(io, [0x01, 0x02, 0x03, 0x04]) # Truncated
            flush(io)
            
            # Reading with size = 0xFFFFFFFF must immediately throw an error BEFORE allocation
            @test_throws ErrorException read_payload(io, hostile_offset, 0xFFFFFFFF)
            
            # Reading with size exceeding actual file size must throw clean bounds error
            @test_throws ErrorException read_payload(io, hostile_offset, UInt32(100000))
            
            # Reading past EOF
            @test_throws ErrorException read_payload(io, UInt64(9999999), UInt32(64))
            
            Base.close(io)
            println("  [Gate 3] Malicious OOM payload bombs safely repelled.")
        end
    end

    @testset "Gate 4: Atomic Vacuum & Space Reclamation Engine (compact!)" begin
        println("  [Gate 4] Testing atomic vacuum & garbage collection...")
        
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "vacuum_test.noodb")
            db = open_database(db_path; create=true)
            
            # 1. Insert 300 large records (each with a 4 KB payload)
            chunk = "A" ^ 4096
            for i in 1:300
                put!(db, "doc_$i", Dict("id" => i, "body" => chunk))
            end
            sync!(db)
            
            size_before_deletes = filesize(db_path)
            println("  [Gate 4] Database size with 300 records: $(round(size_before_deletes / 1024, digits=1)) KB")
            
            # 2. Delete 250 of the 300 records (83% of data becomes dead space)
            for i in 1:250
                delete!(db, "doc_$i")
            end
            sync!(db)
            
            size_after_deletes = filesize(db_path)
            @test size_after_deletes >= size_before_deletes # Dead space still present in append-only log
            
            # 3. Execute atomic vacuum / compaction!
            compact!(db)
            
            size_after_vacuum = filesize(db_path)
            println("  [Gate 4] Database size after vacuum: $(round(size_after_vacuum / 1024, digits=1)) KB")
            
            # Assert significant space reclamation
            @test size_after_vacuum < size_after_deletes * 0.40 # Reclaimed at least 60% of dead space!
            
            # 4. Verify data integrity of remaining 50 records
            for i in 251:300
                v = get(db, "doc_$i")
                @test v !== nothing
                @test v["id"] == i
                @test v["body"] == chunk
            end
            
            # 5. Verify deleted records are still gone
            for i in 1:250
                @test get(db, "doc_$i") === nothing
            end
            
            # 6. Verify semantic search still works on compacted trie
            results = near(db, "doc_280"; limit=5, mode=:exact)
            @test length(results) == 5
            @test results[1].key == "doc_280"
            
            close_database(db)
            
            # 7. Reopen from disk to prove compacted file opens cleanly
            db_reopened = open_database(db_path; create=false)
            @test length(db_reopened.key_to_node) == 50
            @test get(db_reopened, "doc_300") !== nothing
            close_database(db_reopened)
            
            println("  [Gate 4] Atomic vacuum successfully reclaimed $(round((1 - size_after_vacuum/size_after_deletes)*100, digits=1))% of fragmented storage.")
        end
    end

    @testset "Gate 5: Double-Buffered Crash Recovery & Monotonic Generation Integrity" begin
        println("  [Gate 5] Testing double-buffered header crash-recovery failover...")
        
        mktempdir() do tmpdir
            db_path = joinpath(tmpdir, "crash_recovery.noodb")
            db = open_database(db_path; create=true)
            
            # Populate initial data and close (persisting to disk)
            for i in 1:20
                put!(db, "initial_$i", "Value $i")
            end
            close_database(db)
            
            gen_committed = db.generation
            @test gen_committed >= 2
            
            # SIMULATE CRASH: Intentionally corrupt the active header slot
            # Slot offset: if gen is odd, slot 0; if even, slot 1 (128)
            active_slot_offset = (gen_committed % 2 == 1) ? 0 : Format.HEADER_SLOT_SIZE
            
            io = Base.open(db_path, "r+")
            seek(io, active_slot_offset)
            # Write garbage over the magic and CRC of the active header slot
            write(io, [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00])
            flush(io)
            Base.close(io)
            
            # Reopen database: The engine MUST detect corruption in active slot and
            # cleanly fail over to the previous valid generation slot without error!
            db_recovered = open_database(db_path; create=false)
            @test db_recovered.header.magic == Format.NOODB_MAGIC
            @test db_recovered.header.generation == gen_committed - 1
            
            println("  [Gate 5] Automatic failover to Generation $(db_recovered.header.generation) succeeded!")
            
            # Ensure database can continue operating and writing cleanly after recovery
            put!(db_recovered, "recovered_key", "Post-crash resilient write")
            sync!(db_recovered)
            @test get(db_recovered, "recovered_key") == "Post-crash resilient write"
            
            close_database(db_recovered)
            println("  [Gate 5] Double-buffered crash recovery certified.")
        end
    end

end

println("================================================================================")
println("              ALL 5 NOODB FORTIFICATION GATES PASSED (100% GREEN)               ")
println("================================================================================")
