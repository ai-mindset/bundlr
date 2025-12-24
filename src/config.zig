//! Configuration management for bundlr
//! Handles both build-time (comptime) and runtime configuration

const std = @import("std");

/// Build-time configuration options
/// These are set during compilation using environment variables or build options
pub const BuildConfig = struct {
    /// Default Python version to use if not specified
    default_python_version: []const u8 = "3.13",

    /// Default cache directory name
    cache_dir_name: []const u8 = "bundlr_cache",

    /// Maximum download timeout in seconds
    download_timeout_seconds: u32 = 300,

    /// Python build standalone base URL for distributions
    python_builds_base_url: []const u8 = "https://github.com/astral-sh/python-build-standalone/releases/download",

    /// Maximum cache size in MB (0 = unlimited)
    max_cache_size_mb: u32 = 1024,
};

/// Runtime configuration for a Python application
pub const RuntimeConfig = struct {
    allocator: std.mem.Allocator,

    // Project configuration
    project_name: []const u8,
    project_version: []const u8,
    python_version: []const u8,

    // Optional configuration
    requirements: ?[]const []const u8 = null,
    entry_point: ?[]const u8 = null,
    args: ?[]const []const u8 = null,

    // Cache configuration
    cache_dir: ?[]const u8 = null,
    force_reinstall: bool = false,

    pub fn deinit(self: *RuntimeConfig) void {
        // Free any allocated memory
        if (self.cache_dir) |cache_dir| {
            self.allocator.free(cache_dir);
        }
        // Free the strings allocated by create() and parseFromEnv()
        self.allocator.free(self.project_name);
        self.allocator.free(self.project_version);
        self.allocator.free(self.python_version);
    }
};

/// Environment variable configuration keys
pub const EnvVars = struct {
    pub const PROJECT_NAME = "BUNDLR_PROJECT_NAME";
    pub const PROJECT_VERSION = "BUNDLR_PROJECT_VERSION";
    pub const PYTHON_VERSION = "BUNDLR_PYTHON_VERSION";
    pub const REQUIREMENTS = "BUNDLR_REQUIREMENTS";
    pub const ENTRY_POINT = "BUNDLR_ENTRY_POINT";
    pub const CACHE_DIR = "BUNDLR_CACHE_DIR";
    pub const FORCE_REINSTALL = "BUNDLR_FORCE_REINSTALL";
};

/// Parse runtime configuration from environment variables
pub fn parseFromEnv(allocator: std.mem.Allocator) !RuntimeConfig {
    const project_name = std.process.getEnvVarOwned(allocator, EnvVars.PROJECT_NAME) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.MissingProjectName,
        else => return err,
    };
    errdefer allocator.free(project_name);

    const project_version = std.process.getEnvVarOwned(allocator, EnvVars.PROJECT_VERSION) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, "1.0.0"),
        else => return err,
    };
    errdefer allocator.free(project_version);

    const build_config = BuildConfig{};
    const python_version = std.process.getEnvVarOwned(allocator, EnvVars.PYTHON_VERSION) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, build_config.default_python_version),
        else => return err,
    };
    errdefer allocator.free(python_version);

    // Optional cache directory override
    const cache_dir = std.process.getEnvVarOwned(allocator, EnvVars.CACHE_DIR) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };

    // Parse force reinstall flag
    const force_reinstall = if (std.process.getEnvVarOwned(allocator, EnvVars.FORCE_REINSTALL) catch null) |val| blk: {
        defer allocator.free(val);
        break :blk std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "yes");
    } else false;

    return RuntimeConfig{
        .allocator = allocator,
        .project_name = project_name,
        .project_version = project_version,
        .python_version = python_version,
        .cache_dir = cache_dir,
        .force_reinstall = force_reinstall,
    };
}

/// Validate that required configuration is present and valid
pub fn validate(config: *const RuntimeConfig) !void {
    // Validate project name
    if (config.project_name.len == 0) {
        return error.InvalidProjectName;
    }

    // Validate Python version format (basic check)
    if (config.python_version.len < 3 or config.python_version[1] != '.') {
        return error.InvalidPythonVersion;
    }

    // Validate project version is not empty
    if (config.project_version.len == 0) {
        return error.InvalidProjectVersion;
    }
}

/// Create a runtime config with explicit values (for testing/programmatic use)
pub fn create(
    allocator: std.mem.Allocator,
    project_name: []const u8,
    project_version: []const u8,
    python_version: []const u8,
) !RuntimeConfig {
    return RuntimeConfig{
        .allocator = allocator,
        .project_name = try allocator.dupe(u8, project_name),
        .project_version = try allocator.dupe(u8, project_version),
        .python_version = try allocator.dupe(u8, python_version),
    };
}

// Tests
test "build config defaults" {
    const config = BuildConfig{};
    try std.testing.expectEqualStrings("3.13", config.default_python_version);
    try std.testing.expectEqualStrings("bundlr_cache", config.cache_dir_name);
    try std.testing.expect(config.download_timeout_seconds == 300);
}

test "runtime config creation" {
    const allocator = std.testing.allocator;
    var config = try create(allocator, "test-app", "1.0.0", "3.13");
    defer config.deinit();

    try std.testing.expectEqualStrings("test-app", config.project_name);
    try std.testing.expectEqualStrings("1.0.0", config.project_version);
    try std.testing.expectEqualStrings("3.13", config.python_version);
}

test "config validation" {
    const allocator = std.testing.allocator;

    // Valid config
    var valid_config = try create(allocator, "test", "1.0.0", "3.13");
    defer valid_config.deinit();
    try validate(&valid_config);

    // Invalid project name
    var invalid_name_config = RuntimeConfig{
        .allocator = allocator,
        .project_name = "",
        .project_version = "1.0.0",
        .python_version = "3.12",
    };
    try std.testing.expectError(error.InvalidProjectName, validate(&invalid_name_config));

    // Invalid Python version
    var invalid_python_config = RuntimeConfig{
        .allocator = allocator,
        .project_name = "test",
        .project_version = "1.0.0",
        .python_version = "invalid",
    };
    try std.testing.expectError(error.InvalidPythonVersion, validate(&invalid_python_config));
}