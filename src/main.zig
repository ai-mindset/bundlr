const std = @import("std");
const bundlr = @import("bundlr");
const print = std.debug.print;

/// Main bundlr application entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Show help if requested
    if (args.len > 1 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        printUsage(args[0]);
        return;
    }

    // Parse application arguments (everything after "--")
    var app_args: [][]const u8 = &[_][]const u8{};
    if (args.len > 1) {
        for (args[1..], 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "--")) {
                // Cast null-terminated strings to const u8 slices
                const app_args_start = 1 + i + 1;
                if (app_args_start < args.len) {
                    app_args = @as([][]const u8, @ptrCast(args[app_args_start..]));
                }
                break;
            }
        }
    }

    // Parse runtime configuration from environment variables
    var config = bundlr.config.parseFromEnv(allocator) catch |err| switch (err) {
        error.MissingProjectName => {
            print("❌ Error: BUNDLR_PROJECT_NAME environment variable is required\n", .{});
            print("\nExample usage:\n", .{});
            print("  BUNDLR_PROJECT_NAME=cowsay BUNDLR_PROJECT_VERSION=6.1 {s}\n", .{args[0]});
            std.process.exit(1);
        },
        else => return err,
    };
    defer config.deinit();

    print("🚀 Bundlr: Bootstrapping {s} v{s} (Python {s})\n", .{
        config.project_name,
        config.project_version,
        config.python_version
    });

    // Run the bootstrap process
    try bootstrapApplication(allocator, &config, app_args);
}

/// Bootstrap and run a Python application
fn bootstrapApplication(allocator: std.mem.Allocator, config: *const bundlr.config.RuntimeConfig, app_args: []const []const u8) !void {
    // Step 1: Initialize distribution manager
    var dist_manager = bundlr.python.distribution.DistributionManager.init(allocator);

    // Step 2: Ensure Python distribution is available
    print("📥 Ensuring Python {s} is available...\n", .{config.python_version});
    try dist_manager.ensureDistribution(config.python_version, bundlr.platform.http.printProgress);

    // Step 3: Get Python executable
    const python_exe = try dist_manager.getPythonExecutable(config.python_version);
    defer allocator.free(python_exe);
    print("🐍 Using Python: {s}\n", .{python_exe});

    // Step 4: Create virtual environment
    print("📦 Setting up virtual environment...\n", .{});
    var venv_manager = bundlr.python.venv.VenvManager.init(allocator);

    const venv_dir = venv_manager.create(python_exe, config.project_name, config.python_version) catch |err| blk: {
        if (err == error.VenvCreationFailed) {
            // Check if venv already exists
            const existing_venv = try venv_manager.paths.getVenvDir(config.project_name, config.python_version);
            defer allocator.free(existing_venv);

            if (venv_manager.isValid(existing_venv)) {
                print("✅ Using existing virtual environment: {s}\n", .{existing_venv});
                break :blk try allocator.dupe(u8, existing_venv);
            } else {
                print("❌ Failed to create virtual environment\n", .{});
                return err;
            }
        } else {
            return err;
        }
    };
    defer allocator.free(venv_dir);

    print("✅ Virtual environment ready: {s}\n", .{venv_dir});

    // Step 5: Install project package
    print("📋 Installing project package: {s}\n", .{config.project_name});
    const pip_path = try venv_manager.getVenvPip(venv_dir);
    defer allocator.free(pip_path);

    var installer = bundlr.python.installer.PackageInstaller.init(allocator, pip_path);

    // Install the project package
    installer.installPackage(config.project_name) catch |err| {
        print("⚠️  Package installation failed: {}\n", .{err});
        print("   This might be expected if the package doesn't exist in PyPI\n", .{});
    };

    // Step 6: Execute the application
    print("🎯 Executing application...\n", .{});
    try executeApplication(allocator, &venv_manager, venv_dir, config, app_args);
}

