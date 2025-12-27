//! UV bootstrap manager - Downloads and manages uv installations
//! Similar to Python distribution management but for uv package manager

const std = @import("std");
const builtin = @import("builtin");
const paths_module = @import("../platform/paths.zig");
const http = @import("../platform/http.zig");
const extract = @import("../utils/extract.zig");

/// Fallback UV version if GitHub API call fails
pub const FALLBACK_UV_VERSION = "0.9.18";

/// Get the latest uv version from GitHub API
pub fn getLatestUvVersion(allocator: std.mem.Allocator, paths: *paths_module.Paths) ![]u8 {
    var http_client = http.Client.init(allocator, http.Config{});

    // Use a temporary file for the API response
    const cache_dir = try paths.getBundlrCacheDir();
    defer allocator.free(cache_dir);

    // Ensure cache directory exists
    try paths.ensureDirExists(cache_dir);
    const temp_file = try std.fs.path.join(allocator, &[_][]const u8{ cache_dir, "uv_version.json" });
    defer allocator.free(temp_file);

    // Try to fetch latest version from GitHub API
    const api_url = "https://api.github.com/repos/astral-sh/uv/releases/latest";

    http_client.downloadFile(api_url, temp_file, null) catch |err| {
        std.log.warn("Failed to fetch latest uv version: {}. Using fallback {s}", .{ err, FALLBACK_UV_VERSION });
        return try allocator.dupe(u8, FALLBACK_UV_VERSION);
    };

    // Read and parse the JSON response
    const file = std.fs.openFileAbsolute(temp_file, .{}) catch |err| {
        std.log.warn("Failed to read uv version file: {}. Using fallback {s}", .{ err, FALLBACK_UV_VERSION });
        return try allocator.dupe(u8, FALLBACK_UV_VERSION);
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        std.log.warn("Failed to read uv version response: {}. Using fallback {s}", .{ err, FALLBACK_UV_VERSION });
        return try allocator.dupe(u8, FALLBACK_UV_VERSION);
    };
    defer allocator.free(content);

    // Simple JSON parsing for "tag_name" field
    // Look for "tag_name":"v1.2.3" pattern
    const tag_start = std.mem.indexOf(u8, content, "\"tag_name\":\"") orelse {
        std.log.warn("Could not parse uv version from GitHub API. Using fallback {s}", .{FALLBACK_UV_VERSION});
        return try allocator.dupe(u8, FALLBACK_UV_VERSION);
    };

    const version_start = tag_start + "\"tag_name\":\"".len;
    const version_end = std.mem.indexOfPos(u8, content, version_start, "\"") orelse {
        std.log.warn("Could not parse uv version from GitHub API. Using fallback {s}", .{FALLBACK_UV_VERSION});
        return try allocator.dupe(u8, FALLBACK_UV_VERSION);
    };

    const version_with_v = content[version_start..version_end];

    // Remove 'v' prefix if present (e.g., "v0.9.18" -> "0.9.18")
    const version = if (std.mem.startsWith(u8, version_with_v, "v"))
        version_with_v[1..]
    else
        version_with_v;

    // Clean up temp file
    std.fs.deleteFileAbsolute(temp_file) catch {};

    return try allocator.dupe(u8, version);
}

/// Target platform identification for uv releases
pub const Platform = enum {
    linux,
    macos,
    windows,

    const Self = @This();

    /// Get the platform string for uv release URLs
    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .linux => "unknown-linux-gnu",
            .macos => "apple-darwin",
            .windows => "pc-windows-msvc",
        };
    }

    /// Get the current platform
    pub fn current() Self {
        return switch (builtin.os.tag) {
            .linux => .linux,
            .macos => .macos,
            .windows => .windows,
            else => .linux, // Default fallback
        };
    }

    /// Get the archive extension for this platform
    pub fn archiveExtension(self: Self) []const u8 {
        return switch (self) {
            .linux, .macos => "tar.gz",
            .windows => "zip", // Windows uv releases use zip
        };
    }
};

