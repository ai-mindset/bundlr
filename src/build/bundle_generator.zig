//! Self-extracting bundle generator for portable executables
//! Creates executables that contain embedded Python runtime and packages

const std = @import("std");
const bundlr = @import("../bundlr.zig");
const pipeline = @import("pipeline.zig");
const asset_collector = @import("asset_collector.zig");
const runtime_embedder = @import("runtime_embedder.zig");
const dependency_resolver = @import("dependency_resolver.zig");

/// Bundle generation options
pub const BundleOptions = struct {
    /// Output file path
    output_path: []const u8,

    /// Target platform
    target: pipeline.TargetPlatform,

    /// Python runtime bundle
    runtime_bundle: runtime_embedder.RuntimeBundle,

    /// Collected assets
    assets: asset_collector.AssetBundle,

    /// Resolved dependencies
    dependencies: dependency_resolver.DependencyTree,

    /// Entry point command/script
    entry_point: ?[]const u8 = null,

    /// Build metadata
    metadata: pipeline.BuildMetadata,
};

/// Information about generated bundle
pub const BundleInfo = struct {
    /// Path to generated executable
    executable_path: []const u8,

    /// Total bundle size
    total_size: u64,

    /// Component sizes
    components: ComponentSizes,

    /// Bundle metadata
    metadata: BundleMetadata,

    pub fn deinit(self: *BundleInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.executable_path);
        self.metadata.deinit(allocator);
    }
};

/// Breakdown of bundle component sizes
pub const ComponentSizes = struct {
    /// Size of bundlr stub executable
    stub_size: u64,

    /// Size of embedded Python runtime
    runtime_size: u64,

    /// Size of application assets (wheels, etc.)
    assets_size: u64,

    /// Size of metadata and configuration
    metadata_size: u64,

    /// Total size of all components
    total_size: u64,
};

/// Bundle metadata embedded in executable
pub const BundleMetadata = struct {
    /// Bundle format version
    bundle_version: []const u8,

    /// Package name
    package_name: []const u8,

    /// Package version
    package_version: []const u8,

    /// Python version
    python_version: []const u8,

    /// Target platform
    target_platform: []const u8,

    /// Build timestamp
    build_timestamp: i64,

    /// Bundlr version used
    bundlr_version: []const u8,

    /// Entry point information
    entry_point: ?[]const u8 = null,

    /// List of included packages
    included_packages: [][]const u8,

    /// Compression algorithm used
    compression: []const u8,

    pub fn deinit(self: *BundleMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.bundle_version);
        allocator.free(self.package_name);
        allocator.free(self.package_version);
        allocator.free(self.python_version);
        allocator.free(self.target_platform);
        allocator.free(self.bundlr_version);
        if (self.entry_point) |ep| allocator.free(ep);
        for (self.included_packages) |pkg| {
            allocator.free(pkg);
        }
        allocator.free(self.included_packages);
        allocator.free(self.compression);
    }
};

