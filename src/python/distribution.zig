const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const paths_module = @import("../platform/paths.zig");
const http = @import("../platform/http.zig");
const extract = @import("../utils/extract.zig");

/// Target platform identification
pub const Platform = enum {
    linux,
    macos,
    windows,

    const Self = @This();

    /// Get the platform string for python-build-standalone URLs
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
            .windows => "tar.gz", // Windows builds also use tar.gz in python-build-standalone
        };
    }
};

/// Target architecture identification
pub const Architecture = enum {
    x86_64,
    aarch64,

    const Self = @This();

    /// Get the architecture string for python-build-standalone URLs
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

/// Python distribution information
pub const DistributionInfo = struct {
    python_version: []const u8,
    platform: Platform,
    architecture: Architecture,
    build_version: []const u8,

    /// Generate the filename for this distribution
    pub fn filename(self: *const DistributionInfo, allocator: std.mem.Allocator) ![]u8 {
        return try std.fmt.allocPrint(
            allocator,
            "cpython-{s}+{s}-{s}-{s}-install_only.{s}",
            .{
                self.python_version,
                self.build_version,
                self.architecture.toString(),
                self.platform.toString(),
                self.platform.archiveExtension(),
            }
        );
    }

    /// Generate the download URL for this distribution
    pub fn downloadUrl(self: *const DistributionInfo, allocator: std.mem.Allocator) ![]u8 {
        const build_config = config.BuildConfig{};
        const file_name = try self.filename(allocator);
        defer allocator.free(file_name);

        return try std.fmt.allocPrint(
            allocator,
            "{s}/{s}/{s}",
            .{ build_config.python_builds_base_url, self.build_version, file_name }
        );
    }
};

/// Python distribution manager
pub const DistributionManager = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    paths: paths_module.Paths,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        const http_config = http.Config{
            .max_retries = 3,
            .timeout_ms = 60000, // Longer timeout for large downloads
        };

        return Self{
            .allocator = allocator,
            .http_client = http.Client.init(allocator, http_config),
            .paths = paths_module.Paths.init(allocator),
        };
    }

    /// Get distribution info for the specified Python version (uses host platform)
    pub fn getDistributionInfo(self: *Self, python_version: []const u8) DistributionInfo {
        return self.getDistributionInfoForTarget(python_version, Platform.current(), Architecture.current());
    }

    /// Get distribution info for a specific target platform
    pub fn getDistributionInfoForTarget(self: *Self, python_version: []const u8, platform: Platform, arch: Architecture) DistributionInfo {
        _ = self;
        // Map major.minor versions to full versions available in releases
        const full_python_version = if (std.mem.eql(u8, python_version, "3.14"))
            "3.14.2"
        else if (std.mem.eql(u8, python_version, "3.13"))
            "3.13.11"
        else
            python_version;

        const build_version = "20251217"; // Latest release

        return DistributionInfo{
            .python_version = full_python_version,
            .platform = platform,
            .architecture = arch,
            .build_version = build_version,
        };
    }

    /// Check if a Python distribution is already cached
    pub fn isCached(self: *Self, python_version: []const u8) !bool {
        const install_dir = try self.paths.getPythonInstallDir(python_version);
        defer self.allocator.free(install_dir);

        // Check if the Python executable exists
        const python_exe = try self.paths.getPythonExecutablePath(install_dir);
        defer self.allocator.free(python_exe);

        std.fs.accessAbsolute(python_exe, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };

        return true;
    }

    /// Download a Python distribution if not already cached
    pub fn ensureDistribution(self: *Self, python_version: []const u8, progress_fn: ?http.ProgressFn) !void {
        // Check if already cached
        if (try self.isCached(python_version)) {
            std.log.info("Python {s} already cached", .{python_version});
            return;
        }

        // Downloading Python distribution

        const dist_info = self.getDistributionInfo(python_version);
        const download_url = try dist_info.downloadUrl(self.allocator);
        defer self.allocator.free(download_url);

        // Create downloads directory
        const downloads_dir = try self.paths.getDownloadsDir();
        defer self.allocator.free(downloads_dir);
        try self.paths.ensureDirExists(downloads_dir);

        // Download the archive
        const filename = try dist_info.filename(self.allocator);
        defer self.allocator.free(filename);

        const archive_path = try std.fs.path.join(self.allocator, &.{ downloads_dir, filename });
        defer self.allocator.free(archive_path);

        // Downloading from python-build-standalone
        try self.http_client.downloadFile(download_url, archive_path, progress_fn);

        // Extract to Python install directory
        const install_dir = try self.paths.getPythonInstallDir(python_version);
        defer self.allocator.free(install_dir);
        try self.paths.ensureDirExists(install_dir);

        std.log.info("Extracting Python distribution to: {s}", .{install_dir});
        try self.extractDistribution(archive_path, install_dir);

        // Verify the installation
        if (try self.isCached(python_version)) {
            std.log.info("Python {s} successfully installed", .{python_version});
        } else {
            return error.InstallationFailed;
        }
    }

    /// Download a Python distribution for a specific target platform
    pub fn ensureDistributionForTarget(
        self: *Self,
        python_version: []const u8,
        platform: Platform,
        arch: Architecture,
        progress_fn: ?http.ProgressFn,
    ) !void {
        // Check if already cached (use target-specific cache path)
        const cache_key = try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}", .{
            python_version,
            platform.toString(),
            arch.toString(),
        });
        defer self.allocator.free(cache_key);

        const install_dir = try self.getTargetInstallDir(python_version, platform, arch);
        defer self.allocator.free(install_dir);

        // Check if already cached
        const marker_path = try std.fs.path.join(self.allocator, &.{ install_dir, ".bundlr_complete" });
        defer self.allocator.free(marker_path);
        if (std.fs.accessAbsolute(marker_path, .{})) |_| {
            std.log.info("Python {s} for {s} already cached", .{ python_version, platform.toString() });
            return;
        } else |_| {}

        const dist_info = self.getDistributionInfoForTarget(python_version, platform, arch);
        const download_url = try dist_info.downloadUrl(self.allocator);
        defer self.allocator.free(download_url);

        // Create downloads directory
        const downloads_dir = try self.paths.getDownloadsDir();
        defer self.allocator.free(downloads_dir);
        try self.paths.ensureDirExists(downloads_dir);

        // Download the archive
        const filename = try dist_info.filename(self.allocator);
        defer self.allocator.free(filename);

        const archive_path = try std.fs.path.join(self.allocator, &.{ downloads_dir, filename });
        defer self.allocator.free(archive_path);

        std.log.info("Downloading Python {s} for {s}...", .{ python_version, platform.toString() });
        try self.http_client.downloadFile(download_url, archive_path, progress_fn);

        // Extract to target-specific install directory
        try self.paths.ensureDirExists(install_dir);

        std.log.info("Extracting Python distribution to: {s}", .{install_dir});
        try self.extractDistributionForTarget(archive_path, install_dir, platform);

        // Create completion marker
        const marker_file = std.fs.createFileAbsolute(marker_path, .{}) catch |err| {
            std.log.warn("Failed to create cache marker: {}", .{err});
            return;
        };
        marker_file.close();

        std.log.info("Python {s} for {s} successfully installed", .{ python_version, platform.toString() });
    }

    /// Get target-specific install directory
    fn getTargetInstallDir(self: *Self, python_version: []const u8, platform: Platform, arch: Architecture) ![]u8 {
        const cache_dir = try self.paths.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        const dir_name = try std.fmt.allocPrint(self.allocator, "{s}-{s}-{s}", .{
            python_version,
            platform.toString(),
            arch.toString(),
        });
        defer self.allocator.free(dir_name);

        return try std.fs.path.join(self.allocator, &.{ cache_dir, "python", dir_name });
    }

    /// Get Python executable path for a specific target platform
    pub fn getPythonExecutableForTarget(self: *Self, python_version: []const u8, platform: Platform, arch: Architecture) ![]u8 {
        const install_dir = try self.getTargetInstallDir(python_version, platform, arch);
        defer self.allocator.free(install_dir);

        // Windows: python.exe at root; Unix: bin/python3
        return switch (platform) {
            .windows => try std.fs.path.join(self.allocator, &.{ install_dir, "python.exe" }),
            else => try std.fs.path.join(self.allocator, &.{ install_dir, "bin", "python3" }),
        };
    }

    /// Extract a Python distribution archive
    fn extractDistribution(self: *Self, archive_path: []const u8, target_dir: []const u8) !void {
        std.log.info("Extracting {s} to {s}", .{ archive_path, target_dir });

        // Use system tools for extraction (tar/unzip)
        try extract.extractUsingSystemTools(self.allocator, target_dir, archive_path);

        // Python distributions typically extract to "python/install/" structure
        // We need to flatten this to have Python files at the root
        try self.flattenPythonDistribution(target_dir);
    }

    /// Extract a Python distribution archive for a specific target platform
    fn extractDistributionForTarget(self: *Self, archive_path: []const u8, target_dir: []const u8, target_platform: Platform) !void {
        std.log.info("Extracting {s} to {s}", .{ archive_path, target_dir });

        try extract.extractUsingSystemTools(self.allocator, target_dir, archive_path);

        // Flatten nested python/install/ structure
        try self.flattenPythonDistributionForTarget(target_dir, target_platform);
    }

    /// Flatten Python distribution structure after extraction
    /// Python distributions often extract to subdirectories that we need to restructure
    fn flattenPythonDistribution(self: *Self, target_dir: []const u8) !void {
        // Check if there's a single subdirectory that contains the Python installation
        var dir = std.fs.openDirAbsolute(target_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        // For MVP, just check for common Python directory patterns
        var iterator = dir.iterate();
        var found_python_dir: ?[]const u8 = null;
        var dir_count: u32 = 0;

        while (try iterator.next()) |entry| {
            if (entry.kind == .directory) {
                dir_count += 1;
                if (found_python_dir == null) {
                    found_python_dir = try self.allocator.dupe(u8, entry.name);
                } else {
                    // Multiple directories - just use the extracted directory as-is
                    if (found_python_dir) |prev_dir| {
                        self.allocator.free(prev_dir);
                    }
                    found_python_dir = null;
                    break;
                }
            }
        }
        defer if (found_python_dir) |dir_name| self.allocator.free(dir_name);

        // If there's exactly one subdirectory, check if it looks like a Python installation
        if (dir_count == 1 and found_python_dir != null) {
            const subdir_name = found_python_dir.?;
            const subdir_path = try std.fs.path.join(self.allocator, &.{ target_dir, subdir_name });
            defer self.allocator.free(subdir_path);

            // Check if this subdirectory contains Python installation files
            if (self.isPythonInstallationDir(subdir_path)) {
                // Move contents up one level
                try self.moveDirectoryContents(subdir_path, target_dir);
                // Remove the now-empty subdirectory
                std.fs.deleteDirAbsolute(subdir_path) catch {}; // Ignore errors
            }
        }
    }

    /// Check if a directory looks like a Python installation
    fn isPythonInstallationDir(self: *Self, dir_path: []const u8) bool {
        // Look for common Python installation markers
        const markers = switch (builtin.os.tag) {
            .windows => [_][]const u8{ "python.exe", "Scripts", "Lib" },
            else => [_][]const u8{ "bin", "lib", "include" },
        };

        for (markers) |marker| {
            const marker_path = std.fs.path.join(self.allocator, &.{ dir_path, marker }) catch continue;
            defer self.allocator.free(marker_path);

            std.fs.accessAbsolute(marker_path, .{}) catch continue;
            return true; // Found at least one marker
        }
        return false;
    }

    /// Flatten Python distribution for a specific target platform
    /// Handles python-build-standalone's nested python/install/ structure
    fn flattenPythonDistributionForTarget(self: *Self, target_dir: []const u8, target_platform: Platform) !void {
        // python-build-standalone extracts to: python/install/[actual files]
        // We need to move contents from python/install/ to target_dir

        // First, try the standard python/install path
        const python_install_path = try std.fs.path.join(self.allocator, &.{ target_dir, "python", "install" });
        defer self.allocator.free(python_install_path);

        if (self.isPythonInstallationDirForTarget(python_install_path, target_platform)) {
            std.log.info("Flattening python/install/ structure", .{});
            try self.moveDirectoryContents(python_install_path, target_dir);
            // Clean up empty directories
            std.fs.deleteDirAbsolute(python_install_path) catch {};
            const python_dir = try std.fs.path.join(self.allocator, &.{ target_dir, "python" });
            defer self.allocator.free(python_dir);
            std.fs.deleteDirAbsolute(python_dir) catch {};
            return;
        }

        // Fallback: try single subdirectory pattern
        var dir = std.fs.openDirAbsolute(target_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var iterator = dir.iterate();
        var found_subdir: ?[]const u8 = null;
        var dir_count: u32 = 0;

        while (try iterator.next()) |entry| {
            if (entry.kind == .directory) {
                dir_count += 1;
                if (found_subdir == null) {
                    found_subdir = try self.allocator.dupe(u8, entry.name);
                } else {
                    if (found_subdir) |prev| self.allocator.free(prev);
                    found_subdir = null;
                    break;
                }
            }
        }
        defer if (found_subdir) |name| self.allocator.free(name);

        if (dir_count == 1 and found_subdir != null) {
            const subdir_path = try std.fs.path.join(self.allocator, &.{ target_dir, found_subdir.? });
            defer self.allocator.free(subdir_path);

            if (self.isPythonInstallationDirForTarget(subdir_path, target_platform)) {
                try self.moveDirectoryContents(subdir_path, target_dir);
                std.fs.deleteDirAbsolute(subdir_path) catch {};
            }
        }
    }

    /// Check if a directory looks like a Python installation for target platform
    fn isPythonInstallationDirForTarget(self: *Self, dir_path: []const u8, target_platform: Platform) bool {
        const markers = switch (target_platform) {
            .windows => [_][]const u8{ "python.exe", "Scripts", "Lib" },
            else => [_][]const u8{ "bin", "lib", "include" },
        };

        for (markers) |marker| {
            const marker_path = std.fs.path.join(self.allocator, &.{ dir_path, marker }) catch continue;
            defer self.allocator.free(marker_path);

            std.fs.accessAbsolute(marker_path, .{}) catch continue;
            return true;
        }
        return false;
    }

    /// Move all contents from source directory to target directory
    fn moveDirectoryContents(self: *Self, source_dir: []const u8, target_dir: []const u8) !void {
        var source = std.fs.openDirAbsolute(source_dir, .{ .iterate = true }) catch return;
        defer source.close();

        var iterator = source.iterate();
        while (try iterator.next()) |entry| {
            const source_path = try std.fs.path.join(self.allocator, &.{ source_dir, entry.name });
            defer self.allocator.free(source_path);

            const target_path = try std.fs.path.join(self.allocator, &.{ target_dir, entry.name });
            defer self.allocator.free(target_path);

            switch (entry.kind) {
                .file => {
                    std.fs.copyFileAbsolute(source_path, target_path, .{}) catch {};
                    std.fs.deleteFileAbsolute(source_path) catch {};
                },
                .directory => {
                    // Recursively move directory - ensure target directory exists
                    try self.paths.ensureDirExists(target_path);
                    try self.moveDirectoryContents(source_path, target_path);
                    std.fs.deleteDirAbsolute(source_path) catch {};
                },
                else => {},
            }
        }
    }

    /// Get the Python executable path for a version
    pub fn getPythonExecutable(self: *Self, python_version: []const u8) ![]u8 {
        const install_dir = try self.paths.getPythonInstallDir(python_version);
        defer self.allocator.free(install_dir);
        const exe_path = try self.paths.getPythonExecutablePath(install_dir);
        defer self.allocator.free(exe_path);
        return try self.allocator.dupe(u8, exe_path);
    }

    /// List available Python versions in the cache
    pub fn listCachedVersions(self: *Self) !std.ArrayList([]const u8) {
        var versions = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (versions.items) |version| {
                self.allocator.free(version);
            }
            versions.deinit();
        }

        const cache_dir = try self.paths.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        const python_cache_dir = try std.fs.path.join(self.allocator, &.{ cache_dir, "python" });
        defer self.allocator.free(python_cache_dir);

        var dir = std.fs.openDirAbsolute(python_cache_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return versions, // Empty list if directory doesn't exist
            else => return err,
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .directory) {
                const version_copy = try self.allocator.dupe(u8, entry.name);
                try versions.append(version_copy);
            }
        }

        return versions;
    }
};

