//! Enhanced cache management for bundlr
//! Provides directory locking, cache validation, and cleanup functionality

const std = @import("std");
const fs = std.fs;
const paths_module = @import("../platform/paths.zig");
const config = @import("../config.zig");

/// Directory entry for cache cleanup sorting
const DirEntry = struct {
    name: []const u8,
    mtime: i128,

    fn lessThan(_: void, a: DirEntry, b: DirEntry) bool {
        return a.mtime < b.mtime; // Sort oldest first
    }
};

/// Cache manager with locking and validation capabilities
pub const Cache = struct {
    allocator: std.mem.Allocator,
    paths: paths_module.Paths,
    cache_dir: []const u8,
    lock_file: ?std.fs.File = null,

    pub fn init(allocator: std.mem.Allocator) !Cache {
        var paths = paths_module.Paths.init(allocator);
        const cache_dir = try paths.getBundlrCacheDir();

        return Cache{
            .allocator = allocator,
            .paths = paths,
            .cache_dir = cache_dir,
        };
    }

    pub fn deinit(self: *Cache) void {
        if (self.lock_file) |lock_file| {
            lock_file.close();
        }
        self.allocator.free(self.cache_dir);
    }

    /// Acquire an exclusive lock on the cache directory
    /// This prevents concurrent installations from interfering with each other
    pub fn acquireLock(self: *Cache) !void {
        if (self.lock_file != null) {
            return error.LockAlreadyAcquired;
        }

        // Ensure cache directory exists
        try self.paths.ensureDirExists(self.cache_dir);

        // Create lock file path
        var lock_path_buf: [fs.max_path_bytes]u8 = undefined;
        const lock_path = try std.fmt.bufPrint(&lock_path_buf, "{s}/.bundlr.lock", .{self.cache_dir});

        // Create and lock the file
        self.lock_file = fs.createFileAbsolute(lock_path, .{
            .exclusive = true,
            .truncate = false,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Try to open existing lock file and acquire lock
                const file = try fs.openFileAbsolute(lock_path, .{ .mode = .write_only });
                errdefer file.close();

                // Try to lock the file (non-blocking)
                file.lock(.exclusive) catch |lock_err| switch (lock_err) {
                    error.WouldBlock => {
                        file.close();
                        return error.CacheInUse;
                    },
                    else => {
                        file.close();
                        return lock_err;
                    },
                };

                // Successfully acquired lock, store file handle
                self.lock_file = file;
            },
            else => return err,
        };

        // Lock the file
        try self.lock_file.?.lock(.exclusive);

        // Write PID to lock file for debugging
        const pid = std.os.getpid();
        var pid_buf: [32]u8 = undefined;
        const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}\n", .{pid});
        try self.lock_file.?.writeAll(pid_str);
        try self.lock_file.?.sync();
    }

    /// Release the cache lock
    pub fn releaseLock(self: *Cache) void {
        if (self.lock_file) |lock_file| {
            lock_file.close();
            self.lock_file = null;

            // Remove lock file
            var lock_path_buf: [fs.max_path_bytes]u8 = undefined;
            const lock_path = std.fmt.bufPrint(&lock_path_buf, "{s}/.bundlr.lock", .{self.cache_dir}) catch return;
            fs.deleteFileAbsolute(lock_path) catch {}; // Ignore errors - file might not exist
        }
    }

    /// Check if a cached item exists and is valid
    pub fn isValidCached(self: *Cache, item_path: []const u8) !bool {
        const full_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, item_path });
        defer self.allocator.free(full_path);

        // Check if path exists
        const stat = fs.cwd().statFile(full_path) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };

        // For directories, check if they're not empty
        if (stat.kind == .directory) {
            var dir = fs.openDirAbsolute(full_path, .{ .iterate = true }) catch return false;
            defer dir.close();

            var iterator = dir.iterate();
            const first_entry = iterator.next() catch return false;
            return first_entry != null; // Directory is valid if it has at least one entry
        }

        // For files, check if size is greater than 0
        return stat.size > 0;
    }

    /// Get cache statistics
    pub fn getStats(self: *Cache) !CacheStats {
        var stats = CacheStats{};

        // Walk the cache directory and calculate stats
        const cache_dir = fs.openDirAbsolute(self.cache_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return stats, // Cache doesn't exist yet
            else => return err,
        };
        defer cache_dir.close();

        var walker = try cache_dir.walk(self.allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    const file_stats = try entry.dir.statFile(entry.basename);
                    stats.total_size += file_stats.size;
                    stats.file_count += 1;
                },
                .directory => {
                    stats.dir_count += 1;
                },
                else => {},
            }
        }

        return stats;
    }

    /// Clean up old cache entries based on size limits
    pub fn cleanup(self: *Cache) !void {
        const build_config = config.BuildConfig{};
        if (build_config.max_cache_size_mb == 0) {
            return; // No size limit set
        }

        const stats = try self.getStats();
        const max_size_bytes = @as(u64, build_config.max_cache_size_mb) * 1024 * 1024;

        if (stats.total_size <= max_size_bytes) {
            return; // Cache is within limits
        }

        std.log.info("Cache size ({d} MB) exceeds limit ({d} MB), cleaning up...", .{
            stats.total_size / (1024 * 1024),
            build_config.max_cache_size_mb,
        });

        // Simple cleanup strategy: remove oldest venvs and git extracts first
        try self.cleanupBySize(max_size_bytes);
    }

    /// Clean up cache entries to fit within size limit
    fn cleanupBySize(self: *Cache, max_size_bytes: u64) !void {
        // Cleanup priority: git_extracts > venvs > git_archives > downloads > python > uv
        const cleanup_dirs = [_][]const u8{ "git_extracts", "venvs", "git_archives" };

        for (cleanup_dirs) |subdir_name| {
            const current_stats = try self.getStats();
            if (current_stats.total_size <= max_size_bytes) {
                std.log.info("Cache cleanup completed. Size: {d} MB", .{current_stats.total_size / (1024 * 1024)});
                return;
            }

            const subdir_path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, subdir_name });
            defer self.allocator.free(subdir_path);

            try self.cleanupDirectory(subdir_path, max_size_bytes);
        }
    }

    /// Clean up a specific directory by removing oldest entries
    fn cleanupDirectory(self: *Cache, dir_path: []const u8, max_size_bytes: u64) !void {
        const dir = fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return, // Directory doesn't exist
            else => return err,
        };
        defer dir.close();

        // Collect directory entries with their timestamps
        var entries = std.ArrayList(DirEntry).init(self.allocator);
        defer entries.deinit();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .directory) {
                const stat = try dir.statFile(entry.name);
                try entries.append(DirEntry{
                    .name = try self.allocator.dupe(u8, entry.name),
                    .mtime = stat.mtime,
                });
            }
        }

        // Sort by modification time (oldest first)
        std.mem.sort(DirEntry, entries.items, {}, DirEntry.lessThan);

        // Remove oldest entries until under size limit
        var freed_count: usize = 0;
        for (entries.items) |entry| {
            const current_stats = try self.getStats();
            if (current_stats.total_size <= max_size_bytes) {
                break;
            }

            const entry_path = try std.fs.path.join(self.allocator, &.{ dir_path, entry.name });
            defer self.allocator.free(entry_path);

            std.log.info("Removing old cache entry: {s}", .{entry.name});
            fs.deleteTreeAbsolute(entry_path) catch |err| {
                std.log.warn("Failed to remove {s}: {}", .{ entry_path, err });
            };
            
            self.allocator.free(entry.name);
            freed_count += 1;
        }
        
        // Free remaining entry names that weren't processed
        for (entries.items[freed_count..]) |entry| {
            self.allocator.free(entry.name);
        }
    }

    /// Clear all cache contents
    pub fn clear(self: *Cache) !void {
        // Remove entire cache directory
        fs.deleteTreeAbsolute(self.cache_dir) catch |err| switch (err) {
            error.FileNotFound => {}, // Cache doesn't exist
            else => return err,
        };

        // Recreate cache directory
        try self.paths.ensureDirExists(self.cache_dir);
    }

    /// Create a version-specific subdirectory for caching
    pub fn getVersionedCacheDir(self: *Cache, component: []const u8, version: []const u8) ![]const u8 {
        return try std.fs.path.join(self.allocator, &.{ self.cache_dir, component, version });
    }
};