/// Target architecture identification for uv releases
pub const Architecture = enum {
    x86_64,
    aarch64,

    const Self = @This();

    /// Get the architecture string for uv release URLs
    pub fn toString(self: Self) []const u8 {
        return switch (self) {
            .x86_64 => "x86_64",
            .aarch64 => "aarch64",
        };
    }

    /// Get the current architecture
    pub fn current() Self {
        return switch (builtin.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            else => .x86_64, // Default fallback
        };
    }
};

/// UV distribution information
pub const UvDistributionInfo = struct {
    version: []const u8,
    platform: Platform,
    architecture: Architecture,

    /// Generate the filename for this uv distribution
    pub fn filename(self: *const UvDistributionInfo, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "uv-{s}-{s}.{s}",
            .{
                self.architecture.toString(),
                self.platform.toString(),
                self.platform.archiveExtension(),
            },
        );
    }

    /// Generate the download URL for this uv distribution
    pub fn downloadUrl(self: *const UvDistributionInfo, allocator: std.mem.Allocator) ![]u8 {
        const filename_str = try self.filename(allocator);
        defer allocator.free(filename_str);

        return try std.fmt.allocPrint(
            allocator,
            "https://github.com/astral-sh/uv/releases/download/{s}/{s}",
            .{ self.version, filename_str },
        );
    }
};

