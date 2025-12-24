const std = @import("std");
const process = @import("../platform/process.zig");

/// Package installer for pip operations
pub const PackageInstaller = struct {
    allocator: std.mem.Allocator,
    pip_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, pip_path: []const u8) PackageInstaller {
        return PackageInstaller{
            .allocator = allocator,
            .pip_path = pip_path,
        };
    }

    /// Install single package
    pub fn installPackage(self: *PackageInstaller, package_name: []const u8) !void {
        const args = [_][]const u8{ self.pip_path, "install", package_name };
        const exit_code = try process.run(self.allocator, &args, null);

        if (exit_code != 0) {
            return error.PackageInstallationFailed;
        }
    }

    /// Install from requirements file
    pub fn installRequirements(self: *PackageInstaller, requirements_file: []const u8) !void {
        const args = [_][]const u8{ self.pip_path, "install", "-r", requirements_file };
        const exit_code = try process.run(self.allocator, &args, null);

        if (exit_code != 0) {
            return error.RequirementsInstallationFailed;
        }
    }

    /// Install multiple packages
    pub fn installPackages(self: *PackageInstaller, packages: []const []const u8) !void {
        var args = std.ArrayList([]const u8).init(self.allocator);
        defer args.deinit();

        try args.append(self.pip_path);
        try args.append("install");
        try args.appendSlice(packages);

        const exit_code = try process.run(self.allocator, args.items, null);

        if (exit_code != 0) {
            return error.PackagesInstallationFailed;
        }
    }

    /// Check if package is installed
    pub fn isInstalled(self: *PackageInstaller, package_name: []const u8) !bool {
        const args = [_][]const u8{ self.pip_path, "show", package_name };
        const exit_code = try process.run(self.allocator, &args, null);
        return exit_code == 0;
    }
};