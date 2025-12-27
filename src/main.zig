const std = @import("std");
const bundlr = @import("bundlr");
const print = std.debug.print;

/// GUI mode - show dialogues for package input and run bundlr
fn runGuiMode(allocator: std.mem.Allocator) !void {
    print("🎨 Bundlr GUI Mode\n", .{});
    print("   Launching dialogue interface...\n\n", .{});

    // Get package name or repository
    var package_result = bundlr.gui.dialogues.showInputDialogue(
        allocator,
        "Bundlr - Package Runner",
        "Enter PyPI package or Git URL:",
        "cowsay"
    ) catch |err| {
        if (err == error.DialogueCancelled) {
            print("📛 Operation cancelled by user\n", .{});
            return;
        }
        bundlr.gui.dialogues.showMessageDialogue("Error", "Failed to show package dialogue");
        return err;
    };
    defer package_result.deinit();

    if (package_result.text.len == 0) {
        bundlr.gui.dialogues.showMessageDialogue("Error", "Package name cannot be empty");
        return;
    }

    // Get arguments
    var args_result = bundlr.gui.dialogues.showInputDialogue(
        allocator,
        "Bundlr - Arguments",
        "Enter arguments (optional):",
        "-t \"Hello from GUI!\""
    ) catch |err| {
        if (err == error.DialogueCancelled) {
            print("📛 Operation cancelled by user\n", .{});
            return;
        }
        bundlr.gui.dialogues.showMessageDialogue("Error", "Failed to show arguments dialogue");
        return err;
    };
    defer args_result.deinit();

    print("📦 Package: {s}\n", .{package_result.text});
    if (args_result.text.len > 0) {
        print("⚙️  Arguments: {s}\n", .{args_result.text});
    }
    print("\n🚀 Running bundlr...\n\n", .{});

    // Parse arguments into fixed array
    var args_array: [16][]const u8 = undefined; // Support up to 16 arguments
    var arg_count: usize = 0;

    if (args_result.text.len > 0) {
        // Simple approach: just treat the entire args_result.text as one argument
        // This is sufficient for basic GUI use cases
        const trimmed = std.mem.trim(u8, args_result.text, " \t\"'");
        if (trimmed.len > 0) {
            args_array[arg_count] = trimmed;
            arg_count += 1;
        }
    }

    // Build command to execute in terminal window
    var cmd_args: [32][]const u8 = undefined;
    var cmd_count: usize = 0;

    // Get the current executable path
    const exe_path = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(exe_path);

    cmd_args[cmd_count] = exe_path;
    cmd_count += 1;
    cmd_args[cmd_count] = package_result.text;
    cmd_count += 1;

    // Add parsed arguments
    var i: usize = 0;
    while (i < arg_count and cmd_count < cmd_args.len) {
        cmd_args[cmd_count] = args_array[i];
        cmd_count += 1;
        i += 1;
    }

    // Show terminal window with bundlr execution
    const title = try std.fmt.allocPrint(allocator, "Bundlr - {s}", .{package_result.text});
    defer allocator.free(title);

    bundlr.gui.dialogues.showConsoleOutput(allocator, title, cmd_args[0..cmd_count]) catch |err| {
        const error_msg = "Failed to open terminal window. Check that your system has a terminal emulator installed.";
        bundlr.gui.dialogues.showMessageDialogue("Bundlr Error", error_msg);
        print("❌ Error opening console: {}\n", .{err});
        return;
    };

    print("✅ Launched bundlr in terminal window\n", .{});
}

/// Internal function to run a package (extracted from main logic)
fn runPackageInternal(allocator: std.mem.Allocator, package_arg: []const u8, app_args: []const []const u8) !bool {
    // Auto-detect mode and create configuration
    const build_config = bundlr.config.BuildConfig{};
    var config = if (isGitRepository(package_arg))
        try bundlr.config.createGit(allocator, package_arg, build_config.default_python_version, null)
    else
        try bundlr.config.create(allocator, package_arg, "1.0.0", build_config.default_python_version);
    defer config.deinit();

    // Print bootstrap message based on source mode
    switch (config.source_mode) {
        .pypi => {
            print("🚀 Bundlr: Bootstrapping {s} v{s} (Python {s})\n", .{
                config.project_name,
                config.project_version,
                config.python_version,
            });
        },
        .git => {
            print("🚀 Bundlr: Bootstrapping from {s} (Python {s})\n", .{
                config.git_repository.?,
                config.python_version,
            });
        },
    }

    // Continue with existing bundlr logic...
    // (This would call the same functions as the current main function)

    // For now, return success - in full implementation, this would contain
    // all the existing bootstrap logic from main()
    _ = app_args; // Suppress unused warning for now

    // TODO: Move existing main() bootstrap logic here
    print("⚠️  GUI mode package execution not yet fully implemented\n", .{});
    print("   This will be connected to existing bundlr functionality\n", .{});

    return true; // Temporary - return actual success status
}

