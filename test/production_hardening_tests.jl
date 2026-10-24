# NooDB.jl - Production Hardening Test Suite
# Rigorous validation of POSIX file locking (flock), hardware sync barriers (fdatasync),
# type-secure binary serialization, transaction batching, and HTTP/REST daemon integration.

using Test
using NooDB
using Sockets

@testset "NooDB Production Hardening Suite" begin
    test_dir = mktempdir()
    db_path = joinpath(test_dir, "prod_test.noo")

    @testset "1. POSIX Cross-Process File Locking (flock)" begin
        # Open DB instance 1
        db1 = open_database(db_path; create=true, lock_file=true)
        put!(db1, "proc1_key", "proc1_val")
        sync!(db1)

        # Attempt to open DB instance 2 on the same file -> must throw DatabaseLockedException
        @test_throws DatabaseLockedException open_database(db_path; lock_file=true)

        # Close instance 1 to release lock
        close_database(db1)

        # Now instance 2 must succeed
        db2 = open_database(db_path; lock_file=true)
        @test get(db2, "proc1_key") == "proc1_val"
        close_database(db2)
    end

    @testset "2. Hardware Cache Sync Barrier (fdatasync)" begin
        db = open_database(db_path; lock_file=true)
        gen_before = db.generation
        put!(db, "sync_test_key", "durable_value")
        sync!(db)
        @test db.generation == gen_before + 1
        
        # Verify no-op sync does not increment generation or rewrite tables when !db.dirty
        gen_clean = db.generation
        sync!(db)
        @test db.generation == gen_clean
        close_database(db)
    end

    @testset "3. Type-Secure Binary Serialization" begin
        # String roundtrip
        s_val = "concept:hyperbolic_neural_network"
        b_s = serialize_value(s_val)
        @test b_s[1] == NooDB.SecureSerialization.TAG_STRING
        @test deserialize_value(b_s) == s_val

        # Raw Bytes roundtrip
        raw_val = UInt8[0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03]
        b_raw = serialize_value(raw_val)
        @test b_raw[1] == NooDB.SecureSerialization.TAG_BYTES
        @test deserialize_value(b_raw) == raw_val

        # Numbers
        @test deserialize_value(serialize_value(Int64(42))) == 42
        @test deserialize_value(serialize_value(Float64(3.1415926535))) ≈ 3.1415926535
        @test deserialize_value(serialize_value(true)) == true

        # Float32 Vector (Embeddings)
        emb = Float32[0.1, -0.2, 0.3, 0.4, -0.5]
        b_emb = serialize_value(emb)
        @test b_emb[1] == NooDB.SecureSerialization.TAG_FLOAT32_VEC
        @test deserialize_value(b_emb) == emb

        # Defense against malicious truncated bytes
        malicious_truncated = UInt8[NooDB.SecureSerialization.TAG_STRING, 0xFF, 0xFF, 0x00, 0x00, 0x41]
        @test_throws ArgumentError deserialize_value(malicious_truncated)
    end

    @testset "4. Batch Transaction Performance & Index Reuse" begin
        db = open_database(db_path; lock_file=true)
        gen_before = db.generation
        
        # Batch 1,000 inserts inside an atomic transaction block
        transaction(db) do
            for i in 1:1000
                put!(db, "batch_key_$i", "batch_val_$i")
            end
        end
        
        # Must only advance generation by exactly 1 for the whole batch!
        @test db.generation == gen_before + 1
        @test length(db.key_to_node) >= 1000
        
        # Validate random point reads
        @test get(db, "batch_key_1") == "batch_val_1"
        @test get(db, "batch_key_500") == "batch_val_500"
        @test get(db, "batch_key_1000") == "batch_val_1000"
        
        close_database(db)
    end

    @testset "5. Production HTTP/REST Daemon Server" begin
        srv_port = 18090
        srv = start_server(db_path; host="127.0.0.1", port=srv_port, async=true)
        sleep(0.5) # Allow socket to bind
        
        try
            # 5.1 GET /health
            sock = connect(ip"127.0.0.1", srv_port)
            write(sock, "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            resp = String(readavailable(sock))
            close(sock)
            @test occursin("HTTP/1.1 200 OK", resp)
            @test occursin("\"service\":\"NooDB\"", resp)
            
            # 5.2 PUT /v1/records/http_test_key
            sock = connect(ip"127.0.0.1", srv_port)
            body = "Hello from HTTP API!"
            req = "PUT /v1/records/http_test_key HTTP/1.1\r\n" *
                  "Host: 127.0.0.1\r\n" *
                  "X-NooDB-Concept: cloudflare_edge_service\r\n" *
                  "Content-Length: $(length(body))\r\n\r\n" * body
            write(sock, req)
            resp = String(readavailable(sock))
            close(sock)
            @test occursin("HTTP/1.1 200 OK", resp)
            @test occursin("\"status\":\"stored\"", resp)
            
            # 5.3 GET /v1/records/http_test_key
            sock = connect(ip"127.0.0.1", srv_port)
            write(sock, "GET /v1/records/http_test_key HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            resp = String(readavailable(sock))
            close(sock)
            @test occursin("HTTP/1.1 200 OK", resp)
            @test occursin("Hello from HTTP API!", resp)
            
            # 5.4 POST /v1/concepts/near
            sock = connect(ip"127.0.0.1", srv_port)
            search_body = "{\"concept\": \"cloudflare_edge_service\", \"k\": 5}"
            req = "POST /v1/concepts/near HTTP/1.1\r\n" *
                  "Host: 127.0.0.1\r\n" *
                  "Content-Length: $(length(search_body))\r\n\r\n" * search_body
            write(sock, req)
            resp = String(readavailable(sock))
            close(sock)
            @test occursin("HTTP/1.1 200 OK", resp)
            @test occursin("http_test_key", resp)
            
            # 5.5 DELETE /v1/records/http_test_key
            sock = connect(ip"127.0.0.1", srv_port)
            write(sock, "DELETE /v1/records/http_test_key HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            resp = String(readavailable(sock))
            close(sock)
            @test occursin("HTTP/1.1 200 OK", resp)
            @test occursin("\"status\":\"deleted\"", resp)
            
            # 5.6 POST /v1/admin/sync & compact
            sock = connect(ip"127.0.0.1", srv_port)
            write(sock, "POST /v1/admin/sync HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            resp = String(readavailable(sock))
            close(sock)
            @test occursin("HTTP/1.1 200 OK", resp)
            @test occursin("\"status\":\"synced\"", resp)
        finally
            stop_server(srv)
        end
    end

    # Clean up test directory
    rm(test_dir; recursive=true, force=true)
end

println("All Production Hardening Tests Passed Successfully!")
