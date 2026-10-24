# NooDB.jl - Platform Abstraction Layer
# Implements cross-platform POSIX advisory file locking (flock)
# and hardware-level cache synchronization (fdatasync/fsync/_commit).

module Platform

using Base.Libc

export acquire_file_lock, release_file_lock, hard_sync, DatabaseLockedException

# POSIX flock flags
const LOCK_SH = Int32(1)
const LOCK_EX = Int32(2)
const LOCK_NB = Int32(4)
const LOCK_UN = Int32(8)

"""
    DatabaseLockedException

Thrown when another OS process holds an exclusive lock on the database file.
"""
struct DatabaseLockedException <: Exception
    path::String
    msg::String
end

Base.showerror(io::IO, e::DatabaseLockedException) =
    print(io, "DatabaseLockedException: ", e.msg, " [", e.path, "]")

"""
    acquire_file_lock(io::IO, path::String; exclusive::Bool=true, wait::Bool=false)::Bool

Acquires a process-level advisory lock on the underlying file descriptor using POSIX flock.
If the file is already locked by another process and wait=false, throws DatabaseLockedException.
"""
function acquire_file_lock(io::IO, path::String; exclusive::Bool=true, wait::Bool=false)::Bool
    if !Sys.isunix()
        return true # Advisory locking bypassed on non-Unix platforms
    end
    try
        fdesc = fd(io)
        operation = (exclusive ? LOCK_EX : LOCK_SH) | (wait ? Int32(0) : LOCK_NB)
        ret = ccall(:flock, Cint, (Cint, Cint), fdesc, operation)
        if ret != 0
            err = Libc.errno()
            # EAGAIN is 11 on Linux; check both EAGAIN and code 11
            if err == Libc.EAGAIN || err == 11 || (isdefined(Libc, :EWOULDBLOCK) && err == getfield(Libc, :EWOULDBLOCK))
                throw(DatabaseLockedException(path, "Resource temporarily unavailable: database file is locked exclusively by another process"))
            else
                Base.Libc.systemerror("flock", ret != 0)
            end
        end
        return true
    catch e
        if e isa DatabaseLockedException
            rethrow(e)
        end
        return false
    end
end

"""
    release_file_lock(io::IO)::Bool

Releases any advisory lock held on the underlying file descriptor.
"""
function release_file_lock(io::IO)::Bool
    if !Sys.isunix()
        return true
    end
    try
        fdesc = fd(io)
        ret = ccall(:flock, Cint, (Cint, Cint), fdesc, LOCK_UN)
        return ret == 0
    catch
        return false
    end
end

"""
    hard_sync(io::IO)::Bool

Issues a hardware-level flush barrier to the physical storage device controller.
Flushes libc/Julia userland buffers, then issues fdatasync (Linux), fsync (Unix/macOS),
or _commit (Windows) to guarantee dirty kernel page cache is committed to persistent flash.
"""
function hard_sync(io::IO)::Bool
    flush(io)
    if !(io isa Base.Filesystem.File || io isa IOStream)
        return true
    end
    try
        fdesc = fd(io)
        if Sys.islinux()
            ret = ccall(:fdatasync, Cint, (Cint,), fdesc)
            if ret != 0
                ret = ccall(:fsync, Cint, (Cint,), fdesc)
            end
            return ret == 0
        elseif Sys.isunix()
            ret = ccall(:fsync, Cint, (Cint,), fdesc)
            return ret == 0
        elseif Sys.iswindows()
            ret = ccall(:_commit, Cint, (Cint,), fdesc)
            return ret == 0
        end
        return true
    catch
        return false
    end
end

end # module Platform
