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

    /// Discovered Python module name (overrides package name for python -m)
    module_name: ?[]const u8 = null,

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
        const final_executable = try self.assembleFinalExecutable(stub_path, bundle_components, metadata, options.output_path);
        defer self.allocator.free(final_executable);

        // Step 5: Set executable permissions
        try self.setExecutablePermissions(final_executable);

        // Step 6: Calculate component sizes
        const component_sizes = try self.calculateComponentSizes(stub_path, bundle_components, final_executable);

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

        // ---------------------------------------------------------------------------
        // CHANGES vs. previous version
        // ---------------------------------------------------------------------------
        // 1. main(): removed `defer cleanupTempDirectory`; added cleanupOldAppTempDirs
        //    call and `.bundlr_ready` guard so extraction/install are skipped on warm
        //    runs.
        // 2. Replaced createTempDirectory (timestamp-based) with
        //    getOrCreateTempDirectory (stable FNV-1a hash of exe path + size).
        // 3. Added cleanupOldAppTempDirs: scans system temp for bundlr_app_* dirs and
        //    removes entries whose mtime is older than BUNDLR_TEMP_RETENTION_DAYS
        //    (default 30).  Uses Dir.stat() — which in Zig 0.15.2 takes *no* args and
        //    stats the directory handle itself — rather than the invalid
        //    dir.stat(entry.name) call.
        // 4. installPackages: new `ready_marker` parameter; creates the marker file
        //    only after all packages install successfully so interrupted runs retry.
        // ---------------------------------------------------------------------------
        const stub_template =
            \\//! Bundlr self-extracting executable stub
            \\//! This is the entry point for a bundled Python application
            \\
            \\const std = @import("std");
            \\const builtin = @import("builtin");
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
            \\    // Remove stale bundlr_app_* directories (>BUNDLR_TEMP_RETENTION_DAYS days old).
            \\    // Non-fatal: a warning is logged and execution continues on failure.
            \\    cleanupOldAppTempDirs(allocator) catch |err| {
            \\        std.log.warn("Old temp-dir cleanup failed (non-fatal): {}", .{err});
            \\    };
            \\
            \\    // Derive a stable directory from the executable's identity.
            \\    // The directory persists across runs; no defer-cleanup is registered.
            \\    const temp_dir = try getOrCreateTempDirectory(allocator);
            \\    defer allocator.free(temp_dir);
            \\
            \\    // Ready marker: present only after a successful installPackages run.
            \\    const ready_marker = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, ".bundlr_ready" });
            \\    defer allocator.free(ready_marker);
            \\
            \\    const is_ready = blk: {
            \\        std.fs.accessAbsolute(ready_marker, .{}) catch {
            \\            break :blk false;
            \\        };
            \\        break :blk true;
            \\    };
            \\
            \\    if (!is_ready) {
            \\        // Full cold-start: extract, set up Python, install packages.
            \\        try extractBundle(allocator, temp_dir);
            \\        try setupPythonEnvironment(allocator, temp_dir);
            \\        // installPackages creates `ready_marker` on success.
            \\        try installPackages(allocator, temp_dir, ready_marker);
            \\    }
            \\
            \\    // Execute the application
            \\    try executeApplication(allocator, temp_dir, args[1..]);
            \\}}
            \\
            \\// ---------------------------------------------------------------------------
            \\// Stable temp-directory: derived from a FNV-1a hash of the executable's
            \\// absolute path and its file size.  Moving the binary or changing its
            \\// content (different size) produces a new directory; identical exe reuses
            \\// the cached one.
            \\// ---------------------------------------------------------------------------
            \\fn getOrCreateTempDirectory(allocator: std.mem.Allocator) ![]u8 {
            \\    const exe_path = try std.fs.selfExePathAlloc(allocator);
            \\    defer allocator.free(exe_path);
            \\
            \\    const exe_file = try std.fs.openFileAbsolute(exe_path, .{});
            \\    defer exe_file.close();
            \\    const exe_stat = try exe_file.stat();
            \\
            \\    // FNV-1a 64-bit over exe_path bytes then exe_size bytes.
            \\    var hash: u64 = 14695981039346656037;
            \\    for (exe_path) |byte| {
            \\        hash ^= @as(u64, byte);
            \\        hash *%= 1099511628211;
            \\    }
            \\    var size_bytes: [8]u8 = undefined;
            \\    std.mem.writeInt(u64, &size_bytes, @as(u64, exe_stat.size), .little);
            \\    for (size_bytes) |byte| {
            \\        hash ^= @as(u64, byte);
            \\        hash *%= 1099511628211;
            \\    }
            \\
            \\    const system_temp = getSystemTempDir(allocator) catch return error.TempDirNotFound;
            \\    defer allocator.free(system_temp);
            \\
            \\    const dir_name = try std.fmt.allocPrint(allocator, "bundlr_app_{x:0>16}", .{hash});
            \\    defer allocator.free(dir_name);
            \\
            \\    const temp_path = try std.fs.path.join(allocator, &[_][]const u8{ system_temp, dir_name });
            \\
            \\    std.fs.makeDirAbsolute(temp_path) catch |err| switch (err) {
            \\        error.PathAlreadyExists => {}, // Reuse existing directory — expected on warm runs.
            \\        else => return err,
            \\    };
            \\
            \\    return temp_path;
            \\}
            \\
            \\// ---------------------------------------------------------------------------
            \\// Mtime-based cleanup of old bundlr_app_* directories.
            \\//
            \\// Zig 0.15.2 note: std.fs.Dir.stat() takes *no* arguments — it stats the
            \\// directory handle itself.  The previously incorrect dir.stat(entry.name)
            \\// call (which would produce "member function expected 0 argument(s), found 1")
            \\// is avoided by opening each candidate directory as a Dir handle first.
            \\// ---------------------------------------------------------------------------
            \\fn cleanupOldAppTempDirs(allocator: std.mem.Allocator) !void {
            \\    // Honour BUNDLR_TEMP_RETENTION_DAYS; fall back to 30 days.
            \\    const retention_days: i64 = blk: {
            \\        const env_val = std.process.getEnvVarOwned(allocator, "BUNDLR_TEMP_RETENTION_DAYS") catch break :blk 30;
            \\        defer allocator.free(env_val);
            \\        break :blk std.fmt.parseInt(i64, env_val, 10) catch 30;
            \\    };
            \\
            \\    const system_temp = getSystemTempDir(allocator) catch return;
            \\    defer allocator.free(system_temp);
            \\
            \\    var tmp_dir = std.fs.openDirAbsolute(system_temp, .{ .iterate = true }) catch return;
            \\    defer tmp_dir.close();
            \\
            \\    const now_ns: i128 = std.time.nanoTimestamp();
            \\    // retention_ns: days → nanoseconds (1 day = 86400 * 1_000_000_000 ns)
            \\    const retention_ns: i128 = @as(i128, retention_days) * 86400 * 1_000_000_000;
            \\
            \\    var it = tmp_dir.iterate();
            \\    while (try it.next()) |entry| {
            \\        if (entry.kind != .directory) continue;
            \\        if (!std.mem.startsWith(u8, entry.name, "bundlr_app_")) continue;
            \\
            \\        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ system_temp, entry.name });
            \\        defer allocator.free(full_path);
            \\
            \\        // Open the directory as a handle so we can call Dir.stat() (0-arg form).
            \\        // This is the correct Zig 0.15.2 API; dir.stat(entry.name) does not exist.
            \\        var sub_dir = std.fs.openDirAbsolute(full_path, .{}) catch continue;
            \\        defer sub_dir.close();
            \\        const st = sub_dir.stat() catch continue;
            \\
            \\        const age_ns: i128 = now_ns - st.mtime;
            \\        if (age_ns > retention_ns) {
            \\            std.fs.deleteTreeAbsolute(full_path) catch |err| {
            \\                std.log.warn("Failed to remove stale temp dir {s}: {}", .{ full_path, err });
            \\            };
            \\        }
            \\    }
            \\}
            \\
            \\fn getSystemTempDir(allocator: std.mem.Allocator) ![]u8 {
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
            \\fn extractTarGz(allocator: std.mem.Allocator, archive_path: []const u8, target_dir: []const u8, strip_components: ?u32) !void {
            \\    switch (builtin.os.tag) {
            \\        .windows => {
            \\            // Two-stage: decompress gzip with PowerShell, then extract tar
            \\            const tar_path = try allocator.dupe(u8, archive_path[0..archive_path.len-3]);
            \\            defer allocator.free(tar_path);
            \\            // Decompress gzip using .NET GZipStream
            \\            const decompress_cmd = try std.fmt.allocPrint(allocator,
            \\                "$in = [System.IO.File]::OpenRead('{s}'); " ++
            \\                "$out = [System.IO.File]::Create('{s}'); " ++
            \\                "$gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress); " ++
            \\                "$gz.CopyTo($out); $gz.Close(); $out.Close(); $in.Close()",
            \\                .{ archive_path, tar_path });
            \\            defer allocator.free(decompress_cmd);
            \\            const decomp_result = std.process.Child.run(.{
            \\                .allocator = allocator,
            \\                .argv = &[_][]const u8{ "powershell", "-NoProfile", "-Command", decompress_cmd },
            \\            }) catch |err| {
            \\                std.log.err("PowerShell gzip decompress failed: {}", .{err});
            \\                return err;
            \\            };
            \\            defer allocator.free(decomp_result.stdout);
            \\            defer allocator.free(decomp_result.stderr);
            \\            if (decomp_result.term != .Exited or decomp_result.term.Exited != 0) {
            \\                std.log.err("Gzip decompression failed: {s}", .{decomp_result.stderr});
            \\                return error.ExtractionFailed;
            \\            }
            \\            // Extract tar (without -z flag)
            \\            const tar_argv = if (strip_components) |sc| blk: {
            \\                const strip_arg = try std.fmt.allocPrint(allocator, "--strip-components={}", .{sc});
            \\                break :blk &[_][]const u8{ "tar", "-xf", tar_path, "-C", target_dir, strip_arg };
            \\            } else &[_][]const u8{ "tar", "-xf", tar_path, "-C", target_dir };
            \\            const result = std.process.Child.run(.{
            \\                .allocator = allocator,
            \\                .argv = tar_argv,
            \\            }) catch |err| {
            \\                std.log.err("tar extraction failed: {}", .{err});
            \\                return err;
            \\            };
            \\            defer allocator.free(result.stdout);
            \\            defer allocator.free(result.stderr);
            \\            if (result.term != .Exited or result.term.Exited != 0) {
            \\                std.log.err("tar extraction failed: {s}", .{result.stderr});
            \\                return error.ExtractionFailed;
            \\            }
            \\            // Cleanup intermediate tar file
            \\            std.fs.deleteFileAbsolute(tar_path) catch {};
            \\        },
            \\        else => {
            \\            // Unix: use tar directly
            \\            const tar_argv = if (strip_components) |sc| blk: {
            \\                const strip_arg = try std.fmt.allocPrint(allocator, "--strip-components={}", .{sc});
            \\                break :blk &[_][]const u8{ "tar", "-xzf", archive_path, "-C", target_dir, strip_arg };
            \\            } else &[_][]const u8{ "tar", "-xzf", archive_path, "-C", target_dir };
            \\            const result = try std.process.Child.run(.{
            \\                .allocator = allocator,
            \\                .argv = tar_argv,
            \\            });
            \\            defer allocator.free(result.stdout);
            \\            defer allocator.free(result.stderr);
            \\            if (result.term != .Exited or result.term.Exited != 0) {
            \\                std.log.err("tar extraction failed: {s}", .{result.stderr});
            \\                return error.ExtractionFailed;
            \\            }
            \\        },
            \\    }
            \\}
            \\
            \\fn getPythonExePath(allocator: std.mem.Allocator, temp_dir: []const u8) ![]u8 {
            \\    // Read Python version from metadata to construct correct path
            \\    const metadata_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "bundle", "metadata.json" });
            \\    defer allocator.free(metadata_path);
            \\
            \\    const python_version = extractPythonVersionFromMetadata(allocator, metadata_path) catch blk: {
            \\        std.log.warn("Could not read Python version from metadata, attempting runtime discovery", .{});
            \\        break :blk try discoverPythonExecutable(allocator, temp_dir);
            \\    };
            \\    defer allocator.free(python_version);
            \\
            \\    return switch (builtin.os.tag) {
            \\        .windows => try std.fmt.allocPrint(allocator, "{s}\\\\python_runtime\\\\python.exe", .{temp_dir}),
            \\        else => try std.fmt.allocPrint(allocator, "{s}/python_runtime/bin/python{s}", .{ temp_dir, python_version }),
            \\    };
            \\}
            \\
            \\fn extractPythonVersionFromMetadata(allocator: std.mem.Allocator, metadata_path: []const u8) ![]u8 {
            \\    const metadata_file = try std.fs.openFileAbsolute(metadata_path, .{});
            \\    defer metadata_file.close();
            \\
            \\    const metadata_content = try metadata_file.readToEndAlloc(allocator, 1024 * 1024);
            \\    defer allocator.free(metadata_content);
            \\
            \\    // Look for "python_version": "value"
            \\    const needle = "\"python_version\":";
            \\    const start_pos = std.mem.indexOf(u8, metadata_content, needle) orelse return error.PythonVersionNotFound;
            \\
            \\    var pos = start_pos + needle.len;
            \\
            \\    // Skip whitespace and find opening quote
            \\    while (pos < metadata_content.len and (metadata_content[pos] == ' ' or metadata_content[pos] == '\t' or metadata_content[pos] == '\n')) {
            \\        pos += 1;
            \\    }
            \\
            \\    if (pos >= metadata_content.len or metadata_content[pos] != '"') {
            \\        return error.InvalidJsonFormat;
            \\    }
            \\
            \\    pos += 1; // Skip opening quote
            \\    const value_start = pos;
            \\
            \\    // Find closing quote
            \\    while (pos < metadata_content.len and metadata_content[pos] != '"') {
            \\        pos += 1;
            \\    }
            \\
            \\    if (pos >= metadata_content.len) {
            \\        return error.InvalidJsonFormat;
            \\    }
            \\
            \\    const value_end = pos;
            \\    return try allocator.dupe(u8, metadata_content[value_start..value_end]);
            \\}
            \\
            \\fn discoverPythonExecutable(allocator: std.mem.Allocator, temp_dir: []const u8) ![]u8 {
            \\
            \\    switch (builtin.os.tag) {
            \\        .windows => {
            \\            // On Windows, python.exe should be at the root of the runtime
            \\            return try allocator.dupe(u8, "");
            \\        },
            \\        else => {
            \\            // On Unix, scan the bin directory for python executables
            \\            const bin_dir_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "python_runtime", "bin" });
            \\            defer allocator.free(bin_dir_path);
            \\
            \\            var bin_dir = std.fs.openDirAbsolute(bin_dir_path, .{ .iterate = true }) catch {
            \\                // Fallback to generic python3 if bin dir doesn't exist
            \\                return try allocator.dupe(u8, "3");
            \\            };
            \\            defer bin_dir.close();
            \\
            \\            var iterator = bin_dir.iterate();
            \\            while (try iterator.next()) |entry| {
            \\                if (entry.kind != .file) continue;
            \\
            \\                // Look for python3.X executables
            \\                if (std.mem.startsWith(u8, entry.name, "python3.") and entry.name.len > 8) {
            \\                    const version_part = entry.name[6..]; // Skip "python" to get "3.X"
            \\                    return try allocator.dupe(u8, version_part);
            \\                }
            \\                // Look for python3 (without version)
            \\                if (std.mem.eql(u8, entry.name, "python3")) {
            \\                    return try allocator.dupe(u8, "3");
            \\                }
            \\            }
            \\
            \\            // Fallback to generic python3
            \\            return try allocator.dupe(u8, "3");
            \\        },
            \\    }
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
            \\    // Extract the bundle using cross-platform extraction
            \\    try extractTarGz(allocator, bundle_file_path, temp_dir, null);
            \\}
            \\
            \\fn setupPythonEnvironment(allocator: std.mem.Allocator, temp_dir: []const u8) !void {
            \\    // Extract Python runtime from the bundle
            \\    const python_runtime_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "bundle", "python_runtime.tar.gz" });
            \\    defer allocator.free(python_runtime_path);
            \\
            \\    const python_dir = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "python_runtime" });
            \\    defer allocator.free(python_dir);
            \\
            \\    // Create python runtime directory
            \\    std.fs.makeDirAbsolute(python_dir) catch |err| switch (err) {
            \\        error.PathAlreadyExists => {}, // Already exists, that's fine
            \\        else => return err,
            \\    };
            \\
            \\    // Extract Python runtime tar.gz using cross-platform extraction
            \\    try extractTarGz(allocator, python_runtime_path, python_dir, 1);
            \\}
            \\
            \\// installPackages now accepts `ready_marker`: the path to `.bundlr_ready`.
            \\// The marker is created *only* after all packages install successfully so
            \\// that an interrupted run leaves no marker and will retry on next launch.
            \\fn installPackages(allocator: std.mem.Allocator, temp_dir: []const u8, ready_marker: []const u8) !void {
            \\    std.log.info("Installing packages...", .{});
            \\    const python_exe = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "python_runtime", if (builtin.os.tag == .windows) "python.exe" else "bin/python" });
            \\    defer allocator.free(python_exe);
            \\
            \\    const assets_dir = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "bundle", "assets" });
            \\    defer allocator.free(assets_dir);
            \\
            \\    var dir = std.fs.openDirAbsolute(assets_dir, .{ .iterate = true }) catch {
            \\        // Assets dir absent — mark ready so we don't retry pointlessly.
            \\        std.log.warn("Assets directory not found; skipping package install.", .{});
            \\        const mf = std.fs.createFileAbsolute(ready_marker, .{}) catch return;
            \\        mf.close();
            \\        return;
            \\    };
            \\    defer dir.close();
            \\
            \\    var it = dir.iterate();
            \\    while (try it.next()) |entry| {
            \\        if (entry.kind != .directory) continue;
            \\        if (!std.mem.startsWith(u8, entry.name, "bundlr_git_")) continue;
            \\
            \\        const src_path = try std.fs.path.join(allocator, &[_][]const u8{ assets_dir, entry.name });
            \\        defer allocator.free(src_path);
            \\
            \\        std.log.info("Installing from bundled source: {s}", .{src_path});
            \\        const result = try std.process.Child.run(.{
            \\            .allocator = allocator,
            \\            .argv = &[_][]const u8{ python_exe, "-m", "pip", "install", src_path },
            \\        });
            \\        defer allocator.free(result.stdout);
            \\        defer allocator.free(result.stderr);
            \\        if (result.term != .Exited or result.term.Exited != 0) {
            \\            std.log.err("pip install failed: {s}", .{result.stderr});
            \\            return error.PackageInstallFailed;
            \\        }
            \\
            \\        // Success — create ready marker so subsequent runs skip setup.
            \\        const marker_file = std.fs.createFileAbsolute(ready_marker, .{}) catch |err| {
            \\            std.log.warn("Could not create ready marker: {}", .{err});
            \\            return; // Non-fatal: next run will redo install, which is safe.
            \\        };
            \\        marker_file.close();
            \\        return;
            \\    }
            \\
            \\    std.log.warn("No bundled source directory found in assets, nothing to install", .{});
            \\    // Still mark ready: nothing to install means the env is usable as-is.
            \\    const marker_file = std.fs.createFileAbsolute(ready_marker, .{}) catch |err| {
            \\        std.log.warn("Could not create ready marker: {}", .{err});
            \\        return;
            \\    };
            \\    marker_file.close();
            \\}
            \\
            \\fn extractSourceBranch(allocator: std.mem.Allocator, json: []const u8) ?[]u8 {
            \\    const needle = "\"source_branch\":";
            \\    const start = std.mem.indexOf(u8, json, needle) orelse return null;
            \\    const after_key = start + needle.len;
            \\    const trimmed = std.mem.trimLeft(u8, json[after_key..], " \t\n");
            \\    if (trimmed.len == 0 or trimmed[0] == 'n') return null;
            \\    if (trimmed[0] != '"') return null;
            \\    const quote_end = std.mem.indexOf(u8, trimmed[1..], "\"") orelse return null;
            \\    return allocator.dupe(u8, trimmed[1..quote_end + 1]) catch null;
            \\}
            \\
            \\fn extractSourceUrl(allocator: std.mem.Allocator, json: []const u8) ?[]u8 {
            \\    const needle = "\"source_url\":";
            \\    const start = std.mem.indexOf(u8, json, needle) orelse return null;
            \\    const after_key = start + needle.len;
            \\    const trimmed = std.mem.trimLeft(u8, json[after_key..], " \t\n");
            \\    if (trimmed.len == 0 or trimmed[0] == 'n') return null;
            \\    if (trimmed[0] != '"') return null;
            \\    const quote_end = std.mem.indexOf(u8, trimmed[1..], "\"") orelse return null;
            \\    return allocator.dupe(u8, trimmed[1..quote_end + 1]) catch null;
            \\}
            \\
            \\fn executeApplication(allocator: std.mem.Allocator, temp_dir: []const u8, args: []const []const u8) !void {
            \\    // Construct path to Python executable
            \\    const python_exe = try getPythonExePath(allocator, temp_dir);
            \\    defer allocator.free(python_exe);
            \\
            \\    // Read metadata to determine how to execute the application
            \\    const metadata_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "bundle", "metadata.json" });
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
            \\    const assets_dir = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "bundle", "assets" });
            \\    defer allocator.free(assets_dir);
            \\
            \\    const python_script = if (extractEntryPointFromJson(allocator, metadata_content)) |ep| blk: {
            \\        defer allocator.free(ep);
            \\        break :blk try std.fmt.allocPrint(allocator,
            \\            \\import sys
            \\            \\import subprocess
            \\            \\try:
            \\            \\    sys.exit(subprocess.call([sys.executable, '-m', '{s}'] + sys.argv[1:]))
            \\            \\except KeyboardInterrupt:
            \\            \\    sys.exit(0)
            \\        , .{ep});
            \\    } else try std.fmt.allocPrint(allocator,
            \\        \\import sys
            \\        \\import subprocess
            \\        \\try:
            \\        \\    sys.exit(subprocess.call([sys.executable, '-m', '{s}'] + sys.argv[1:]))
            \\        \\except KeyboardInterrupt:
            \\        \\    sys.exit(0)
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
            \\
            \\fn extractEntryPointFromJson(allocator: std.mem.Allocator, json_content: []const u8) ?[]u8 {
            \\    const needle = "\"entry_point\":";
            \\    const start_pos = std.mem.indexOf(u8, json_content, needle) orelse return null;
            \\    var pos = start_pos + needle.len;
            \\    while (pos < json_content.len and (json_content[pos] == ' ' or json_content[pos] == '\t' or json_content[pos] == '\n')) {
            \\        pos += 1;
            \\    }
            \\    if (pos >= json_content.len or json_content[pos] == 'n') return null; // null value
            \\    if (json_content[pos] != '"') return null;
            \\    pos += 1;
            \\    const value_start = pos;
            \\    while (pos < json_content.len and json_content[pos] != '"') {
            \\        pos += 1;
            \\    }
            \\    if (pos >= json_content.len) return null;
            \\    return allocator.dupe(u8, json_content[value_start..pos]) catch null;
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

        const output_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ std.fs.path.dirname(source_path).?, output_name });
        errdefer self.allocator.free(output_path); // Free on error

        // Build zig compile command for cross-compilation
        const target_string = switch (target) {
            .linux_x86_64 => "x86_64-linux",
            .linux_aarch64 => "aarch64-linux",
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
            output_name[0 .. output_name.len - if (std.mem.endsWith(u8, output_name, ".exe")) @as(usize, 4) else @as(usize, 0)],
        };

        const result = try bundlr.platform.process.run(self.allocator, &compile_args, std.fs.path.dirname(source_path).?);

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
            const escaped_ep = try std.mem.replaceOwned(u8, self.allocator, ep, "'", "'\"'\"'");
            defer self.allocator.free(escaped_ep);
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "\"$PYTHON_RUNTIME/bin/python\" -c '{s}' \"$@\"",
                .{escaped_ep},
            );
        } else blk: {
            const root = options.dependencies.root_package;
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
            \\    tar -xzf "$BUNDLE_DIR/python_runtime.tar.gz" -C "$BUNDLE_DIR"
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
        const metadata = .{
            .bundle_version = "1.0",
            .package_name = options.module_name orelse options.dependencies.root_package,
            .source_url = options.dependencies.source_url,
            .source_branch = options.metadata.git_branch orelse "main",
            .python_version = options.runtime_bundle.metadata.python_version,
            .target_platform = options.target.toString(),
            .build_timestamp = options.metadata.build_time,
            .bundlr_version = options.metadata.bundlr_version,
            .entry_point = options.entry_point,
        };

        std.debug.print("🔍 writing entry_point: {?s}\n", .{options.entry_point});

        const metadata_file = try std.fs.createFileAbsolute(metadata_path, .{});
        defer metadata_file.close();

        var buf: std.io.Writer.Allocating = .init(self.allocator);
        defer buf.deinit();
        try buf.writer.print("{f}", .{std.json.fmt(metadata, .{})});
        try metadata_file.writeAll(buf.written());
    }

    /// Create bundle metadata
    fn createBundleMetadata(self: *BundleGenerator, options: BundleOptions) !BundleMetadata {
        var packages = try self.allocator.alloc([]const u8, options.dependencies.packages.len);
        for (options.dependencies.packages, 0..) |pkg, i| {
            packages[i] = try self.allocator.dupe(u8, pkg.name);
        }

        return BundleMetadata{
            .bundle_version = try self.allocator.dupe(u8, "1.0"),
            .package_name = try self.allocator.dupe(u8, options.module_name orelse options.dependencies.root_package),
            .package_version = try self.allocator.dupe(u8, "1.0.0"),
            .python_version = try self.allocator.dupe(u8, options.runtime_bundle.metadata.python_version),
            .target_platform = try self.allocator.dupe(u8, options.target.toString()),
            .build_timestamp = options.metadata.build_time,
            .bundlr_version = try self.allocator.dupe(u8, options.metadata.bundlr_version),
            .entry_point = if (options.entry_point) |ep| try self.allocator.dupe(u8, ep) else null,
            .included_packages = packages,
            .compression = try self.allocator.dupe(u8, "gzip"),
        };
    }

    /// Assemble final executable from components
    fn assembleFinalExecutable(self: *BundleGenerator, stub_path: []const u8, components: BundleComponents, metadata: BundleMetadata, output_path: []const u8) ![]u8 {
        _ = metadata;

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

        const final_path = try self.allocator.dupe(u8, output_path);
        try self.copyFile(stub_path, final_path);
        try self.appendBundleToExecutable(final_path, bundle_archive);

        return final_path;
    }

    /// Append bundle data to executable
    fn appendBundleToExecutable(self: *BundleGenerator, executable_path: []const u8, bundle_path: []const u8) !void {
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
    fn calculateComponentSizes(self: *BundleGenerator, stub_path: []const u8, components: BundleComponents, final_executable: []const u8) !ComponentSizes {
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
        var paths = bundlr.platform.paths.Paths.init(self.allocator);
        const system_temp = try paths.getTemporaryDir();
        defer self.allocator.free(system_temp);

        var prng = std.Random.DefaultPrng.init(@as(u64, @intCast(std.time.nanoTimestamp())));
        const random_num = prng.random().int(u32);
        const temp_name = try std.fmt.allocPrint(self.allocator, "bundlr_bundle_{}_{}", .{ std.time.timestamp(), random_num });
        defer self.allocator.free(temp_name);

        const tmp_path = try std.fs.path.join(self.allocator, &[_][]const u8{ system_temp, temp_name });
        defer self.allocator.free(tmp_path);

        std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const retry_name = try std.fmt.allocPrint(self.allocator, "bundlr_bundle_{}_{}_{}", .{ std.time.timestamp(), random_num, prng.random().int(u16) });
                defer self.allocator.free(retry_name);
                const retry_path = try std.fs.path.join(self.allocator, &[_][]const u8{ system_temp, retry_name });
                try std.fs.makeDirAbsolute(retry_path);
                return retry_path;
            },
            else => return err,
        };

        return try std.fs.path.join(self.allocator, &[_][]const u8{ system_temp, temp_name });
    }

    fn cleanupTempDirectory(self: *BundleGenerator, temp_dir: []const u8) void {
        _ = self;
        std.fs.deleteTreeAbsolute(temp_dir) catch |err| {
            std.log.warn("Failed to cleanup temp directory {s}: {}", .{ temp_dir, err });
        };
    }

    fn ensureDirExists(self: *BundleGenerator, path: []const u8) !void {
        _ = self;
        std.fs.makeDirAbsolute(path) catch |err| switch (err) {
            error.PathAlreadyExists => return,
            else => return err,
        };
    }

    fn copyFile(self: *BundleGenerator, src: []const u8, dest: []const u8) !void {
        const cp_args = [_][]const u8{ "cp", "-r", src, dest };
        const result = try bundlr.platform.process.run(self.allocator, &cp_args, ".");
        if (result != 0) {
            return error.FileCopyFailed;
        }
    }

    fn getFileSize(self: *BundleGenerator, file_path: []const u8) !u64 {
        _ = self;
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
        return 10 * 1024 * 1024; // Placeholder: 10MB
    }
};

