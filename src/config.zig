//! Configuration management for bundlr
//! Handles both build-time (comptime) and runtime configuration

const std = @import("std");

/// Build-time configuration options
/// These are set during compilation using environment variables or build options
pub const BuildConfig = struct {
    /// Default Python version to use if not specified
    default_python_version: []const u8 = "3.14",

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

    // Source mode detection
    source_mode: SourceMode,

    // Project configuration (PyPI mode)
    project_name: []const u8,
    project_version: []const u8,
    python_version: []const u8,

    // Git configuration (Git mode)
    git_repository: ?[]const u8 = null,
    git_branch: ?[]const u8 = null,
    git_tag: ?[]const u8 = null,
    git_commit: ?[]const u8 = null,

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
        // Free Git-related strings
        if (self.git_repository) |git_repo| {
            self.allocator.free(git_repo);
        }
        if (self.git_branch) |git_branch| {
            self.allocator.free(git_branch);
        }
        if (self.git_tag) |git_tag| {
            self.allocator.free(git_tag);
        }
        if (self.git_commit) |git_commit| {
            self.allocator.free(git_commit);
        }
        // Free the strings allocated by create() and parseFromEnv()
        self.allocator.free(self.project_name);
        self.allocator.free(self.project_version);
        self.allocator.free(self.python_version);
    }
};

/// Source mode for package installation
pub const SourceMode = enum {
    pypi,  // Install from PyPI (default)
    git,   // Install from Git repository
};

/// Environment variable configuration keys
pub const EnvVars = struct {
    // PyPI mode variables
    pub const PROJECT_NAME = "BUNDLR_PROJECT_NAME";
    pub const PROJECT_VERSION = "BUNDLR_PROJECT_VERSION";
    pub const PYTHON_VERSION = "BUNDLR_PYTHON_VERSION";
    pub const REQUIREMENTS = "BUNDLR_REQUIREMENTS";
    pub const ENTRY_POINT = "BUNDLR_ENTRY_POINT";
    pub const CACHE_DIR = "BUNDLR_CACHE_DIR";
    pub const FORCE_REINSTALL = "BUNDLR_FORCE_REINSTALL";

    // Git mode variables
    pub const GIT_REPOSITORY = "BUNDLR_GIT_REPOSITORY";
    pub const GIT_BRANCH = "BUNDLR_GIT_BRANCH";
    pub const GIT_TAG = "BUNDLR_GIT_TAG";
    pub const GIT_COMMIT = "BUNDLR_GIT_COMMIT";
};

/// Parse runtime configuration from environment variables
pub fn parseFromEnv(allocator: std.mem.Allocator) !RuntimeConfig {
    // First, check for Git repository to determine source mode
    const git_repository = std.process.getEnvVarOwned(allocator, EnvVars.GIT_REPOSITORY) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    errdefer if (git_repository) |repo| allocator.free(repo);

    // Determine source mode
    const source_mode: SourceMode = if (git_repository != null) .git else .pypi;

    // Parse project name (required for PyPI mode, optional for Git mode)
    const project_name = std.process.getEnvVarOwned(allocator, EnvVars.PROJECT_NAME) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => switch (source_mode) {
            .pypi => return error.MissingProjectName,
            .git => try allocator.dupe(u8, "git-package"), // Default name for Git mode
        },
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

    // Parse Git-specific variables
    const git_branch = std.process.getEnvVarOwned(allocator, EnvVars.GIT_BRANCH) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    errdefer if (git_branch) |branch| allocator.free(branch);

    const git_tag = std.process.getEnvVarOwned(allocator, EnvVars.GIT_TAG) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    errdefer if (git_tag) |tag| allocator.free(tag);

    const git_commit = std.process.getEnvVarOwned(allocator, EnvVars.GIT_COMMIT) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    errdefer if (git_commit) |commit| allocator.free(commit);

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

    const config = RuntimeConfig{
        .allocator = allocator,
        .source_mode = source_mode,
        .project_name = project_name,
        .project_version = project_version,
        .python_version = python_version,
        .git_repository = git_repository,
        .git_branch = git_branch,
        .git_tag = git_tag,
        .git_commit = git_commit,
        .cache_dir = cache_dir,
        .force_reinstall = force_reinstall,
    };

    // Validate the configuration
    try validate(&config);

    return config;
}

