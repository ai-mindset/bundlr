//! UV virtual environment management
//! Replaces Python's built-in venv module with uv's faster implementation

const std = @import("std");
const paths_module = @import("../platform/paths.zig");
const process = @import("../platform/process.zig");

/// UV virtual environment manager
pub const UvVenvManager = struct {
    allocator: std.mem.Allocator,
    uv_path: []const u8,
    paths: paths_module.Paths,

    pub fn init(allocator: std.mem.Allocator, uv_path: []const u8) UvVenvManager {
        return UvVenvManager{
            .allocator = allocator,
            .uv_path = uv_path,
            .paths = paths_module.Paths.init(allocator),
        };
    }


    /// Create a virtual environment using uv
    pub fn create(
        self: *UvVenvManager,
        project_name: []const u8,
        python_version: []const u8,
    ) ![]u8 {
        // Get virtual environment directory path
        const venv_dir_const = try self.paths.getVenvDir(project_name, python_version);
        defer self.allocator.free(venv_dir_const);

        const venv_dir = try self.allocator.dupe(u8, venv_dir_const);
        errdefer self.allocator.free(venv_dir);

        // Check if venv already exists and is valid
        if (try self.isValid(venv_dir)) {
            return venv_dir;
        }

        // Create the virtual environment using uv
        // Command: uv venv --python {python_version} {venv_dir}
        const args = [_][]const u8{
            self.uv_path,
            "venv",
            "--python",
            python_version,
            venv_dir,
        };

        const exit_code = try process.run(self.allocator, &args, null);
        if (exit_code != 0) {
            self.allocator.free(venv_dir);
            return error.VenvCreationFailed;
        }

        return venv_dir;
    }

    /// Check if a virtual environment exists and is valid
    pub fn isValid(self: *UvVenvManager, venv_dir: []const u8) !bool {
        // Check if the Python executable exists
        const python_exe = try self.getVenvPython(venv_dir);
        defer self.allocator.free(python_exe);

        std.fs.accessAbsolute(python_exe, .{}) catch return false;
        return true;
    }

    /// Get the Python executable path from a virtual environment
    pub fn getVenvPython(self: *UvVenvManager, venv_dir: []const u8) ![]u8 {
        const platform = @import("builtin").os.tag;
        const python_name = switch (platform) {
            .windows => "python.exe",
            else => "python",
        };

        const bin_dir = switch (platform) {
            .windows => "Scripts",
            else => "bin",
        };

        return try std.fs.path.join(self.allocator, &[_][]const u8{ venv_dir, bin_dir, python_name });
    }

    /// Get the uv executable path (works with any venv when --venv is specified)
    pub fn getVenvUv(self: *UvVenvManager) ![]u8 {
        // Return the original uv path, as it works with any venv when --venv is specified
        return try self.allocator.dupe(u8, self.uv_path);
    }
};

// Tests
test "uv venv manager creation" {
    const allocator = std.testing.allocator;
    var manager = UvVenvManager.init(allocator, "/usr/bin/uv");
    defer manager.deinit();

    try std.testing.expect(manager.allocator.vtable == allocator.vtable);
    try std.testing.expectEqualStrings("/usr/bin/uv", manager.uv_path);
}

test "venv path generation" {
    const allocator = std.testing.allocator;
    var manager = UvVenvManager.init(allocator, "/usr/bin/uv");
    defer manager.deinit();

    // Test Python executable path generation
    const python_path = try manager.getVenvPython("/test/venv");
    defer allocator.free(python_path);

    const platform = std.builtin.os.tag;
    const expected = switch (platform) {
        .windows => "/test/venv/Scripts/python.exe",
        else => "/test/venv/bin/python",
    };

    try std.testing.expectEqualStrings(expected, python_path);
}