/// Main bundlr application entry point
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Check for special flags first
    if (args.len > 1) {
        if (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) {
            printUsage(args[0]);
            return;
        } else if (std.mem.eql(u8, args[1], "--gui")) {
            try runGuiMode(allocator);
            return;
        }
    }

    // Default behavior: launch GUI if no arguments (double-click behavior)
    if (args.len == 1) {
        try runGuiMode(allocator);
        return;
    }

    // Parse first argument as package name or Git repository
    const package_arg = args[1];

    // Application arguments are everything after the package name
    const app_args = if (args.len > 2) args[2..] else &[_][]const u8{};

    // Auto-detect mode and create configuration
    const build_config = bundlr.config.BuildConfig{};
    var config = if (isGitRepository(package_arg))
        try bundlr.config.createGit(allocator, package_arg, build_config.default_python_version, null)
    else
        try bundlr.config.create(allocator, package_arg, "1.0.0", build_config.default_python_version);
    defer config.deinit();

    // Print bootstrap message based on source mode
    switch (config.source_mode) {
        .pypi => {
            print("🚀 Bundlr: Bootstrapping {s} v{s} (Python {s})\n", .{
                config.project_name,
                config.project_version,
                config.python_version,
            });
        },
        .git => {
            print("🚀 Bundlr: Bootstrapping from {s} (Python {s})\n", .{
                config.git_repository.?,
                config.python_version,
            });
        },
    }

    // Run the bootstrap process
    try bootstrapApplication(allocator, &config, app_args);
}

/// Detect if a string is a Git repository URL
fn isGitRepository(package_arg: []const u8) bool {
    return std.mem.startsWith(u8, package_arg, "http://") or
           std.mem.startsWith(u8, package_arg, "https://") or
           std.mem.startsWith(u8, package_arg, "git@") or
           std.mem.indexOf(u8, package_arg, "github.com") != null or
           std.mem.indexOf(u8, package_arg, "gitlab.com") != null;
}

/// Bootstrap and run a Python application
fn bootstrapApplication(allocator: std.mem.Allocator, config: *const bundlr.config.RuntimeConfig, app_args: []const []const u8) !void {
    // Route to different bootstrap flows based on source mode
    switch (config.source_mode) {
        .pypi => try bootstrapPyPiApplication(allocator, config, app_args),
        .git => try bootstrapGitApplication(allocator, config, app_args),
    }
}

/// Bootstrap PyPI application (original workflow)
fn bootstrapPyPiApplication(allocator: std.mem.Allocator, config: *const bundlr.config.RuntimeConfig, app_args: []const []const u8) !void {
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
    try executePyPiApplication(allocator, &venv_manager, venv_dir, config, app_args);
}