/// Cache statistics structure
pub const CacheStats = struct {
    total_size: u64 = 0,
    file_count: u32 = 0,
    dir_count: u32 = 0,

    pub fn format(
        self: CacheStats,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        return writer.print("CacheStats{{ size: {:.2} MB, files: {d}, dirs: {d} }}", .{
            @as(f64, @floatFromInt(self.total_size)) / (1024.0 * 1024.0),
            self.file_count,
            self.dir_count,
        });
    }
};

/// RAII wrapper for cache locking
pub const CacheLock = struct {
    cache: *Cache,
    locked: bool = false,

    pub fn init(cache: *Cache) CacheLock {
        return CacheLock{ .cache = cache };
    }

    pub fn acquire(self: *CacheLock) !void {
        if (self.locked) return error.AlreadyLocked;
        try self.cache.acquireLock();
        self.locked = true;
    }

    pub fn release(self: *CacheLock) void {
        if (self.locked) {
            self.cache.releaseLock();
            self.locked = false;
        }
    }

    pub fn deinit(self: *CacheLock) void {
        self.release();
    }
};

// Tests
test "cache initialization and cleanup" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator);
    defer cache.deinit();

    try std.testing.expect(cache.cache_dir.len > 0);
    try std.testing.expect(cache.lock_file == null);
}

test "cache stats on empty cache" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator);
    defer cache.deinit();

    const stats = cache.getStats() catch |err| switch (err) {
        error.FileNotFound => return, // Expected for non-existent cache
        else => return err,
    };

    try std.testing.expect(stats.total_size == 0);
    try std.testing.expect(stats.file_count == 0);
}

test "versioned cache directory" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator);
    defer cache.deinit();

    const versioned_dir = try cache.getVersionedCacheDir("python", "3.13");
    defer allocator.free(versioned_dir);

    try std.testing.expect(std.mem.indexOf(u8, versioned_dir, "python") != null);
    try std.testing.expect(std.mem.indexOf(u8, versioned_dir, "3.13") != null);
}

test "cache lock RAII wrapper" {
    const allocator = std.testing.allocator;
    var cache = try Cache.init(allocator);
    defer cache.deinit();

    var lock = CacheLock.init(&cache);
    defer lock.deinit();

    try std.testing.expect(!lock.locked);
}

test "cache stats formatting" {
    const stats = CacheStats{
        .total_size = 1024 * 1024, // 1 MB
        .file_count = 10,
        .dir_count = 3,
    };

    var buffer: [256]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buffer, "{}", .{stats});
    try std.testing.expect(std.mem.indexOf(u8, formatted, "1.00 MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, formatted, "3") != null);
}