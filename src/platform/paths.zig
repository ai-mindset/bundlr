//! Cross-platform path handling for bundlr
//! Manages cache directories, Python installation paths, and temporary directories

const std = @import("std");
const config = @import("../config.zig");
const builtin = @import("builtin");

/// Cross-platform path utilities
pub const Paths = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Paths {
        return Paths{ .allocator = allocator };
    }

    /// Get the system's cache directory
    /// On Windows: %LOCALAPPDATA% or %TEMP%
    /// On macOS: ~/Library/Caches
    /// On Linux: $XDG_CACHE_HOME or ~/.cache
    pub fn getSystemCacheDir(self: *Paths) ![]const u8 {
        switch (builtin.os.tag) {
            .windows => {
                // Try LOCALAPPDATA first, then TEMP
                return std.process.getEnvVarOwned(self.allocator, "LOCALAPPDATA") catch
                    std.process.getEnvVarOwned(self.allocator, "TEMP") catch
                    try self.allocator.dupe(u8, "C:\\Temp");
            },
            .macos => {
                // Try to get HOME and append Library/Caches
                const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch
                    return error.HomeDirectoryNotFound;
                defer self.allocator.free(home);
                return try std.fs.path.join(self.allocator, &.{ home, "Library", "Caches" });
            },
            .linux => {
                // Try XDG_CACHE_HOME first, then HOME/.cache
                if (std.process.getEnvVarOwned(self.allocator, "XDG_CACHE_HOME")) |xdg_cache| {
                    return xdg_cache;
                } else |_| {
                    const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch
                        return error.HomeDirectoryNotFound;
                    defer self.allocator.free(home);
                    return try std.fs.path.join(self.allocator, &.{ home, ".cache" });
                }
            },
            else => {
                // Fallback for other Unix-like systems
                return self.getTemporaryDir();
            },
        }
    }

    /// Get bundlr's cache directory (system cache + bundlr subfolder)
    pub fn getBundlrCacheDir(self: *Paths) ![]const u8 {
        // Allow override via environment variable
        if (std.process.getEnvVarOwned(self.allocator, config.EnvVars.CACHE_DIR)) |custom_cache| {
            return custom_cache;
        } else |_| {
            // Use system cache directory + bundlr subfolder
            const system_cache = try self.getSystemCacheDir();
            defer self.allocator.free(system_cache);
            const build_config = config.BuildConfig{};
            return try std.fs.path.join(self.allocator, &.{ system_cache, build_config.cache_dir_name });
        }
    }

    /// Get temporary directory for the system
    pub fn getTemporaryDir(self: *Paths) ![]const u8 {
        switch (builtin.os.tag) {
            .windows => {
                return std.process.getEnvVarOwned(self.allocator, "TMP") catch
                    std.process.getEnvVarOwned(self.allocator, "TEMP") catch
                    try self.allocator.dupe(u8, "C:\\Temp");
            },
            else => {
                return std.process.getEnvVarOwned(self.allocator, "TMPDIR") catch
                    std.process.getEnvVarOwned(self.allocator, "TMP") catch
                    try self.allocator.dupe(u8, "/tmp");
            },
        }
    }

    /// Get Python installation directory within bundlr cache
    pub fn getPythonInstallDir(self: *Paths, python_version: []const u8) ![]const u8 {
        const cache_dir = try self.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);
        return try std.fs.path.join(self.allocator, &.{ cache_dir, "python", python_version });
    }

    /// Get virtual environment directory for a project
    pub fn getVenvDir(self: *Paths, project_name: []const u8, python_version: []const u8) ![]const u8 {
        const cache_dir = try self.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        // Create a unique venv name that includes both project and Python version
        var venv_name_buf: [256]u8 = undefined;
        const venv_name = try std.fmt.bufPrint(&venv_name_buf, "{s}-py{s}", .{ project_name, python_version });

        return try std.fs.path.join(self.allocator, &.{ cache_dir, "venvs", venv_name });
    }

    /// Get downloads directory for Python distributions
    pub fn getDownloadsDir(self: *Paths) ![]const u8 {
        const cache_dir = try self.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);
        return try std.fs.path.join(self.allocator, &.{ cache_dir, "downloads" });
    }

    /// Ensure a directory exists (create if it doesn't)
    pub fn ensureDirExists(self: *Paths, dir_path: []const u8) !void {

        // Use makeDirAbsolute with recursive creation by building path step by step
        if (std.fs.path.isAbsolute(dir_path)) {
            // Get parent directory and ensure it exists first
            if (std.fs.path.dirname(dir_path)) |parent| {
                // Check if we've reached the root (different formats on different platforms)
                const is_root = switch (builtin.os.tag) {
                    .windows => parent.len <= 3 and (std.mem.endsWith(u8, parent, ":\\") or std.mem.eql(u8, parent, "\\\\")),
                    else => std.mem.eql(u8, parent, "/"),
                };

                if (!is_root and !std.mem.eql(u8, parent, dir_path)) {
                    try self.ensureDirExists(parent);
                }
            }

            // Now try to create the target directory
            std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        } else {
            // For relative paths, use makePath which creates parent directories
            try std.fs.cwd().makePath(dir_path);
        }
    }

    /// Get the Python executable path within an installation
    pub fn getPythonExecutablePath(self: *Paths, python_install_dir: []const u8) ![]const u8 {
        switch (builtin.os.tag) {
            .windows => {
                return try std.fs.path.join(self.allocator, &.{ python_install_dir, "python.exe" });
            },
            else => {
                // First try to find version-specific executable (e.g., python3.13)
                const bin_dir = try std.fs.path.join(self.allocator, &.{ python_install_dir, "bin" });
                defer self.allocator.free(bin_dir);

                var dir = std.fs.openDirAbsolute(bin_dir, .{ .iterate = true }) catch {
                    return try std.fs.path.join(self.allocator, &.{ python_install_dir, "bin", "python3" });
                };
                defer dir.close();

                // Look for python3.x executable (exclude -config scripts)
                var iterator = dir.iterate();
                while (try iterator.next()) |entry| {
                    if (entry.kind == .file and
                        std.mem.startsWith(u8, entry.name, "python3.") and
                        !std.mem.endsWith(u8, entry.name, "-config")) {
                        return try std.fs.path.join(self.allocator, &.{ python_install_dir, "bin", entry.name });
                    }
                }

                // Fallback to python3
                return try std.fs.path.join(self.allocator, &.{ python_install_dir, "bin", "python3" });
            },
        }
    }
};