/// Self-extracting bundle generator
pub const BundleGenerator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BundleGenerator {
        return BundleGenerator{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BundleGenerator) void {
        _ = self;
    }

    /// Generate self-extracting bundle executable
    pub fn generateBundle(self: *BundleGenerator, options: BundleOptions) !BundleInfo {
        std.debug.print("📦 Generating self-extracting bundle...\n", .{});

        // Step 1: Create bundlr stub executable
        std.debug.print("  🔧 Creating bundlr stub...\n", .{});
        const stub_path = try self.createBundlrStub(options.target);
        defer self.allocator.free(stub_path);

        // Step 2: Prepare bundle components
        std.debug.print("  📋 Preparing bundle components...\n", .{});
        const bundle_components = try self.prepareBundleComponents(options);
        defer self.cleanupBundleComponents(bundle_components);

        // Step 3: Create bundle metadata
        std.debug.print("  📄 Creating bundle metadata...\n", .{});
        const metadata = try self.createBundleMetadata(options);

        // Step 4: Assemble final executable
        std.debug.print("  🔨 Assembling final executable...\n", .{});
        const final_executable = try self.assembleFinalExecutable(
            stub_path,
            bundle_components,
            metadata,
            options.output_path
        );
        defer self.allocator.free(final_executable);

        // Step 5: Set executable permissions
        try self.setExecutablePermissions(final_executable);

        // Step 6: Calculate component sizes
        const component_sizes = try self.calculateComponentSizes(
            stub_path,
            bundle_components,
            final_executable
        );

        std.debug.print("✅ Bundle generated: {s} ({} MB)\n", .{
            final_executable,
            component_sizes.total_size / (1024 * 1024),
        });

        return BundleInfo{
            .executable_path = try self.allocator.dupe(u8, final_executable),
            .total_size = component_sizes.total_size,
            .components = component_sizes,
            .metadata = metadata,
        };
    }

    /// Create bundlr stub executable for target platform
    fn createBundlrStub(self: *BundleGenerator, target: pipeline.TargetPlatform) ![]u8 {
        // Create a minimal Zig executable that will serve as the stub
        const stub_source = try self.generateStubSource(target);
        defer self.allocator.free(stub_source);

        const temp_dir = try self.createTempDirectory();
        defer self.allocator.free(temp_dir);
        defer self.cleanupTempDirectory(temp_dir);

        const stub_source_path = try std.fs.path.join(self.allocator, &[_][]const u8{ temp_dir, "stub.zig" });
        defer self.allocator.free(stub_source_path);

        // Write stub source to file
        const stub_file = try std.fs.createFileAbsolute(stub_source_path, .{});
        defer stub_file.close();
        try stub_file.writeAll(stub_source);

        // Compile stub for target platform (returns path in temp_dir)
        const temp_stub_path = try self.compileStubForTarget(stub_source_path, target);
        defer self.allocator.free(temp_stub_path);

        // Copy stub to a permanent location before temp cleanup
        const permanent_stub_dir = try self.createTempDirectory();
        defer self.allocator.free(permanent_stub_dir);
        const stub_name = switch (target) {
            .windows_x86_64, .windows_aarch64 => "bundlr_stub.exe",
            else => "bundlr_stub",
        };
        const permanent_stub_path = try std.fs.path.join(self.allocator, &[_][]const u8{ permanent_stub_dir, stub_name });

        try self.copyFile(temp_stub_path, permanent_stub_path);

        return permanent_stub_path;
    }

    /// Generate source code for bundlr stub
    fn generateStubSource(self: *BundleGenerator, target: pipeline.TargetPlatform) ![]u8 {
        _ = target;

        const stub_template =
            \\//! Bundlr self-extracting executable stub
            \\//! This is the entry point for a bundled Python application
            \\
            \\const std = @import("std");
            \\
            \\// Embedded bundle data (will be appended during bundle generation)
            \\extern const bundle_data: [*]const u8;
            \\extern const bundle_size: usize;
            \\
            \\pub fn main() !void {{
            \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            \\    defer _ = gpa.deinit();
            \\    const allocator = gpa.allocator();
            \\
            \\    // Get command line arguments
            \\    const args = try std.process.argsAlloc(allocator);
            \\    defer std.process.argsFree(allocator, args);
            \\
            \\    // Create temporary extraction directory
            \\    const temp_dir = createTempDirectory(allocator) catch |err| {
            \\        std.log.err("Failed to create temp directory: {}", .{err});
            \\        return err;
            \\    };
            \\    // Created temp directory successfully
            \\    defer cleanupTempDirectory(allocator, temp_dir);
            \\
            \\    // Extract embedded bundle to temp directory
            \\    try extractBundle(allocator, temp_dir);
            \\
            \\    // Set up Python environment
            \\    try setupPythonEnvironment(allocator, temp_dir);
            \\
            \\    // Install packages
            \\    try installPackages(allocator, temp_dir);
            \\
            \\    // Execute the application
            \\    try executeApplication(allocator, temp_dir, args[1..]);
            \\}}
            \\
            \\fn createTempDirectory(allocator: std.mem.Allocator) ![]u8 {{
            \\    const temp_name = try std.fmt.allocPrint(allocator, "bundlr_app_{}", .{std.time.timestamp()});
            \\    defer allocator.free(temp_name);
            \\
            \\    // Get cross-platform temp directory
            \\    const system_temp = getSystemTempDir(allocator) catch return error.TempDirNotFound;
            \\    defer allocator.free(system_temp);
            \\
            \\    const temp_path = try std.fs.path.join(allocator, &[_][]const u8{ system_temp, temp_name });
            \\    try std.fs.makeDirAbsolute(temp_path);
            \\
            \\    return temp_path;
            \\}}
            \\
            \\fn getSystemTempDir(allocator: std.mem.Allocator) ![]u8 {
            \\    const builtin = @import("builtin");
            \\    switch (builtin.os.tag) {
            \\        .windows => {
            \\            return std.process.getEnvVarOwned(allocator, "TMP") catch
            \\                std.process.getEnvVarOwned(allocator, "TEMP") catch
            \\                try allocator.dupe(u8, "C:\\\\Temp");
            \\        },
            \\        else => {
            \\            return std.process.getEnvVarOwned(allocator, "TMPDIR") catch
            \\                std.process.getEnvVarOwned(allocator, "TMP") catch
            \\                try allocator.dupe(u8, "/tmp");
            \\        },
            \\    }
            \\}
            \\
            \\fn cleanupTempDirectory(allocator: std.mem.Allocator, temp_dir: []const u8) void {
            \\    _ = allocator;
            \\    std.fs.deleteTreeAbsolute(temp_dir) catch |err| {
            \\        std.log.warn("Failed to cleanup temp directory: {}", .{err});
            \\    };
            \\}
            \\
            \\fn extractBundle(allocator: std.mem.Allocator, temp_dir: []const u8) !void {
            \\
            \\    // Read the current executable to find the embedded bundle
            \\    const exe_path = try std.fs.selfExePathAlloc(allocator);
            \\    defer allocator.free(exe_path);
            \\
            \\    const exe_file = try std.fs.openFileAbsolute(exe_path, .{});
            \\    defer exe_file.close();
            \\
            \\    const exe_stat = try exe_file.stat();
            \\    const exe_size = exe_stat.size;
            \\
            \\    // Find the start of the bundle by looking for a tar.gz signature
            \\    // The bundle is appended after the executable
            \\    var buffer: [8192]u8 = undefined;
            \\    var bundle_start: u64 = 0;
            \\
            \\    // Simple approach: scan from start to find gzip signature
            \\    var pos: u64 = 0;
            \\    while (pos < exe_size) : (pos += 512) {
            \\        try exe_file.seekTo(pos);
            \\        const bytes_read = try exe_file.readAll(buffer[0..]);
            \\
            \\        // Look for gzip magic number (1f 8b 08) - 08 is deflate compression
            \\        var i: usize = 0;
            \\        while (i < bytes_read - 2) : (i += 1) {
            \\            if (buffer[i] == 0x1f and buffer[i + 1] == 0x8b and buffer[i + 2] == 0x08) {
            \\                bundle_start = pos + i;
            \\                // Found valid gzip header
            \\                break;
            \\            }
            \\        }
            \\        if (bundle_start > 0) break;
            \\    }
            \\
            \\    if (bundle_start == 0) {
            \\        std.log.err("Could not find embedded bundle in executable", .{});
            \\        return error.BundleNotFound;
            \\    }
            \\
            \\    // Extract the bundle data to a temporary file
            \\    const bundle_file_path = try std.fmt.allocPrint(allocator, "{s}/bundle.tar.gz", .{temp_dir});
            \\    defer allocator.free(bundle_file_path);
            \\
            \\    // Creating bundle file
            \\    const bundle_file = std.fs.createFileAbsolute(bundle_file_path, .{}) catch |err| {
            \\        std.log.err("Failed to create bundle file: {} at path: {s}", .{ err, bundle_file_path });
            \\        return err;
            \\    };
            \\
            \\    // Copy bundle data from executable to bundle file
            \\    try exe_file.seekTo(bundle_start);
            \\    const extracted_bundle_size = exe_size - bundle_start;
            \\    // Copy bundle data from executable to bundle file
            \\
            \\    var copy_buffer: [16384]u8 = undefined;
            \\    var remaining = extracted_bundle_size;
            \\    var bytes_written: u64 = 0;
            \\    while (remaining > 0) {
            \\        const to_read = @min(remaining, copy_buffer.len);
            \\        const bytes_read = exe_file.readAll(copy_buffer[0..to_read]) catch |err| {
            \\            std.log.err("Error reading from executable: {}", .{err});
            \\            return err;
            \\        };
            \\        bundle_file.writeAll(copy_buffer[0..bytes_read]) catch |err| {
            \\            std.log.err("Error writing to bundle file: {}", .{err});
            \\            return err;
            \\        };
            \\        remaining -= bytes_read;
            \\        bytes_written += bytes_read;
            \\        if (bytes_read == 0) break;
            \\    }
            \\    // Bundle data copied successfully
            \\
            \\    // Close the file before tar extraction
            \\    bundle_file.close();
            \\
            \\    // Verify bundle file exists before extraction
            \\    std.fs.accessAbsolute(bundle_file_path, .{}) catch |err| {
            \\        std.log.err("Bundle file does not exist: {} at path: {s}", .{ err, bundle_file_path });
            \\        return err;
            \\    };
            \\
            \\    // Check if tar exists before extraction
            \\    const tar_check = std.process.Child.run(.{
            \\        .allocator = allocator,
            \\        .argv = &[_][]const u8{ "/bin/tar", "--version" },
            \\    }) catch |err| {
            \\        std.log.err("tar executable not found: {}", .{err});
            \\        return err;
            \\    };
            \\
            \\    if (tar_check.term != .Exited or tar_check.term.Exited != 0) {
            \\        std.log.err("tar command failed", .{});
            \\        return error.TarNotAvailable;
            \\    }
            \\
            \\    // Extract the bundle
            \\
            \\    const extract_result = std.process.Child.run(.{
            \\        .allocator = allocator,
            \\        .argv = &[_][]const u8{ "/bin/tar", "-xzf", bundle_file_path, "-C", temp_dir },
            \\    }) catch |err| {
            \\        std.log.err("Failed to run tar command: {} (Command: tar -xzf {s} -C {s})", .{ err, bundle_file_path, temp_dir });
            \\        return err;
            \\    };
            \\
            \\    if (extract_result.term.Exited != 0) {
            \\        std.log.err("Bundle extraction failed with exit code: {}", .{extract_result.term.Exited});
            \\        if (extract_result.stderr.len > 0) {
            \\            std.log.err("Tar stderr: {s}", .{extract_result.stderr});
            \\        }
            \\        return error.ExtractionFailed;
            \\    }
            \\    defer allocator.free(extract_result.stdout);
            \\    defer allocator.free(extract_result.stderr);
            \\}
            \\
            \\fn setupPythonEnvironment(allocator: std.mem.Allocator, temp_dir: []const u8) !void {
            \\    // Extract Python runtime from the bundle
            \\    const python_runtime_path = try std.fmt.allocPrint(allocator, "{s}/bundle/python_runtime.tar.gz", .{temp_dir});
            \\    defer allocator.free(python_runtime_path);
            \\
            \\    const python_dir = try std.fmt.allocPrint(allocator, "{s}/python_runtime", .{temp_dir});
            \\    defer allocator.free(python_dir);
            \\
            \\    // Create python runtime directory
            \\    std.fs.makeDirAbsolute(python_dir) catch |err| switch (err) {
            \\        error.PathAlreadyExists => {}, // Already exists, that's fine
            \\        else => return err,
            \\    };
            \\
            \\    // Extract Python runtime tar.gz
            \\    const extract_result = std.process.Child.run(.{
            \\        .allocator = allocator,
            \\        .argv = &[_][]const u8{ "/bin/tar", "-xzf", python_runtime_path, "-C", python_dir, "--strip-components=1" },
            \\    }) catch |err| {
            \\        std.log.err("Failed to extract Python runtime: {}", .{err});
            \\        return err;
            \\    };
            \\
            \\    if (extract_result.term.Exited != 0) {
            \\        std.log.err("Python runtime extraction failed with exit code: {}", .{extract_result.term.Exited});
            \\        return error.PythonExtractionFailed;
            \\    }
            \\
            \\    // Set up environment variables for the Python runtime
            \\    const python_home = try std.fmt.allocPrint(allocator, "{s}", .{python_dir});
            \\    defer allocator.free(python_home);
            \\
            \\    const assets_dir = try std.fmt.allocPrint(allocator, "{s}/bundle/assets", .{temp_dir});
            \\    defer allocator.free(assets_dir);
            \\
            \\    // Note: For simplicity, we'll rely on Python's sys.path manipulation
            \\    // rather than setting PYTHONHOME and PYTHONPATH environment variables
            \\    // The variables are used in other functions
            \\}
            \\
            \\fn installPackages(allocator: std.mem.Allocator, temp_dir: []const u8) !void {
            \\    std.log.info("Installing packages...", .{});
            \\    const python_exe = try std.fmt.allocPrint(allocator, "{s}/python_runtime/3.14/bin/python3.14", .{temp_dir});
            \\    defer allocator.free(python_exe);
            \\
            \\    const assets_dir = try std.fmt.allocPrint(allocator, "{s}/bundle/assets", .{temp_dir});
            \\    defer allocator.free(assets_dir);
            \\    // Installing packages from assets directory
            \\
            \\    var dir = std.fs.openDirAbsolute(assets_dir, .{ .iterate = true }) catch |err| {
            \\        std.log.err("Failed to open assets directory: {}", .{err});
            \\        return err;
            \\    };
            \\    defer dir.close();
            \\
            \\    var iterator = dir.iterate();
            \\    while (try iterator.next()) |entry| {
            \\        if (entry.kind != .file) continue;
            \\        // Install any file in assets directory
            \\
            \\        const asset_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{assets_dir, entry.name});
            \\        defer allocator.free(asset_path);
            \\
            \\        // Use the original wheel filename - it already has correct format
            \\        const install_path = asset_path;
            \\
            \\        const install_result = std.process.Child.run(.{
            \\            .allocator = allocator,
            \\            .argv = &[_][]const u8{ python_exe, "-m", "pip", "install", install_path },
            \\        }) catch |err| {
            \\            std.log.err("Failed to install {s}: {}", .{entry.name, err});
            \\            return err;
            \\        };
            \\        defer allocator.free(install_result.stdout);
            \\        defer allocator.free(install_result.stderr);
            \\
            \\        if (install_result.term.Exited != 0) {
            \\            std.log.err("Package install failed with exit code {}: {s}", .{install_result.term.Exited, install_result.stderr});
            \\        } else {
            \\            // Package installed successfully
            \\        }
            \\    }
            \\}
            \\
            \\fn executeApplication(allocator: std.mem.Allocator, temp_dir: []const u8, args: []const []const u8) !void {
            \\    // Construct path to Python executable
            \\    const python_exe = try std.fmt.allocPrint(allocator, "{s}/python_runtime/3.14/bin/python3.14", .{temp_dir});
            \\    defer allocator.free(python_exe);
            \\
            \\    // Read metadata to determine how to execute the application
            \\    const metadata_path = try std.fmt.allocPrint(allocator, "{s}/bundle/metadata.json", .{temp_dir});
            \\    defer allocator.free(metadata_path);
            \\
            \\    const metadata_file = std.fs.openFileAbsolute(metadata_path, .{}) catch |err| {
            \\        std.log.err("Could not open metadata file: {}", .{err});
            \\        return err;
            \\    };
            \\    defer metadata_file.close();
            \\
            \\    const metadata_content = try metadata_file.readToEndAlloc(allocator, 1024 * 1024);
            \\    defer allocator.free(metadata_content);
            \\
            \\    // Parse JSON metadata (simplified parsing for package_name)
            \\    const package_name = extractPackageNameFromJson(allocator, metadata_content) catch |err| {
            \\        std.log.err("Could not parse package name from metadata: {}", .{err});
            \\        return err;
            \\    };
            \\    defer allocator.free(package_name);
            \\
            \\    // Get assets directory for sys.path
            \\    const assets_dir = try std.fmt.allocPrint(allocator, "{s}/bundle/assets", .{temp_dir});
            \\    defer allocator.free(assets_dir);
            \\
            \\    // Build Python script to run the module as a command
            \\    const python_script = try std.fmt.allocPrint(allocator,
            \\        \\import sys
            \\        \\import subprocess
            \\        \\sys.exit(subprocess.call([sys.executable, '-m', '{s}'] + sys.argv[1:]))
            \\    , .{package_name});
            \\    defer allocator.free(python_script);
            \\
            \\    // Build command arguments: python -c "script" [user_args...]
            \\    const base_args = [_][]const u8{ python_exe, "-c", python_script };
            \\    const total_arg_count = base_args.len + args.len;
            \\    const argv = try allocator.alloc([]const u8, total_arg_count);
            \\    defer allocator.free(argv);
            \\
            \\    // Copy base arguments
            \\    @memcpy(argv[0..base_args.len], &base_args);
            \\
            \\    // Copy user arguments
            \\    for (args, 0..) |arg, i| {
            \\        argv[base_args.len + i] = arg;
            \\    }
            \\
            \\    // Execute the Python application
            \\    var child = std.process.Child.init(argv, allocator);
            \\    child.stdin_behavior = .Inherit;
            \\    child.stdout_behavior = .Inherit;
            \\    child.stderr_behavior = .Inherit;
            \\
            \\    const term = try child.spawnAndWait();
            \\
            \\    // Exit with the same code as the Python application
            \\    switch (term) {
            \\        .Exited => |code| std.process.exit(code),
            \\        .Signal => |sig| {
            \\            std.log.err("Application terminated by signal: {}", .{sig});
            \\            std.process.exit(1);
            \\        },
            \\        .Stopped => |sig| {
            \\            std.log.err("Application stopped by signal: {}", .{sig});
            \\            std.process.exit(1);
            \\        },
            \\        .Unknown => |code| {
            \\            std.log.err("Application terminated with unknown code: {}", .{code});
            \\            std.process.exit(1);
            \\        },
            \\    }
            \\}
            \\
            \\fn extractPackageNameFromJson(allocator: std.mem.Allocator, json_content: []const u8) ![]u8 {
            \\    // Simple JSON parsing to extract package_name
            \\    // Look for "package_name": "value"
            \\    const needle = "\"package_name\":";
            \\    const start_pos = std.mem.indexOf(u8, json_content, needle) orelse return error.PackageNameNotFound;
            \\
            \\    var pos = start_pos + needle.len;
            \\
            \\    // Skip whitespace and find opening quote
            \\    while (pos < json_content.len and (json_content[pos] == ' ' or json_content[pos] == '\t' or json_content[pos] == '\n')) {
            \\        pos += 1;
            \\    }
            \\
            \\    if (pos >= json_content.len or json_content[pos] != '"') {
            \\        return error.InvalidJsonFormat;
            \\    }
            \\
            \\    pos += 1; // Skip opening quote
            \\    const value_start = pos;
            \\
            \\    // Find closing quote
            \\    while (pos < json_content.len and json_content[pos] != '"') {
            \\        pos += 1;
            \\    }
            \\
            \\    if (pos >= json_content.len) {
            \\        return error.InvalidJsonFormat;
            \\    }
            \\
            \\    const value_end = pos;
            \\    return try allocator.dupe(u8, json_content[value_start..value_end]);
            \\}
        ;

        return try self.allocator.dupe(u8, stub_template);
    }

    /// Compile stub for target platform
    fn compileStubForTarget(self: *BundleGenerator, source_path: []const u8, target: pipeline.TargetPlatform) ![]u8 {
        const output_name = switch (target) {
            .windows_x86_64, .windows_aarch64 => "bundlr_stub.exe",
            else => "bundlr_stub",
        };

        const output_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ std.fs.path.dirname(source_path).?, output_name }
        );
        errdefer self.allocator.free(output_path); // Free on error

        // Build zig compile command for cross-compilation
        const target_string = switch (target) {
            .linux_x86_64 => "x86_64-linux-gnu",
            .linux_aarch64 => "aarch64-linux-gnu",
            .windows_x86_64 => "x86_64-windows-gnu",
            .windows_aarch64 => "aarch64-windows-gnu",
            .macos_x86_64 => "x86_64-macos",
            .macos_aarch64 => "aarch64-macos",
            .all => "native", // Compile for current platform
        };

        const compile_args = [_][]const u8{
            "zig",
            "build-exe",
            source_path,
            "-target",
            target_string,
            "-O",
            "ReleaseFast",
            "--name",
            output_name[0..output_name.len - if (std.mem.endsWith(u8, output_name, ".exe")) @as(usize, 4) else @as(usize, 0)],
        };

        const result = try bundlr.platform.process.run(
            self.allocator,
            &compile_args,
            std.fs.path.dirname(source_path).?
        );

        if (result != 0) {
            return error.StubCompilationFailed;
        }

        return output_path;
    }

    /// Prepare all bundle components for assembly
    fn prepareBundleComponents(self: *BundleGenerator, options: BundleOptions) !BundleComponents {
        const temp_dir = try self.createTempDirectory();

        // Create bundle directory structure
        const bundle_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ temp_dir, "bundle" });
        self.ensureDirExists(bundle_dir) catch |err| {
            std.debug.print("Error creating bundle directory {s}: {}\n", .{ bundle_dir, err });
            return err;
        };

        // Copy runtime bundle
        const runtime_dest = try std.fs.path.join(self.allocator, &[_][]const u8{ bundle_dir, "python_runtime.tar.gz" });
        std.debug.print("  📋 Copying runtime from: {s}\n", .{options.runtime_bundle.runtime_path});
        std.debug.print("  📋 Copying runtime to: {s}\n", .{runtime_dest});
        try self.copyFile(options.runtime_bundle.runtime_path, runtime_dest);

        // Copy assets
        const assets_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ bundle_dir, "assets" });
        try self.ensureDirExists(assets_dir);

        for (options.assets.assets) |asset| {
            if (asset.local_path) |local_path| {
                const asset_name = std.fs.path.basename(local_path);
                const asset_dest = try std.fs.path.join(self.allocator, &[_][]const u8{ assets_dir, asset_name });
                defer self.allocator.free(asset_dest);
                try self.copyFile(local_path, asset_dest);
            }
        }

        // Create metadata file
        const metadata_path = try std.fs.path.join(self.allocator, &[_][]const u8{ bundle_dir, "metadata.json" });
        try self.writeMetadataFile(metadata_path, options);

        // Create launcher script
        const launcher_path = try self.createLauncherScript(bundle_dir, options);

        return BundleComponents{
            .temp_dir = temp_dir,
            .bundle_dir = bundle_dir,
            .runtime_path = runtime_dest,
            .assets_dir = assets_dir,
            .metadata_path = metadata_path,
            .launcher_path = launcher_path,
        };
    }

    /// Bundle components structure
    const BundleComponents = struct {
        temp_dir: []const u8,
        bundle_dir: []const u8,
        runtime_path: []const u8,
        assets_dir: []const u8,
        metadata_path: []const u8,
        launcher_path: []const u8,
    };

    /// Create launcher script for the application
    fn createLauncherScript(self: *BundleGenerator, bundle_dir: []const u8, options: BundleOptions) ![]u8 {
        const launcher_path = try std.fs.path.join(self.allocator, &[_][]const u8{ bundle_dir, "launcher.sh" });

        const exec_command = if (options.entry_point) |ep| blk: {
            // Safely escape single quotes for use inside a single-quoted shell string
            const escaped_ep = try std.mem.replaceOwned(u8, self.allocator, ep, "'", "'\"'\"'");
            defer self.allocator.free(escaped_ep);
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "\"$PYTHON_RUNTIME/bin/python\" -c '{s}' \"$@\"",
                .{escaped_ep},
            );
        } else blk: {
            const root = options.dependencies.root_package;
            // Safely escape single quotes for use inside a single-quoted shell string
            const escaped_root = try std.mem.replaceOwned(u8, self.allocator, root, "'", "'\"'\"'");
            defer self.allocator.free(escaped_root);
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "\"$PYTHON_RUNTIME/bin/python\" -m '{s}' \"$@\"",
                .{escaped_root},
            );
        };
        defer self.allocator.free(exec_command);

        const launcher_content = try std.fmt.allocPrint(self.allocator,
            \\#!/bin/bash
            \\# Bundlr application launcher script
            \\
            \\BUNDLE_DIR="$( cd "$( dirname "${{BASH_SOURCE[0]}}" )" && pwd )"
            \\PYTHON_RUNTIME="$BUNDLE_DIR/python_runtime"
            \\ASSETS_DIR="$BUNDLE_DIR/assets"
            \\
            \\# Extract Python runtime if needed
            \\if [ ! -d "$PYTHON_RUNTIME" ]; then
            \\    /bin/tar -xzf "$BUNDLE_DIR/python_runtime.tar.gz" -C "$BUNDLE_DIR"
            \\fi
            \\
            \\# Set up Python environment
            \\export PYTHONHOME="$PYTHON_RUNTIME"
            \\export PYTHONPATH="$ASSETS_DIR:$PYTHONPATH"
            \\
            \\# Execute application
            \\{s}
        , .{exec_command});
        defer self.allocator.free(launcher_content);

        const launcher_file = try std.fs.createFileAbsolute(launcher_path, .{});
        defer launcher_file.close();
        try launcher_file.writeAll(launcher_content);

        return launcher_path;
    }

    /// Write metadata file
    fn writeMetadataFile(self: *BundleGenerator, metadata_path: []const u8, options: BundleOptions) !void {
        const metadata_content = try std.fmt.allocPrint(self.allocator,
            \\{{
            \\  "bundle_version": "1.0",
            \\  "package_name": "{s}",
            \\  "python_version": "{s}",
            \\  "target_platform": "{s}",
            \\  "build_timestamp": {},
            \\  "bundlr_version": "{s}",
            \\  "entry_point": {s}
            \\}}
        , .{
            options.dependencies.root_package,
            options.runtime_bundle.metadata.python_version,
            options.target.toString(),
            options.metadata.build_time,
            options.metadata.bundlr_version,
            if (options.entry_point) |ep|
                try std.fmt.allocPrint(self.allocator, "\"{s}\"", .{ep})
            else
                "null"
        });
        defer self.allocator.free(metadata_content);

        const metadata_file = try std.fs.createFileAbsolute(metadata_path, .{});
        defer metadata_file.close();
        try metadata_file.writeAll(metadata_content);
    }

    /// Create bundle metadata
    fn createBundleMetadata(self: *BundleGenerator, options: BundleOptions) !BundleMetadata {
        // Build list of included packages
        var packages = try self.allocator.alloc([]const u8, options.dependencies.packages.len);
        for (options.dependencies.packages, 0..) |pkg, i| {
            packages[i] = try self.allocator.dupe(u8, pkg.name);
        }

        return BundleMetadata{
            .bundle_version = try self.allocator.dupe(u8, "1.0"),
            .package_name = try self.allocator.dupe(u8, options.dependencies.root_package),
            .package_version = try self.allocator.dupe(u8, "1.0.0"), // TODO: Extract from dependencies
            .python_version = try self.allocator.dupe(u8, options.runtime_bundle.metadata.python_version),
            .target_platform = try self.allocator.dupe(u8, options.target.toString()),
            .build_timestamp = options.metadata.build_time,
            .bundlr_version = try self.allocator.dupe(u8, options.metadata.bundlr_version),
            .entry_point = if (options.entry_point) |ep| try self.allocator.dupe(u8, ep) else null,
            .included_packages = packages,
            .compression = try self.allocator.dupe(u8, "xz"),
        };
    }

    /// Assemble final executable from components
    fn assembleFinalExecutable(
        self: *BundleGenerator,
        stub_path: []const u8,
        components: BundleComponents,
        metadata: BundleMetadata,
        output_path: []const u8
    ) ![]u8 {
        _ = metadata;

        // Create tar archive of bundle components (use gzip for speed since runtime is already compressed)
        const bundle_archive = try std.fmt.allocPrint(self.allocator, "{s}/bundle.tar.gz", .{components.temp_dir});
        defer self.allocator.free(bundle_archive);

        const tar_args = [_][]const u8{
            "tar",
            "-C",
            std.fs.path.dirname(components.bundle_dir).?,
            "-czf",
            bundle_archive,
            std.fs.path.basename(components.bundle_dir),
        };

        const result = try bundlr.platform.process.run(self.allocator, &tar_args, ".");
        if (result != 0) {
            return error.BundleArchiveCreationFailed;
        }

        // Combine stub executable with bundle archive
        const final_path = try self.allocator.dupe(u8, output_path);

        // Copy stub to final location
        try self.copyFile(stub_path, final_path);

        // Append bundle data to executable
        try self.appendBundleToExecutable(final_path, bundle_archive);

        return final_path;
    }

    /// Append bundle data to executable
    fn appendBundleToExecutable(self: *BundleGenerator, executable_path: []const u8, bundle_path: []const u8) !void {
        // Append bundle using cat command
        const cat_command = try std.fmt.allocPrint(self.allocator, "cat '{s}' >> '{s}'", .{ bundle_path, executable_path });
        defer self.allocator.free(cat_command);

        const cat_args = [_][]const u8{ "sh", "-c", cat_command };

        const result = try bundlr.platform.process.run(self.allocator, &cat_args, ".");
        if (result != 0) {
            return error.BundleAppendFailed;
        }
    }

    /// Set executable permissions
    fn setExecutablePermissions(self: *BundleGenerator, executable_path: []const u8) !void {
        const chmod_args = [_][]const u8{ "chmod", "+x", executable_path };
        const result = try bundlr.platform.process.run(self.allocator, &chmod_args, ".");
        if (result != 0) {
            return error.PermissionSetFailed;
        }
    }

    /// Calculate component sizes
    fn calculateComponentSizes(
        self: *BundleGenerator,
        stub_path: []const u8,
        components: BundleComponents,
        final_executable: []const u8
    ) !ComponentSizes {
        const stub_size = try self.getFileSize(stub_path);
        const runtime_size = try self.getFileSize(components.runtime_path);
        const assets_size = try self.getDirectorySize(components.assets_dir);
        const metadata_size = try self.getFileSize(components.metadata_path);
        const total_size = try self.getFileSize(final_executable);

        return ComponentSizes{
            .stub_size = stub_size,
            .runtime_size = runtime_size,
            .assets_size = assets_size,
            .metadata_size = metadata_size,
            .total_size = total_size,
        };
    }

    /// Cleanup bundle components
    fn cleanupBundleComponents(self: *BundleGenerator, components: BundleComponents) void {
        self.cleanupTempDirectory(components.temp_dir);
        self.allocator.free(components.temp_dir);
        self.allocator.free(components.bundle_dir);
        self.allocator.free(components.runtime_path);
        self.allocator.free(components.assets_dir);
        self.allocator.free(components.metadata_path);
        self.allocator.free(components.launcher_path);
    }

    /// Helper functions
    fn createTempDirectory(self: *BundleGenerator) ![]u8 {
        // Use cross-platform temp directory
        var paths = bundlr.platform.paths.Paths.init(self.allocator);
        const system_temp = try paths.getTemporaryDir();
        defer self.allocator.free(system_temp);

        // Use nanosecond timestamp + random number to avoid collisions
        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
        const random_num = prng.random().int(u32);
        const temp_name = try std.fmt.allocPrint(self.allocator, "bundlr_bundle_{}_{}", .{ std.time.timestamp(), random_num });
        defer self.allocator.free(temp_name);

        // Create temp directory in system temp location
        const tmp_path = try std.fs.path.join(self.allocator, &[_][]const u8{ system_temp, temp_name });
        defer self.allocator.free(tmp_path);

        // Create directory with error handling for existing paths
        std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Try again with a different name
                const retry_name = try std.fmt.allocPrint(self.allocator, "bundlr_bundle_{}_{}_{}", .{ std.time.timestamp(), random_num, prng.random().int(u16) });
                defer self.allocator.free(retry_name);
                const retry_path = try std.fs.path.join(self.allocator, &[_][]const u8{ system_temp, retry_name });
                try std.fs.makeDirAbsolute(retry_path);
                return retry_path;
            },
            else => return err,
        };

        // Return the full path to the temp directory
        return try std.fs.path.join(self.allocator, &[_][]const u8{ system_temp, temp_name });
    }

    fn cleanupTempDirectory(self: *BundleGenerator, temp_dir: []const u8) void {
        _ = self;
        std.fs.deleteTreeAbsolute(temp_dir) catch |err| {
            std.log.warn("Failed to cleanup temp directory {s}: {}", .{ temp_dir, err });
        };
    }

    /// Create directory if it doesn't exist, ignore if it already exists
    fn ensureDirExists(self: *BundleGenerator, path: []const u8) !void {
        _ = self;
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Directory already exists, this is fine
                return;
            },
            else => return err,
        };
    }

    fn copyFile(self: *BundleGenerator, src: []const u8, dest: []const u8) !void {
        const cp_args = [_][]const u8{ "cp", src, dest };
        const result = try bundlr.platform.process.run(self.allocator, &cp_args, ".");
        if (result != 0) {
            return error.FileCopyFailed;
        }
    }

    fn getFileSize(self: *BundleGenerator, file_path: []const u8) !u64 {
        _ = self;
        // Handle both absolute and relative paths
        const file = if (std.fs.path.isAbsolute(file_path))
            std.fs.openFileAbsolute(file_path, .{}) catch return 0
        else
            std.fs.cwd().openFile(file_path, .{}) catch return 0;
        defer file.close();
        const stat = try file.stat();
        return stat.size;
    }

    fn getDirectorySize(self: *BundleGenerator, dir_path: []const u8) !u64 {
        _ = self;
        _ = dir_path;
        // TODO: Implement directory size calculation
        return 10 * 1024 * 1024; // Placeholder: 10MB
    }
};

// Tests
test "bundle generator initialization" {
    const allocator = std.testing.allocator;
    var generator = BundleGenerator.init(allocator);
    defer generator.deinit();

    // Test stub source generation
    const stub_source = try generator.generateStubSource(.linux_x86_64);
    defer allocator.free(stub_source);

    try std.testing.expect(std.mem.indexOf(u8, stub_source, "bundlr_app_") != null);
}

test "component sizes calculation" {
    const allocator = std.testing.allocator;
    var generator = BundleGenerator.init(allocator);
    defer generator.deinit();

    // Test with placeholder data
    const components = BundleGenerator.BundleComponents{
        .temp_dir = "/tmp/test",
        .bundle_dir = "/tmp/test/bundle",
        .runtime_path = "/tmp/test/runtime.tar.xz",
        .assets_dir = "/tmp/test/assets",
        .metadata_path = "/tmp/test/metadata.json",
        .launcher_path = "/tmp/test/launcher.sh",
    };

    // This would normally calculate real sizes, but will return 0 for non-existent files
    const sizes = try generator.calculateComponentSizes("/tmp/stub", components, "/tmp/final");

    try std.testing.expect(sizes.total_size == 0); // Files don't exist, so size is 0
}