/// Validate that required configuration is present and valid
pub fn validate(config: *const RuntimeConfig) !void {
    // Validate based on source mode
    switch (config.source_mode) {
        .pypi => {
            // Validate project name for PyPI mode
            if (config.project_name.len == 0) {
                return error.InvalidProjectName;
            }
        },
        .git => {
            // Validate Git repository URL for Git mode
            if (config.git_repository == null or config.git_repository.?.len == 0) {
                return error.MissingGitRepository;
            }
            // Basic URL validation - should start with http/https
            if (config.git_repository) |repo| {
                if (!std.mem.startsWith(u8, repo, "http://") and !std.mem.startsWith(u8, repo, "https://")) {
                    return error.InvalidGitRepositoryUrl;
                }
            }
        },
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
        .source_mode = .pypi,
        .project_name = try allocator.dupe(u8, project_name),
        .project_version = try allocator.dupe(u8, project_version),
        .python_version = try allocator.dupe(u8, python_version),
    };
}

/// Create a runtime config for Git mode (for testing/programmatic use)
pub fn createGit(
    allocator: std.mem.Allocator,
    git_repository: []const u8,
    python_version: []const u8,
    git_branch: ?[]const u8,
) !RuntimeConfig {
    return RuntimeConfig{
        .allocator = allocator,
        .source_mode = .git,
        .project_name = try allocator.dupe(u8, "git-package"),
        .project_version = try allocator.dupe(u8, "1.0.0"),
        .python_version = try allocator.dupe(u8, python_version),
        .git_repository = try allocator.dupe(u8, git_repository),
        .git_branch = if (git_branch) |branch| try allocator.dupe(u8, branch) else null,
    };
}

// Tests
test "build config defaults" {
    const config = BuildConfig{};
    try std.testing.expectEqualStrings("3.14", config.default_python_version);
    try std.testing.expectEqualStrings("bundlr_cache", config.cache_dir_name);
    try std.testing.expect(config.download_timeout_seconds == 300);
}

test "runtime config creation" {
    const allocator = std.testing.allocator;
    var config = try create(allocator, "test-app", "1.0.0", "3.14");
    defer config.deinit();

    try std.testing.expectEqualStrings("test-app", config.project_name);
    try std.testing.expectEqualStrings("1.0.0", config.project_version);
    try std.testing.expectEqualStrings("3.14", config.python_version);
}

test "config validation - PyPI mode" {
    const allocator = std.testing.allocator;

    // Valid PyPI config
    var valid_config = try create(allocator, "test", "1.0.0", "3.14");
    defer valid_config.deinit();
    try validate(&valid_config);

    // Invalid project name
    var invalid_name_config = RuntimeConfig{
        .allocator = allocator,
        .source_mode = .pypi,
        .project_name = try allocator.dupe(u8, ""),
        .project_version = try allocator.dupe(u8, "1.0.0"),
        .python_version = try allocator.dupe(u8, "3.13"),
    };
    defer invalid_name_config.deinit();
    try std.testing.expectError(error.InvalidProjectName, validate(&invalid_name_config));

    // Invalid Python version
    var invalid_python_config = RuntimeConfig{
        .allocator = allocator,
        .source_mode = .pypi,
        .project_name = try allocator.dupe(u8, "test"),
        .project_version = try allocator.dupe(u8, "1.0.0"),
        .python_version = try allocator.dupe(u8, "invalid"),
    };
    defer invalid_python_config.deinit();
    try std.testing.expectError(error.InvalidPythonVersion, validate(&invalid_python_config));
}

test "config validation - Git mode" {
    const allocator = std.testing.allocator;

    // Valid Git config
    var valid_git_config = try createGit(allocator, "https://github.com/user/repo", "3.14", "main");
    defer valid_git_config.deinit();
    try validate(&valid_git_config);

    // Test source mode detection
    try std.testing.expect(valid_git_config.source_mode == .git);
    try std.testing.expectEqualStrings("https://github.com/user/repo", valid_git_config.git_repository.?);

    // Invalid Git repository URL
    var invalid_git_config = RuntimeConfig{
        .allocator = allocator,
        .source_mode = .git,
        .project_name = try allocator.dupe(u8, "test"),
        .project_version = try allocator.dupe(u8, "1.0.0"),
        .python_version = try allocator.dupe(u8, "3.14"),
        .git_repository = try allocator.dupe(u8, "invalid-url"),
    };
    defer invalid_git_config.deinit();
    try std.testing.expectError(error.InvalidGitRepositoryUrl, validate(&invalid_git_config));
}

test "Git config creation" {
    const allocator = std.testing.allocator;
    var config = try createGit(allocator, "https://github.com/astral-sh/ruff", "3.14", "main");
    defer config.deinit();

    try std.testing.expect(config.source_mode == .git);
    try std.testing.expectEqualStrings("https://github.com/astral-sh/ruff", config.git_repository.?);
    try std.testing.expectEqualStrings("main", config.git_branch.?);
    try std.testing.expectEqualStrings("3.14", config.python_version);
}