/// Bootstrap Git repository application (new workflow)
fn bootstrapGitApplication(allocator: std.mem.Allocator, config: *const bundlr.config.RuntimeConfig, app_args: []const []const u8) !void {
    // Step 1: Ensure uv is installed
    print("⚡ Ensuring uv is installed...\n", .{});
    var uv_manager = bundlr.uv.bootstrap.UvManager.init(allocator);

    const uv_version = try uv_manager.ensureUvInstalled(bundlr.platform.http.printProgress);
    defer allocator.free(uv_version);

    const uv_exe = try uv_manager.getUvExecutable(uv_version);
    defer allocator.free(uv_exe);
    print("⚡ Using uv: {s} (v{s})\n", .{ uv_exe, uv_version });

    // Step 2: Download and extract Git repository
    print("📥 Downloading repository: {s}\n", .{config.git_repository.?});
    var git_manager = bundlr.git.archive.GitArchiveManager.init(allocator);

    const archive_path = try git_manager.downloadRepository(
        config.git_repository.?,
        config.git_branch,
        config.git_tag,
        config.git_commit,
        bundlr.platform.http.printProgress,
    );
    defer allocator.free(archive_path);

    const extract_dir = try git_manager.extractRepository(archive_path, config.project_name);
    defer allocator.free(extract_dir);
    print("📂 Extracted to: {s}\n", .{extract_dir});

    // Step 3: Create virtual environment with uv
    print("📦 Setting up virtual environment with uv...\n", .{});
    var uv_venv_manager = bundlr.uv.venv.UvVenvManager.init(allocator, uv_exe);

    const venv_dir = try uv_venv_manager.create(config.project_name, config.python_version);
    defer allocator.free(venv_dir);
    print("✅ Virtual environment ready: {s}\n", .{venv_dir});

    // Step 4: Install package from extracted repository
    print("📋 Installing package from local directory...\n", .{});
    var uv_installer = bundlr.uv.installer.UvPackageInstaller.init(allocator, uv_exe, venv_dir);
    try uv_installer.installFromPath(extract_dir);
    print("✅ Package installed successfully\n", .{});

    // Step 5: Execute the application
    print("🎯 Executing application...\n", .{});
    try executeGitApplication(allocator, &uv_venv_manager, venv_dir, config, app_args);

    // Step 6: Clean up temporary files
    print("🧹 Cleaning up temporary files...\n", .{});

    // Clean up the current extraction directory
    git_manager.cleanupExtraction(extract_dir);

    // Clean up old extractions (older than 24 hours) to prevent accumulation
    git_manager.cleanupOldExtractions(24) catch |err| {
        std.log.warn("Failed to cleanup old extractions: {}", .{err});
    };
}

/// Execute PyPI application using pip virtual environment
fn executePyPiApplication(
    allocator: std.mem.Allocator,
    venv_manager: *bundlr.python.venv.VenvManager,
    venv_dir: []const u8,
    config: *const bundlr.config.RuntimeConfig,
    app_args: []const []const u8
) !void {
    const python_exe = try venv_manager.getVenvPython(venv_dir);
    defer allocator.free(python_exe);

    try executeWithPython(allocator, python_exe, config, app_args);
}

/// Execute Git application using uv virtual environment
fn executeGitApplication(
    allocator: std.mem.Allocator,
    uv_venv_manager: *bundlr.uv.venv.UvVenvManager,
    venv_dir: []const u8,
    config: *const bundlr.config.RuntimeConfig,
    app_args: []const []const u8
) !void {
    // For Git repositories, try to extract the package name from the repository
    var actual_package_name: ?[]u8 = null;
    defer if (actual_package_name) |name| allocator.free(name);

    // Try to determine the package name from the Git repository URL
    if (config.git_repository) |repo_url| {
        // Extract repo name from URL (e.g., "https://github.com/astral-sh/ruff" -> "ruff")
        const repo_name = blk: {
            const last_slash = std.mem.lastIndexOf(u8, repo_url, "/") orelse break :blk null;
            if (last_slash + 1 >= repo_url.len) break :blk null;
            var name = repo_url[last_slash + 1 ..];

            // Remove .git suffix if present
            if (std.mem.endsWith(u8, name, ".git")) {
                name = name[0 .. name.len - 4];
            }
            break :blk name;
        };

        if (repo_name) |name| {
            actual_package_name = try allocator.dupe(u8, name);

            // Try running as entry point command first
            if (tryRunEntryPoint(allocator, venv_dir, name, app_args)) {
                print("✅ Application completed successfully\n", .{});
                return;
            } else |_| {
                // Entry point failed, continue with Python execution
            }
        }
    }

    // Fall back to Python execution
    const python_exe = try uv_venv_manager.getVenvPython(venv_dir);
    defer allocator.free(python_exe);

    // Create a modified config with the actual package name if we found one
    var modified_config = config.*;
    if (actual_package_name) |name| {
        modified_config.project_name = name;
    }

    try executeWithPython(allocator, python_exe, &modified_config, app_args);
}

