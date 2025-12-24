const std = @import("std");
const builtin = @import("builtin");
const paths_module = @import("../platform/paths.zig");
const process = @import("../platform/process.zig");

/// Virtual environment manager
pub const VenvManager = struct {
    allocator: std.mem.Allocator,
    paths: paths_module.Paths,

    pub fn init(allocator: std.mem.Allocator) VenvManager {
        return VenvManager{
            .allocator = allocator,
            .paths = paths_module.Paths.init(allocator),
        };
    }

    /// Create virtual environment
    pub fn create(
        self: *VenvManager,
        python_exe: []const u8,
        project_name: []const u8,
        python_version: []const u8,
    ) ![]const u8 {
        const venv_dir = try self.paths.getVenvDir(project_name, python_version);
        errdefer self.allocator.free(venv_dir);

        // Ensure parent directory exists
        const parent = std.fs.path.dirname(venv_dir) orelse return error.InvalidPath;
        try self.paths.ensureDirExists(parent);

        // Create venv
        const args = [_][]const u8{ python_exe, "-m", "venv", venv_dir };
        const exit_code = try process.run(self.allocator, &args, null);

        if (exit_code != 0) {
            self.allocator.free(venv_dir);
            return error.VenvCreationFailed;
        }

        return venv_dir;
    }

    /// Check if virtual environment exists and is valid
    pub fn isValid(self: *VenvManager, venv_dir: []const u8) bool {
        const python_exe = self.getVenvPython(venv_dir) catch return false;
        defer self.allocator.free(python_exe);

        std.fs.accessAbsolute(python_exe, .{}) catch return false;
        return true;
    }

    /// Get Python executable path in venv
    pub fn getVenvPython(self: *VenvManager, venv_dir: []const u8) ![]u8 {
        return switch (builtin.os.tag) {
            .windows => try std.fs.path.join(self.allocator, &.{ venv_dir, "Scripts", "python.exe" }),
            else => try std.fs.path.join(self.allocator, &.{ venv_dir, "bin", "python" }),
        };
    }

    /// Get pip executable path in venv
    pub fn getVenvPip(self: *VenvManager, venv_dir: []const u8) ![]u8 {
        return switch (builtin.os.tag) {
            .windows => try std.fs.path.join(self.allocator, &.{ venv_dir, "Scripts", "pip.exe" }),
            else => try std.fs.path.join(self.allocator, &.{ venv_dir, "bin", "pip" }),
        };
    }
};