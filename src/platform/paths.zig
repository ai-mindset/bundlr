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

                // Look for python3.x executable
                var iterator = dir.iterate();
                while (try iterator.next()) |entry| {
                    if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "python3.")) {
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