// Legacy compatibility function - migrates the old getCacheDir behavior
pub fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    var paths = Paths.init(allocator);
    return try paths.getBundlrCacheDir();
}

// Tests
test "paths initialization" {
    const allocator = std.testing.allocator;
    const paths = Paths.init(allocator);
    try std.testing.expect(paths.allocator.vtable == allocator.vtable);
}

test "temporary directory retrieval" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const temp_dir = try paths.getTemporaryDir();
    defer allocator.free(temp_dir);

    try std.testing.expect(temp_dir.len > 0);
    // On most systems, temp dir should contain "tmp" or "Temp"
    const lower_temp = std.ascii.toLower(temp_dir[0]);
    _ = lower_temp; // Suppress unused variable warning
}

test "bundlr cache directory" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const cache_dir = try paths.getBundlrCacheDir();
    defer allocator.free(cache_dir);

    try std.testing.expect(cache_dir.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, cache_dir, "bundlr_cache") != null);
}

test "python install directory" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const install_dir = try paths.getPythonInstallDir("3.13");
    defer allocator.free(install_dir);

    try std.testing.expect(std.mem.indexOf(u8, install_dir, "python") != null);
    try std.testing.expect(std.mem.indexOf(u8, install_dir, "3.13") != null);
}

test "venv directory naming" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const venv_dir = try paths.getVenvDir("myapp", "3.13");
    defer allocator.free(venv_dir);

    try std.testing.expect(std.mem.indexOf(u8, venv_dir, "venvs") != null);
    try std.testing.expect(std.mem.indexOf(u8, venv_dir, "myapp-py3.13") != null);
}