// Tests
test "platform detection" {
    const platform = Platform.current();
    const platform_str = platform.toString();
    try std.testing.expect(platform_str.len > 0);

    // Test archive extension
    const ext = platform.archiveExtension();
    try std.testing.expect(std.mem.eql(u8, ext, "tar.gz"));
}

test "architecture detection" {
    const arch = Architecture.current();
    const arch_str = arch.toString();
    try std.testing.expect(arch_str.len > 0);
}

test "distribution info creation" {
    const allocator = std.testing.allocator;

    const dist_info = DistributionInfo{
        .python_version = "3.14.0",
        .platform = .linux,
        .architecture = .x86_64,
        .build_version = "20241016",
    };

    const filename = try dist_info.filename(allocator);
    defer allocator.free(filename);

    try std.testing.expect(std.mem.indexOf(u8, filename, "3.14.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, filename, "x86_64") != null);
    try std.testing.expect(std.mem.indexOf(u8, filename, "unknown-linux-gnu") != null);
    try std.testing.expect(std.mem.endsWith(u8, filename, ".tar.gz"));
}

test "distribution manager initialization" {
    const allocator = std.testing.allocator;
    const manager = DistributionManager.init(allocator);

    try std.testing.expect(manager.allocator.vtable == allocator.vtable);
}

test "distribution info URL generation" {
    const allocator = std.testing.allocator;

    const dist_info = DistributionInfo{
        .python_version = "3.14.0",
        .platform = .linux,
        .architecture = .x86_64,
        .build_version = "20241016",
    };

    const url = try dist_info.downloadUrl(allocator);
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "github.com/indygreg/python-build-standalone") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "3.14.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "20241016") != null);
}