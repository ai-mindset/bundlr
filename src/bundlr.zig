//! Bundlr - A Python application packaging tool
//! This is the main library module for the bundlr project.

const std = @import("std");

// Re-export modules as they're implemented
pub const config = @import("config.zig");
pub const platform = struct {
    pub const paths = @import("platform/paths.zig");
    pub const http = @import("platform/http.zig");
    pub const process = @import("platform/process.zig");
};
pub const python = struct {
    pub const distribution = @import("python/distribution.zig");
    pub const venv = @import("python/venv.zig");
    pub const installer = @import("python/installer.zig");
};
pub const utils = struct {
    pub const extract = @import("utils/extract.zig");
    pub const cache = @import("utils/cache.zig");
};

/// Main bundlr functionality
pub const Bundlr = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Bundlr {
        return Bundlr{
            .allocator = allocator,
        };
    }

    /// Bootstrap a Python application
    /// This is the main entry point for bundlr functionality
    pub fn bootstrap(self: *Bundlr, bootstrap_config: BootstrapConfig) !void {
        // TODO: Implement the full bootstrap process:
        // 1. Validate configuration
        // 2. Get or create cache directory
        // 3. Download Python distribution if needed
        // 4. Create virtual environment
        // 5. Install packages
        // 6. Execute application
        _ = self;
        _ = bootstrap_config;
        std.log.info("Bootstrap process not yet implemented", .{});
    }

    pub fn deinit(self: *Bundlr) void {
        _ = self;
        // TODO: Add cleanup when needed
    }
};

/// Configuration for bootstrapping a Python application
pub const BootstrapConfig = struct {
    /// Name of the Python project/application
    project_name: []const u8,
    /// Version of the Python project
    project_version: []const u8,
    /// Python version to use (e.g., "3.13")
    python_version: []const u8,
    /// Optional requirements to install
    requirements: ?[]const []const u8 = null,
    /// Entry point for the application
    entry_point: ?[]const u8 = null,
    /// Additional arguments to pass to the application
    args: ?[]const []const u8 = null,
};

/// Create a bundlr instance with the provided allocator
pub fn init(allocator: std.mem.Allocator) Bundlr {
    return Bundlr.init(allocator);
}

/// Version information
pub const version = "0.0.1";

test "bundlr init and basic functionality" {
    const allocator = std.testing.allocator;
    var bundlr = init(allocator);
    defer bundlr.deinit();

    // Test that we can create a bundlr instance
    try std.testing.expect(bundlr.allocator.vtable == allocator.vtable);
}

test "bootstrap config creation" {
    const bootstrap_config = BootstrapConfig{
        .project_name = "test-app",
        .project_version = "1.0.0",
        .python_version = "3.13",
    };

    try std.testing.expectEqualStrings("test-app", bootstrap_config.project_name);
    try std.testing.expectEqualStrings("1.0.0", bootstrap_config.project_version);
    try std.testing.expectEqualStrings("3.13", bootstrap_config.python_version);
}