test "python executable path" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const python_dir = "/opt/python/3.13";
    const exe_path = try paths.getPythonExecutablePath(python_dir);
    defer allocator.free(exe_path);

    switch (builtin.os.tag) {
        .windows => try std.testing.expect(std.mem.endsWith(u8, exe_path, "python.exe")),
        else => try std.testing.expect(std.mem.endsWith(u8, exe_path, "python3")),
    }
}

test "legacy getCacheDir compatibility" {
    const allocator = std.testing.allocator;
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    try std.testing.expect(cache_dir.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, cache_dir, "bundlr_cache") != null);
}

test "ensureDirExists creates nested cache directories" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const temp_dir = try paths.getTemporaryDir();
    defer allocator.free(temp_dir);

    const test_cache_dir = try std.fs.path.join(allocator, &.{ temp_dir, "bundlr_cache_test" });
    defer allocator.free(test_cache_dir);

    const nested_dir = try std.fs.path.join(allocator, &.{ test_cache_dir, "level1", "level2", "level3" });
    defer allocator.free(nested_dir);

    // Cleanup before test
    std.fs.deleteTreeAbsolute(test_cache_dir) catch {};
    defer std.fs.deleteTreeAbsolute(test_cache_dir) catch {};

    // Test that ensureDirExists creates the full path
    try paths.ensureDirExists(nested_dir);

    // Verify all levels exist
    std.fs.accessAbsolute(test_cache_dir, .{}) catch unreachable;
    std.fs.accessAbsolute(nested_dir, .{}) catch unreachable;
}

test "ensureDirExists handles absolute and relative paths correctly" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const temp_dir = try paths.getTemporaryDir();
    defer allocator.free(temp_dir);

    // Test absolute path
    const abs_test_dir = try std.fs.path.join(allocator, &.{ temp_dir, "abs_cache_test", "subdir" });
    defer allocator.free(abs_test_dir);

    std.fs.deleteTreeAbsolute(abs_test_dir) catch {};
    defer std.fs.deleteTreeAbsolute(abs_test_dir) catch {};

    try paths.ensureDirExists(abs_test_dir);
    std.fs.accessAbsolute(abs_test_dir, .{}) catch unreachable;

    // Test relative path (from current working directory)
    const rel_test_dir = "test_rel_cache/subdir";
    std.fs.cwd().deleteTree(rel_test_dir) catch {};
    defer std.fs.cwd().deleteTree("test_rel_cache") catch {};

    try paths.ensureDirExists(rel_test_dir);
    std.fs.cwd().access(rel_test_dir, .{}) catch unreachable;
}

test "getBundlrCacheDir returns platform-appropriate paths" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const cache_dir = try paths.getBundlrCacheDir();
    defer allocator.free(cache_dir);

    // Verify cache directory path is non-empty and contains expected components
    try std.testing.expect(cache_dir.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, cache_dir, "bundlr_cache") != null);

    // Test platform-specific path characteristics
    switch (builtin.os.tag) {
        .windows => {
            // Windows paths should contain drive letters or UNC paths
            const has_drive_letter = cache_dir.len >= 3 and cache_dir[1] == ':';
            const has_unc_path = std.mem.startsWith(u8, cache_dir, "\\\\");
            try std.testing.expect(has_drive_letter or has_unc_path);
        },
        .macos => {
            // macOS should use ~/Library/Caches
            try std.testing.expect(std.mem.indexOf(u8, cache_dir, "Library/Caches") != null or
                                  std.mem.indexOf(u8, cache_dir, "/tmp") != null);
        },
        .linux => {
            // Linux should use ~/.cache or $XDG_CACHE_HOME
            try std.testing.expect(std.mem.indexOf(u8, cache_dir, ".cache") != null or
                                  std.mem.indexOf(u8, cache_dir, "/tmp") != null);
        },
        else => {
            // Other Unix-like systems should fallback to /tmp
            try std.testing.expect(std.mem.indexOf(u8, cache_dir, "/tmp") != null);
        },
    }
}