/// Try to run an application using its entry point command
fn tryRunEntryPoint(
    allocator: std.mem.Allocator,
    venv_dir: []const u8,
    package_name: []const u8,
    app_args: []const []const u8
) !void {
    // Build path to the entry point executable in venv/bin/
    const platform = @import("builtin").os.tag;
    const bin_dir = switch (platform) {
        .windows => "Scripts",
        else => "bin",
    };

    const entry_point_path = try std.fs.path.join(allocator, &[_][]const u8{ venv_dir, bin_dir, package_name });
    defer allocator.free(entry_point_path);

    // Check if entry point exists
    std.fs.accessAbsolute(entry_point_path, .{}) catch return error.EntryPointNotFound;

    // Build command arguments
    var cmd_args: [32][]const u8 = undefined; // Fixed size array
    var arg_count: usize = 0;

    cmd_args[arg_count] = entry_point_path; arg_count += 1;

    // Add application arguments
    for (app_args) |arg| {
        if (arg_count >= cmd_args.len) break; // Prevent overflow
        cmd_args[arg_count] = arg;
        arg_count += 1;
    }

    // Execute the entry point command
    const exit_code = try bundlr.platform.process.run(allocator, cmd_args[0..arg_count], null);
    if (exit_code != 0) {
        return error.EntryPointExecutionFailed;
    }
}

/// Common execution logic for both PyPI and Git applications
fn executeWithPython(
    allocator: std.mem.Allocator,
    python_exe: []const u8,
    config: *const bundlr.config.RuntimeConfig,
    app_args: []const []const u8
) !void {
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
    print("Run ANY Python package from PyPI or Git with zero setup!\n", .{});

    print("\n🎨 DEFAULT (GUI MODE):\n", .{});
    print("  {s}                                   # Double-click or run with no args for GUI\n", .{program_name});

    print("\n🚀 COMMAND LINE USAGE:\n", .{});
    print("  {s} <package_or_repo> [arguments...]\n", .{program_name});

    print("\n📦 PyPI PACKAGES:\n", .{});
    print("  {s} cowsay \"Hello World\"              # Run cowsay with arguments\n", .{program_name});
    print("  {s} httpie GET httpbin.org/json        # Run httpie (HTTP client)\n", .{program_name});
    print("  {s} youtube-dl --help                  # Run youtube-dl help\n", .{program_name});
    print("  {s} black --check .                    # Run black code formatter\n", .{program_name});

    print("\n🔗 GIT REPOSITORIES:\n", .{});
    print("  {s} https://github.com/psf/black       # Run from Git repo\n", .{program_name});
    print("  {s} github.com/user/repo --help        # GitHub short syntax\n", .{program_name});

    print("\n🎯 OPTIONS:\n", .{});
    print("  -h, --help              Show this help message\n", .{});
    print("      --gui               Launch GUI mode explicitly\n", .{});

    print("\n🔧 ENVIRONMENT VARIABLES (optional):\n", .{});
    print("  BUNDLR_PYTHON_VERSION   Python version (default: 3.14)\n", .{});
    print("  BUNDLR_GIT_BRANCH       Git branch name (default: main)\n", .{});
    print("  BUNDLR_CACHE_DIR        Custom cache directory\n", .{});

    print("\n✨ It's that simple! Bundlr automatically:\n", .{});
    print("   • Downloads and installs Python if needed\n", .{});
    print("   • Creates isolated virtual environments\n", .{});
    print("   • Installs packages and dependencies\n", .{});
    print("   • Runs your application\n", .{});
    print("   • Cleans up temporary files\n", .{});
}

test "bundlr config integration" {
    const allocator = std.testing.allocator;
    var config = try bundlr.config.create(allocator, "test-app", "1.0.0", "3.14");
    defer config.deinit();

    try std.testing.expectEqualStrings("test-app", config.project_name);
    try std.testing.expectEqualStrings("3.14", config.python_version);
}

test "main module integration" {
    // Test that main module can access all bundlr functionality
    const allocator = std.testing.allocator;

    // Test configuration creation
    var config = try bundlr.config.create(allocator, "test", "1.0.0", "3.14");
    defer config.deinit();

    // Test paths functionality
    var paths = bundlr.platform.paths.Paths.init(allocator);
    const cache_dir = try paths.getBundlrCacheDir();
    defer allocator.free(cache_dir);

    try std.testing.expect(cache_dir.len > 0);
}