/// Execute the Python application
fn executeApplication(
    allocator: std.mem.Allocator,
    venv_manager: *bundlr.python.venv.VenvManager,
    venv_dir: []const u8,
    config: *const bundlr.config.RuntimeConfig,
    app_args: []const []const u8
) !void {
    const python_exe = try venv_manager.getVenvPython(venv_dir);
    defer allocator.free(python_exe);

    // Build command arguments
    var cmd_args: [32][]const u8 = undefined; // Fixed size array
    var arg_count: usize = 0;

    // Try different execution methods
    if (config.entry_point) |entry_point| {
        // Use specified entry point
        cmd_args[arg_count] = python_exe; arg_count += 1;
        cmd_args[arg_count] = "-c"; arg_count += 1;
        cmd_args[arg_count] = entry_point; arg_count += 1;
    } else {
        // Try to run as module
        cmd_args[arg_count] = python_exe; arg_count += 1;
        cmd_args[arg_count] = "-m"; arg_count += 1;
        cmd_args[arg_count] = config.project_name; arg_count += 1;
    }

    // Add application arguments
    for (app_args) |arg| {
        if (arg_count >= cmd_args.len) break; // Prevent overflow
        cmd_args[arg_count] = arg;
        arg_count += 1;
    }

    // Execute the application
    const exit_code = bundlr.platform.process.run(allocator, cmd_args[0..arg_count], null) catch |err| {
        print("❌ Failed to execute application: {}\n", .{err});
        return err;
    };

    if (exit_code == 0) {
        print("✅ Application completed successfully\n", .{});
    } else {
        print("⚠️  Application exited with code: {}\n", .{exit_code});
        std.process.exit(@intCast(exit_code));
    }
}

/// Print usage information
fn printUsage(program_name: []const u8) void {
    print("Bundlr - Python Application Packager\n", .{});
    print("\nUsage: {s} [options] [-- app_args...]\n", .{program_name});
    print("\nRequired Environment Variables:\n", .{});
    print("  BUNDLR_PROJECT_NAME     Name of the Python package to install and run\n", .{});
    print("  BUNDLR_PROJECT_VERSION  Version of the project (default: 1.0.0)\n", .{});
    print("  BUNDLR_PYTHON_VERSION   Python version to use (default: 3.13)\n", .{});
    print("\nOptional Environment Variables:\n", .{});
    print("  BUNDLR_ENTRY_POINT      Custom Python code to execute\n", .{});
    print("  BUNDLR_CACHE_DIR        Custom cache directory\n", .{});
    print("  BUNDLR_FORCE_REINSTALL  Force package reinstallation (1/true/yes)\n", .{});
    print("\nExamples:\n", .{});
    print("  # Run cowsay package\n", .{});
    print("  BUNDLR_PROJECT_NAME=cowsay {s}\n", .{program_name});
    print("\n  # Run with custom entry point\n", .{});
    print("  BUNDLR_PROJECT_NAME=requests BUNDLR_ENTRY_POINT=\"import requests; print('OK')\" {s}\n", .{program_name});
    print("\n  # Pass arguments to the application\n", .{});
    print("  BUNDLR_PROJECT_NAME=cowsay {s} -- \"Hello World\"\n", .{program_name});
}

test "bundlr config integration" {
    const allocator = std.testing.allocator;
    var config = try bundlr.config.create(allocator, "test-app", "1.0.0", "3.13");
    defer config.deinit();

    try std.testing.expectEqualStrings("test-app", config.project_name);
    try std.testing.expectEqualStrings("3.13", config.python_version);
}

test "main module integration" {
    // Test that main module can access all bundlr functionality
    const allocator = std.testing.allocator;

    // Test configuration creation
    var config = try bundlr.config.create(allocator, "test", "1.0.0", "3.13");
    defer config.deinit();

    // Test paths functionality
    var paths = bundlr.platform.paths.Paths.init(allocator);
    const cache_dir = try paths.getBundlrCacheDir();
    defer allocator.free(cache_dir);

    try std.testing.expect(cache_dir.len > 0);
}