// Tests
test "bundle generator initialization" {
    const allocator = std.testing.allocator;
    var generator = BundleGenerator.init(allocator);
    defer generator.deinit();

    const stub_source = try generator.generateStubSource(.linux_x86_64);
    defer allocator.free(stub_source);

    // Stable hash directory pattern
    try std.testing.expect(std.mem.indexOf(u8, stub_source, "bundlr_app_") != null);
    // Persistence: no defer cleanup in main
    try std.testing.expect(std.mem.indexOf(u8, stub_source, "getOrCreateTempDirectory") != null);
    // Ready-marker guard
    try std.testing.expect(std.mem.indexOf(u8, stub_source, ".bundlr_ready") != null);
    // Mtime-based cleanup function present
    try std.testing.expect(std.mem.indexOf(u8, stub_source, "cleanupOldAppTempDirs") != null);
    // Correct Zig 0.15.2 Dir.stat() usage (no-arg form via sub_dir.stat())
    try std.testing.expect(std.mem.indexOf(u8, stub_source, "sub_dir.stat()") != null);
    // Ensure the invalid dir.stat(entry.name) pattern is absent
    try std.testing.expect(std.mem.indexOf(u8, stub_source, "dir.stat(entry.name)") == null);
}

test "component sizes calculation" {
    const allocator = std.testing.allocator;
    var generator = BundleGenerator.init(allocator);
    defer generator.deinit();

    const components = BundleGenerator.BundleComponents{
        .temp_dir = "/tmp/test",
        .bundle_dir = "/tmp/test/bundle",
        .runtime_path = "/tmp/test/runtime.tar.xz",
        .assets_dir = "/tmp/test/assets",
        .metadata_path = "/tmp/test/metadata.json",
        .launcher_path = "/tmp/test/launcher.sh",
    };

    const sizes = try generator.calculateComponentSizes("/tmp/stub", components, "/tmp/final");
    try std.testing.expect(sizes.total_size == 0); // Files don't exist, so size is 0
}
