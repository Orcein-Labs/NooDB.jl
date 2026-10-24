# NooDB.jl - Production HTTP/REST & IPC Daemon Server
# Zero-dependency, asynchronous HTTP/1.1 API server for edge and microservice integration.
# Allows Cloudflare Workers, Python, Node.js, and curl to query NooDB natively.

module Server

using Sockets
using ..Lorentz
using ..Engine

export NooDBServer, start_server, stop_server

"""
    NooDBServer

Running instance of the NooDB HTTP/REST daemon.
"""
mutable struct NooDBServer
    db::NooDBDatabase
    server::Sockets.TCPServer
    task::Task
    is_running::Ref{Bool}
    host::String
    port::Int
end

"""
    write_http_response(client::TCPSocket, status_code::Int, status_text::String, content_type::String, body::Union{String, Vector{UInt8}})
"""
function write_http_response(
    client::TCPSocket,
    status_code::Int,
    status_text::String,
    content_type::String,
    body::Union{String, Vector{UInt8}}
)
    body_bytes = body isa String ? codeunits(body) : body
    response = "HTTP/1.1 $status_code $status_text\r\n" *
               "Server: NooDB/0.1.0\r\n" *
               "Content-Type: $content_type\r\n" *
               "Content-Length: $(length(body_bytes))\r\n" *
               "Connection: close\r\n" *
               "Access-Control-Allow-Origin: *\r\n" *
               "Access-Control-Allow-Methods: GET, PUT, POST, DELETE, OPTIONS\r\n" *
               "Access-Control-Allow-Headers: Content-Type, X-NooDB-Concept, X-NooDB-Latent\r\n\r\n"
    write(client, codeunits(response))
    write(client, body_bytes)
    flush(client)
end

"""
    parse_http_request(client::TCPSocket)
"""
function parse_http_request(client::TCPSocket)
    line = readline(client)
    if isempty(line)
        return nothing
    end
    parts = split(strip(line), " ")
    if length(parts) < 2
        return nothing
    end
    method = String(parts[1])
    target = String(parts[2])
    
    headers = Dict{String, String}()
    while true
        h_line = readline(client)
        h_line_stripped = strip(h_line)
        if isempty(h_line_stripped)
            break
        end
        h_parts = split(h_line_stripped, ":"; limit=2)
        if length(h_parts) == 2
            headers[lowercase(strip(h_parts[1]))] = strip(h_parts[2])
        end
    end
    
    content_len = parse(Int, get(headers, "content-length", "0"))
    body = UInt8[]
    if content_len > 0
        body = read(client, content_len)
    end
    
    return (method=method, target=target, headers=headers, body=body)
end

