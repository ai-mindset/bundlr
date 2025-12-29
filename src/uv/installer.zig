//! UV package installer
//! Replaces pip with uv's faster package installation

const std = @import("std");
const process = @import("../platform/process.zig");

/// UV package installer - uses uv pip install for faster package management
pub const UvPackageInstaller = struct {
    allocator: std.mem.Allocator,
    uv_path: []const u8,
    venv_dir: []const u8,

    pub fn init(allocator: std.mem.Allocator, uv_path: []const u8, venv_dir: []const u8) UvPackageInstaller {
        return UvPackageInstaller{
            .allocator = allocator,
            .uv_path = uv_path,
            .venv_dir = venv_dir,
        };
    }

    /// Install a single package from PyPI
    pub fn installPackage(self: *UvPackageInstaller, package_name: []const u8) !void {
        const args = [_][]const u8{
            self.uv_path,
            "pip",
            "install",
            package_name,
        };

        // Set VIRTUAL_ENV environment variable for uv 0.9.18 compatibility
        const exit_code = try process.runWithEnv(self.allocator, &args, null, &[_][]const u8{
            "VIRTUAL_ENV", self.venv_dir,
        });
        if (exit_code != 0) {
            return error.PackageInstallationFailed;
        }
    }

    /// Install package from a local directory (for Git repositories)
    pub fn installFromPath(self: *UvPackageInstaller, source_path: []const u8) !void {
        const args = [_][]const u8{
            self.uv_path,
            "pip",
            "install",
            source_path,
        };

        // Set VIRTUAL_ENV environment variable for uv 0.9.18 compatibility
        const exit_code = try process.runWithEnv(self.allocator, &args, null, &[_][]const u8{
            "VIRTUAL_ENV", self.venv_dir,
        });
        if (exit_code != 0) {
            return error.LocalInstallationFailed;
        }
    }

    /// Install package from a local directory in editable mode
    pub fn installFromPathEditable(self: *UvPackageInstaller, source_path: []const u8) !void {
        const args = [_][]const u8{
            self.uv_path,
            "pip",
            "install",
            "-e",
            source_path,
        };

        // Set VIRTUAL_ENV environment variable for uv 0.9.18 compatibility
        const exit_code = try process.runWithEnv(self.allocator, &args, null, &[_][]const u8{
            "VIRTUAL_ENV", self.venv_dir,
        });
        if (exit_code != 0) {
            return error.EditableInstallationFailed;
        }
    }

    /// Install from requirements file
    pub fn installRequirements(self: *UvPackageInstaller, requirements_file: []const u8) !void {
        const args = [_][]const u8{
            self.uv_path,
            "pip",
            "install",
            "-r",
            requirements_file,
        };

        // Set VIRTUAL_ENV environment variable for uv 0.9.18 compatibility
        const exit_code = try process.runWithEnv(self.allocator, &args, null, &[_][]const u8{
            "VIRTUAL_ENV", self.venv_dir,
        });
        if (exit_code != 0) {
            return error.RequirementsInstallationFailed;
        }
    }

    /// Install multiple packages
    pub fn installPackages(self: *UvPackageInstaller, packages: []const []const u8) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append(self.uv_path);
        try args.append("pip");
        try args.append("install");
        try args.appendSlice(packages);

        // Set VIRTUAL_ENV environment variable for uv 0.9.18 compatibility
        const exit_code = try process.runWithEnv(self.allocator, args.items, null, &[_][]const u8{
            "VIRTUAL_ENV", self.venv_dir,
        });
        if (exit_code != 0) {
            return error.PackagesInstallationFailed;
        }
    }

    /// Check if package is installed
    pub fn isInstalled(self: *UvPackageInstaller, package_name: []const u8) !bool {
        const args = [_][]const u8{
            self.uv_path,
            "pip",
            "show",
            package_name,
        };

        // Set VIRTUAL_ENV environment variable for uv 0.9.18 compatibility
        const exit_code = try process.runWithEnv(self.allocator, &args, null, &[_][]const u8{
            "VIRTUAL_ENV", self.venv_dir,
        });
        return exit_code == 0;
    }

    /// List installed packages
    pub fn listPackages(self: *UvPackageInstaller) !void {
        const args = [_][]const u8{
            self.uv_path,
            "pip",
            "list",
        };

        // Set VIRTUAL_ENV environment variable for uv 0.9.18 compatibility
        const exit_code = try process.runWithEnv(self.allocator, &args, null, &[_][]const u8{
            "VIRTUAL_ENV", self.venv_dir,
        });
        if (exit_code != 0) {
            return error.ListPackagesFailed;
        }
    }

    /// Sync dependencies from lock file
    pub fn sync(self: *UvPackageInstaller, lock_file: ?[]const u8) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append(self.uv_path);
        try args.append("pip");
        try args.append("sync");

        if (lock_file) |file| {
            try args.append(file);
        }

        // Set VIRTUAL_ENV environment variable for uv 0.9.18 compatibility
        const exit_code = try process.runWithEnv(self.allocator, args.items, null, &[_][]const u8{
            "VIRTUAL_ENV", self.venv_dir,
        });
        if (exit_code != 0) {
            return error.SyncFailed;
        }
    }
};

// Tests
test "uv installer creation" {
    const allocator = std.testing.allocator;
    const installer = UvPackageInstaller.init(allocator, "/usr/bin/uv", "/test/venv");

    try std.testing.expect(installer.allocator.vtable == allocator.vtable);
    try std.testing.expectEqualStrings("/usr/bin/uv", installer.uv_path);
    try std.testing.expectEqualStrings("/test/venv", installer.venv_dir);
}