test "cache directories are writable after creation" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const temp_dir = try paths.getTemporaryDir();
    defer allocator.free(temp_dir);

    const test_subdir = try std.fs.path.join(allocator, &.{ temp_dir, "bundlr_write_test" });
    defer allocator.free(test_subdir);

    // Clean up before test
    std.fs.deleteTreeAbsolute(test_subdir) catch {};
    defer std.fs.deleteTreeAbsolute(test_subdir) catch {};

    // Create the directory structure
    try paths.ensureDirExists(test_subdir);

    // Test that we can write to the directory
    const test_file = try std.fs.path.join(allocator, &.{ test_subdir, "test_file.txt" });
    defer allocator.free(test_file);

    const file = try std.fs.createFileAbsolute(test_file, .{});
    defer file.close();
    try file.writeAll("Test cache directory write");

    // Verify we can read it back
    const read_file = try std.fs.openFileAbsolute(test_file, .{});
    defer read_file.close();

    var buffer: [100]u8 = undefined;
    const bytes_read = try read_file.readAll(&buffer);
    try std.testing.expectEqualStrings("Test cache directory write", buffer[0..bytes_read]);
}

test "bundlr cache structure creation" {
    const allocator = std.testing.allocator;
    var paths = Paths.init(allocator);

    const temp_dir = try paths.getTemporaryDir();
    defer allocator.free(temp_dir);

    const test_cache = try std.fs.path.join(allocator, &.{ temp_dir, "test_bundlr_cache" });
    defer allocator.free(test_cache);

    // Clean up before test
    std.fs.deleteTreeAbsolute(test_cache) catch {};
    defer std.fs.deleteTreeAbsolute(test_cache) catch {};

    // Test all bundlr cache subdirectory structures
    const python_dir = try std.fs.path.join(allocator, &.{ test_cache, "python", "3.13" });
    defer allocator.free(python_dir);

    const downloads_dir = try std.fs.path.join(allocator, &.{ test_cache, "downloads" });
    defer allocator.free(downloads_dir);

    const venv_dir = try std.fs.path.join(allocator, &.{ test_cache, "venvs", "myapp-py3.13" });
    defer allocator.free(venv_dir);

    const git_archives_dir = try std.fs.path.join(allocator, &.{ test_cache, "git_archives" });
    defer allocator.free(git_archives_dir);

    const git_extracts_dir = try std.fs.path.join(allocator, &.{ test_cache, "git_extracts", "project-12345" });
    defer allocator.free(git_extracts_dir);

    const uv_dir = try std.fs.path.join(allocator, &.{ test_cache, "uv", "0.9.18" });
    defer allocator.free(uv_dir);

    // Create all directory structures
    try paths.ensureDirExists(python_dir);
    try paths.ensureDirExists(downloads_dir);
    try paths.ensureDirExists(venv_dir);
    try paths.ensureDirExists(git_archives_dir);
    try paths.ensureDirExists(git_extracts_dir);
    try paths.ensureDirExists(uv_dir);

    // Verify all directories exist
    std.fs.accessAbsolute(python_dir, .{}) catch unreachable;
    std.fs.accessAbsolute(downloads_dir, .{}) catch unreachable;
    std.fs.accessAbsolute(venv_dir, .{}) catch unreachable;
    std.fs.accessAbsolute(git_archives_dir, .{}) catch unreachable;
    std.fs.accessAbsolute(git_extracts_dir, .{}) catch unreachable;
    std.fs.accessAbsolute(uv_dir, .{}) catch unreachable;
}