"""
    handle_client(db::NooDBDatabase, client::TCPSocket)
"""
function handle_client(db::NooDBDatabase, client::TCPSocket)
    try
        req = parse_http_request(client)
        if req === nothing
            close(client)
            return
        end
        
        # Handle CORS preflight
        if req.method == "OPTIONS"
            write_http_response(client, 204, "No Content", "text/plain", "")
            close(client)
            return
        end
        
        path = req.target
        query_idx = findfirst('?', path)
        clean_path = query_idx !== nothing ? path[1:query_idx-1] : path
        
        # Route 1: GET /health
        if req.method == "GET" && (clean_path == "/health" || clean_path == "/")
            rec_count = length(db.key_to_node)
            gen = db.generation
            node_count = length(db.nodes)
            fsize = isopen(db.io) ? filesize(db.io) : 0
            json_body = "{\"status\":\"ok\",\"service\":\"NooDB\",\"records\":$rec_count,\"nodes\":$node_count,\"generation\":$gen,\"file_size\":$fsize}"
            write_http_response(client, 200, "OK", "application/json", json_body)
            close(client)
            return
        end
        
        # Route 2: GET /v1/records/:key
        if req.method == "GET" && startswith(clean_path, "/v1/records/")
            key = clean_path[length("/v1/records/")+1:end]
            val = Engine.get(db, key)
            if val === nothing
                write_http_response(client, 404, "Not Found", "application/json", "{\"error\":\"Key not found\",\"key\":\"$key\"}")
            else
                if val isa String
                    write_http_response(client, 200, "OK", "text/plain; charset=utf-8", val)
                elseif val isa Vector{UInt8}
                    write_http_response(client, 200, "OK", "application/octet-stream", val)
                else
                    write_http_response(client, 200, "OK", "application/json", string(val))
                end
            end
            close(client)
            return
        end
        
        # Route 3: PUT /v1/records/:key
        if req.method == "PUT" && startswith(clean_path, "/v1/records/")
            key = clean_path[length("/v1/records/")+1:end]
            concept = get(req.headers, "x-noodb-concept", nothing)
            latent_header = get(req.headers, "x-noodb-latent", nothing)
            
            latent = nothing
            if latent_header !== nothing
                nums = split(latent_header, ",")
                latent = [parse(Float32, strip(x)) for x in nums if !isempty(strip(x))]
            end
            
            # If body is UTF-8 text, store as string, otherwise raw bytes
            body_val = try
                String(req.body)
            catch
                req.body
            end
            
            Engine.put!(db, key, body_val; concept=concept, latent=latent)
            write_http_response(client, 200, "OK", "application/json", "{\"status\":\"stored\",\"key\":\"$key\"}")
            close(client)
            return
        end
        
        # Route 4: DELETE /v1/records/:key
        if req.method == "DELETE" && startswith(clean_path, "/v1/records/")
            key = clean_path[length("/v1/records/")+1:end]
            deleted = Engine.delete!(db, key)
            if deleted
                write_http_response(client, 200, "OK", "application/json", "{\"status\":\"deleted\",\"key\":\"$key\"}")
            else
                write_http_response(client, 404, "Not Found", "application/json", "{\"error\":\"Key not found\",\"key\":\"$key\"}")
            end
            close(client)
            return
        end
        
        # Route 5: POST /v1/concepts/near
        if req.method == "POST" && clean_path == "/v1/concepts/near"
            body_str = String(req.body)
            k = 10
            m_k = match(r"\"k\"\s*:\s*(\d+)", body_str)
            if m_k !== nothing
                k = parse(Int, m_k.captures[1])
            end
            
            m_latent = match(r"\"latent\"\s*:\s*\[([^\]]+)\]", body_str)
            m_concept = match(r"\"concept\"\s*:\s*\"([^\"]+)\"", body_str)
            
            results = SearchResult[]
            if m_latent !== nothing
                raw_nums = split(m_latent.captures[1], ",")
                latent_vec = [parse(Float32, strip(x)) for x in raw_nums if !isempty(strip(x))]
                results = Engine.query_latent(db, latent_vec; limit=k)
            elseif m_concept !== nothing
                results = Engine.near(db, m_concept.captures[1]; limit=k)
            else
                write_http_response(client, 400, "Bad Request", "application/json", "{\"error\":\"Must supply 'latent' array or 'concept' string\"}")
                close(client)
                return
            end
            
            # Format results array
            items = String[]
            for r in results
                push!(items, "{\"key\":\"$(r.key)\",\"distance\":$(r.distance),\"visited_nodes\":$(r.visited_nodes)}")
            end
            json_arr = "[" * join(items, ",") * "]"
            write_http_response(client, 200, "OK", "application/json", json_arr)
            close(client)
            return
        end
        
        # Route 6: POST /v1/admin/sync
        if req.method == "POST" && clean_path == "/v1/admin/sync"
            Engine.sync!(db)
            write_http_response(client, 200, "OK", "application/json", "{\"status\":\"synced\",\"generation\":$(db.generation)}")
            close(client)
            return
        end
        
        # Route 7: POST /v1/admin/compact
        if req.method == "POST" && clean_path == "/v1/admin/compact"
            Engine.compact!(db)
            write_http_response(client, 200, "OK", "application/json", "{\"status\":\"compacted\",\"generation\":$(db.generation)}")
            close(client)
            return
        end
        
        # Fallback: 404
        write_http_response(client, 404, "Not Found", "application/json", "{\"error\":\"Endpoint not found\",\"path\":\"$clean_path\"}")
        close(client)
    catch e
        try
            write_http_response(client, 500, "Internal Server Error", "application/json", "{\"error\":\"$(string(e))\"}")
            close(client)
        catch
        end
    end
end

"""
    start_server(db_or_path; host="127.0.0.1", port=8080, async=true)::NooDBServer

Starts a high-performance HTTP/REST server for NooDB.
"""
function start_server(
    db_or_path::Union{NooDBDatabase, String};
    host::String = "127.0.0.1",
    port::Int = 8080,
    async::Bool = true
)::NooDBServer
    db = db_or_path isa NooDBDatabase ? db_or_path : Engine.open_database(db_or_path; create=true)
    ip_addr = Sockets.parse(IPAddr, host)
    server = Sockets.listen(ip_addr, port)
    is_running = Ref(true)
    
    server_task = @async begin
        while is_running[]
            try
                client = Sockets.accept(server)
                @async handle_client(db, client)
            catch e
                if !is_running[]
                    break
                end
            end
        end
    end
    
    srv = NooDBServer(db, server, server_task, is_running, host, port)
    
    if !async
        wait(server_task)
    end
    
    return srv
end

"""
    stop_server(srv::NooDBServer)

Gracefully stops the HTTP/REST server and flushes database state.
"""
function stop_server(srv::NooDBServer)
    srv.is_running[] = false
    try
        close(srv.server)
    catch
    end
    try
        Engine.close_database(srv.db)
    catch
    end
    return true
end

end # module Server