/// UV bootstrap manager - handles download and installation of uv
pub const UvManager = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    paths: paths_module.Paths,

    pub fn init(allocator: std.mem.Allocator) UvManager {
        return UvManager{
            .allocator = allocator,
            .http_client = http.Client.init(allocator, http.Config{}),
            .paths = paths_module.Paths.init(allocator),
        };
    }

    /// Check if uv is already installed and cached
    pub fn isCached(self: *UvManager, version: []const u8) !bool {
        const uv_exe = try self.getUvExecutable(version);
        defer self.allocator.free(uv_exe);

        // Check if the executable exists
        std.fs.accessAbsolute(uv_exe, .{}) catch return false;
        return true;
    }

    /// Ensure uv is installed, downloading if necessary
    pub fn ensureUvInstalled(self: *UvManager, progress_fn: ?http.ProgressFn) ![]u8 {
        // Get the latest version
        const latest_version = try getLatestUvVersion(self.allocator, &self.paths);
        errdefer self.allocator.free(latest_version);

        if (try self.isCached(latest_version)) {
            return latest_version; // Already installed, return version
        }

        // Download and install uv
        try self.downloadUv(latest_version, progress_fn);
        return latest_version;
    }

    /// Download and install uv
    fn downloadUv(self: *UvManager, version: []const u8, progress_fn: ?http.ProgressFn) !void {
        const dist_info = UvDistributionInfo{
            .version = version,
            .platform = Platform.current(),
            .architecture = Architecture.current(),
        };

        // Get download URL
        const download_url = try dist_info.downloadUrl(self.allocator);
        defer self.allocator.free(download_url);

        // Get archive filename
        const archive_filename = try dist_info.filename(self.allocator);
        defer self.allocator.free(archive_filename);

        // Get cache directory paths
        const cache_dir = try self.paths.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        const downloads_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_dir, "downloads" });
        defer self.allocator.free(downloads_dir);

        // Ensure downloads directory exists (create parent directories if needed)
        try self.paths.ensureDirExists(downloads_dir);

        const archive_path = try std.fs.path.join(self.allocator, &[_][]const u8{ downloads_dir, archive_filename });
        defer self.allocator.free(archive_path);

        // Download the archive
        try self.http_client.downloadFile(download_url, archive_path, progress_fn);

        // Extract the archive to uv cache directory
        try self.extractUv(archive_path, version);
    }

    /// Extract uv archive to installation directory
    fn extractUv(self: *UvManager, archive_path: []const u8, version: []const u8) !void {
        const cache_dir = try self.paths.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        const uv_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_dir, "uv" });
        defer self.allocator.free(uv_dir);

        const version_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ uv_dir, version });
        defer self.allocator.free(version_dir);

        // Ensure version directory exists (create parent directories if needed)
        try self.paths.ensureDirExists(version_dir);

        // Extract archive - use the generic extractUsingSystemTools function
        try extract.extractUsingSystemTools(self.allocator, version_dir, archive_path);

        // Make uv executable (Unix-like systems)
        if (comptime builtin.os.tag != .windows) {
            const uv_exe = try self.getUvExecutable(version);
            defer self.allocator.free(uv_exe);

            // Set executable permissions
            const file = std.fs.openFileAbsolute(uv_exe, .{ .mode = .read_write }) catch return;
            defer file.close();

            try file.chmod(0o755);
        }
    }

    /// Get the path to the uv executable
    pub fn getUvExecutable(self: *UvManager, version: []const u8) ![]u8 {
        const cache_dir = try self.paths.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        const uv_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_dir, "uv", version });
        defer self.allocator.free(uv_dir);

        // The extraction creates a subdirectory like "uv-x86_64-unknown-linux-gnu"
        // Find the actual uv executable inside this subdirectory
        var dir = std.fs.openDirAbsolute(uv_dir, .{ .iterate = true }) catch {
            // If can't open directory, fallback to direct path
            const platform = Platform.current();
            const executable_name = switch (platform) {
                .windows => "uv.exe",
                .linux, .macos => "uv",
            };
            return try std.fs.path.join(self.allocator, &[_][]const u8{ uv_dir, executable_name });
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .directory) {
                // Found subdirectory, check for uv executable inside
                const sub_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ uv_dir, entry.name });
                defer self.allocator.free(sub_dir);

                const platform = Platform.current();
                const executable_name = switch (platform) {
                    .windows => "uv.exe",
                    .linux, .macos => "uv",
                };

                const uv_exe = try std.fs.path.join(self.allocator, &[_][]const u8{ sub_dir, executable_name });
                // Check if executable exists
                std.fs.accessAbsolute(uv_exe, .{}) catch {
                    self.allocator.free(uv_exe);
                    continue;
                };
                return uv_exe;
            }
        }

        // Fallback to direct path if no subdirectory found
        const platform = Platform.current();
        const executable_name = switch (platform) {
            .windows => "uv.exe",
            .linux, .macos => "uv",
        };
        return try std.fs.path.join(self.allocator, &[_][]const u8{ uv_dir, executable_name });
    }

    /// Check if uv is installed on the system PATH (fallback)
    pub fn isSystemUvAvailable(self: *UvManager) bool {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &[_][]const u8{ "uv", "--version" },
        }) catch return false;

        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        return result.term == .Exited and result.term.Exited == 0;
    }
};

// Tests
test "uv platform detection" {
    const platform = Platform.current();
    const arch = Architecture.current();

    // Just test that we can get platform strings
    _ = platform.toString();
    _ = arch.toString();
    _ = platform.archiveExtension();
}

test "uv distribution info" {
    const allocator = std.testing.allocator;

    const dist_info = UvDistributionInfo{
        .version = "0.9.18",
        .platform = .linux,
        .architecture = .x86_64,
    };

    const filename_str = try dist_info.filename(allocator);
    defer allocator.free(filename_str);

    try std.testing.expectEqualStrings("uv-x86_64-unknown-linux-gnu.tar.gz", filename_str);

    const url = try dist_info.downloadUrl(allocator);
    defer allocator.free(url);

    const expected_url = "https://github.com/astral-sh/uv/releases/download/0.9.18/uv-x86_64-unknown-linux-gnu.tar.gz";
    try std.testing.expectEqualStrings(expected_url, url);
}

test "uv manager creation" {
    const allocator = std.testing.allocator;
    var manager = UvManager.init(allocator);
    defer manager.deinit();

    // Test basic functionality
    try std.testing.expect(manager.allocator.vtable == allocator.vtable);
}

