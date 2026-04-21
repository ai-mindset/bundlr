//! Build pipeline orchestration for bundlr
//! Coordinates the creation of portable executables from Python packages

const std = @import("std");
const bundlr = @import("../bundlr.zig");

/// Target platform specification for cross-platform builds
pub const TargetPlatform = enum {
    linux_x86_64,
    linux_aarch64,
    windows_x86_64,
    windows_aarch64,
    macos_x86_64,
    macos_aarch64,
    all,

    pub fn toString(self: TargetPlatform) []const u8 {
        return switch (self) {
            .linux_x86_64 => "linux-x86_64",
            .linux_aarch64 => "linux-aarch64",
            .windows_x86_64 => "windows-x86_64",
            .windows_aarch64 => "windows-aarch64",
            .macos_x86_64 => "macos-x86_64",
            .macos_aarch64 => "macos-aarch64",
            .all => "all",
        };
    }

    pub fn fromString(str: []const u8) !TargetPlatform {
        if (std.mem.eql(u8, str, "linux-x86_64")) return .linux_x86_64;
        if (std.mem.eql(u8, str, "linux-aarch64")) return .linux_aarch64;
        if (std.mem.eql(u8, str, "windows-x86_64")) return .windows_x86_64;
        if (std.mem.eql(u8, str, "windows-aarch64")) return .windows_aarch64;
        if (std.mem.eql(u8, str, "macos-x86_64")) return .macos_x86_64;
        if (std.mem.eql(u8, str, "macos-aarch64")) return .macos_aarch64;
        if (std.mem.eql(u8, str, "all")) return .all;
        return error.UnknownTargetPlatform;
    }

    pub fn getTargetList(self: TargetPlatform, allocator: std.mem.Allocator) ![]TargetPlatform {
        if (self == .all) {
            return try allocator.dupe(TargetPlatform, &[_]TargetPlatform{
                .linux_x86_64,
                .linux_aarch64,
                .windows_x86_64,
                .windows_aarch64,
                .macos_x86_64,
                .macos_aarch64,
            });
        } else {
            return try allocator.dupe(TargetPlatform, &[_]TargetPlatform{self});
        }
    }

    pub fn getFileExtension(self: TargetPlatform) []const u8 {
        return switch (self) {
            .windows_x86_64, .windows_aarch64 => ".exe",
            else => "",
        };
    }
};

/// Build configuration for portable executable generation
pub const BuildOptions = struct {
    /// Package name or Git repository URL
    package: []const u8,

    /// Target platform(s) to build for
    target: TargetPlatform = .linux_x86_64,

    /// Output file path (optional, auto-generated if not provided)
    output_path: ?[]const u8 = null,

    /// Output directory for multiple targets
    output_dir: ?[]const u8 = null,

    /// Python version to embed
    python_version: []const u8 = "3.14",

    /// Optimization level
    optimize_level: OptimizeLevel = .balanced,

    /// Whether to exclude development dependencies
    exclude_dev_deps: bool = false,

    /// Custom entry point (optional)
    entry_point: ?[]const u8 = null,

    /// Build metadata
    build_metadata: BuildMetadata = .{},
};

/// Optimization levels for build process
pub const OptimizeLevel = enum {
    size, // --optimize-size: Minimize executable size
    speed, // --optimize-speed: Maximize runtime performance
    compatibility, // --optimize-compatibility: Maximum compatibility
    balanced, // Default: Balance between size and performance
};

/// Build metadata to include in the bundle
pub const BuildMetadata = struct {
    /// Build timestamp
    build_time: i64 = 0,

    /// Bundlr version used for building
    bundlr_version: []const u8 = "1.0.3",

    /// Python version used
    python_version: []const u8 = "3.14",

    /// Target platform
    target_platform: ?[]const u8 = null,

    // Git branch
    git_branch: ?[]const u8 = null,
};

/// Build pipeline result
pub const BuildResult = struct {
    /// Path to generated executable
    executable_path: []const u8,

    /// Target platform
    target: TargetPlatform,

    /// Executable size in bytes
    size_bytes: u64,

    /// Build metadata
    metadata: BuildMetadata,

    /// Build duration in milliseconds
    build_duration_ms: u64,

    pub fn deinit(self: *BuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.executable_path);
        // Note: target_platform is set to toString() which returns string literals
        // so we don't need to free it
    }
};

/// Main build pipeline coordinator
pub const BuildPipeline = struct {
    allocator: std.mem.Allocator,
    options: BuildOptions,

    pub fn init(allocator: std.mem.Allocator, options: BuildOptions) BuildPipeline {
        return BuildPipeline{
            .allocator = allocator,
            .options = options,
        };
    }

    /// Execute the complete build pipeline
    pub fn execute(self: *BuildPipeline) ![]BuildResult {
        const start_time = std.time.milliTimestamp();

        std.debug.print("🔨 Bundlr Build Pipeline Starting\n", .{});
        std.debug.print("📦 Package: {s}\n", .{self.options.package});
        std.debug.print("🎯 Target: {s}\n", .{self.options.target.toString()});

        // Get list of target platforms
        const targets = try self.options.target.getTargetList(self.allocator);
        defer self.allocator.free(targets);

        var results = try self.allocator.alloc(BuildResult, targets.len);

        // Build for each target platform
        for (targets, 0..) |target, i| {
            std.debug.print("\n🏗️  Building for {s}...\n", .{target.toString()});

            const target_start_time = std.time.milliTimestamp();

            // Step 1: Resolve dependencies
            std.debug.print("📋 Resolving dependencies...\n", .{});
            const dependency_resolver = @import("dependency_resolver.zig");
            var resolver = dependency_resolver.DependencyResolver.init(self.allocator);
            defer resolver.deinit();

            // Step 1.5: Discover real Python module name for git packages
            const module_name = self.discoverModuleName() catch |err| blk: {
                std.debug.print("⚠️  Module discovery failed ({}), using default\n", .{err});
                break :blk null;
            };
            defer if (module_name) |name| self.allocator.free(name);

            const dependencies = resolver.resolveDependencies(self.options.package, target, self.options.python_version, self.options.exclude_dev_deps) catch |err| {
                std.debug.print("❌ Failed to resolve dependencies: {}\n", .{err});
                // Create failed result
                results[i] = BuildResult{
                    .executable_path = try std.fmt.allocPrint(self.allocator, "{s}-{s}-FAILED", .{ self.options.package, target.toString() }),
                    .target = target,
                    .size_bytes = 0,
                    .metadata = self.createBuildMetadata(target),
                    .build_duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - target_start_time)),
                };
                continue;
            };
            defer _ = dependencies.deinit(self.allocator);

            std.debug.print("✅ Resolved {} dependencies\n", .{dependencies.packages.len});

            // Step 2: Collect assets (wheels, packages)
            std.debug.print("📥 Collecting assets for {s}...\n", .{target.toString()});
            const asset_collector = @import("asset_collector.zig");
            var collector = try asset_collector.AssetCollector.init(self.allocator);
            defer collector.deinit();

            var assets = collector.collectAssets(dependencies.packages, target) catch |err| {
                std.debug.print("❌ Failed to collect assets: {}\n", .{err});
                results[i] = BuildResult{
                    .executable_path = try std.fmt.allocPrint(self.allocator, "{s}-{s}-FAILED", .{ self.options.package, target.toString() }),
                    .target = target,
                    .size_bytes = 0,
                    .metadata = self.createBuildMetadata(target),
                    .build_duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - target_start_time)),
                };
                continue;
            };
            defer assets.deinit(self.allocator);

            std.debug.print("✅ Collected {} assets ({} MB)\n", .{ assets.assets.len, assets.total_size / (1024 * 1024) });

            // Step 3: Embed Python runtime
            std.debug.print("🐍 Preparing Python runtime for {s}...\n", .{target.toString()});
            const runtime_embedder = @import("runtime_embedder.zig");
            var embedder = runtime_embedder.RuntimeEmbedder.init(self.allocator);
            defer embedder.deinit();

            var runtime_bundle = embedder.createRuntimeBundle(self.options.python_version, target, self.options.optimize_level) catch |err| {
                std.debug.print("❌ Failed to prepare runtime: {}\n", .{err});
                results[i] = BuildResult{
                    .executable_path = try std.fmt.allocPrint(self.allocator, "{s}-{s}-FAILED", .{ self.options.package, target.toString() }),
                    .target = target,
                    .size_bytes = 0,
                    .metadata = self.createBuildMetadata(target),
                    .build_duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - target_start_time)),
                };
                continue;
            };
            defer runtime_bundle.deinit(self.allocator);

            std.debug.print("✅ Runtime prepared ({} MB)\n", .{runtime_bundle.size_bytes / (1024 * 1024)});

            // Step 4: Generate self-extracting bundle
            std.debug.print("📦 Generating portable executable...\n", .{});
            const bundle_generator = @import("bundle_generator.zig");
            var generator = bundle_generator.BundleGenerator.init(self.allocator);
            defer generator.deinit();

            const output_path = try self.determineOutputPath(target);

            const bundle_options = bundle_generator.BundleOptions{
                .output_path = output_path,
                .target = target,
                .runtime_bundle = runtime_bundle,
                .assets = assets,
                .dependencies = dependencies,
                .entry_point = self.options.entry_point,
                .module_name = module_name,
                .metadata = self.createBuildMetadata(target),
            };

            var bundle_info = generator.generateBundle(bundle_options) catch |err| {
                std.debug.print("❌ Failed to generate bundle: {}\n", .{err});
                results[i] = BuildResult{
                    .executable_path = output_path,
                    .target = target,
                    .size_bytes = 0,
                    .metadata = self.createBuildMetadata(target),
                    .build_duration_ms = @as(u64, @intCast(std.time.milliTimestamp() - target_start_time)),
                };
                continue;
            };
            defer bundle_info.deinit(self.allocator);

            const build_duration = @as(u64, @intCast(std.time.milliTimestamp() - target_start_time));

            results[i] = BuildResult{
                .executable_path = output_path,
                .target = target,
                .size_bytes = bundle_info.total_size,
                .metadata = self.createBuildMetadata(target),
                .build_duration_ms = build_duration,
            };

            std.debug.print("✅ Built {s} ({} dependencies resolved)\n", .{ output_path, dependencies.packages.len });
        }

        const total_duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        std.debug.print("\n🎉 Build pipeline completed in {}ms\n", .{total_duration});

        return results;
    }

    /// Determine output path for target platform
    fn determineOutputPath(self: *BuildPipeline, target: TargetPlatform) ![]u8 {
        if (self.options.output_path) |output_path| {
            // Single file output
            return try self.allocator.dupe(u8, output_path);
        } else if (self.options.output_dir) |output_dir| {
            // Multiple files in directory
            const filename = try std.fmt.allocPrint(self.allocator, "{s}-{s}{s}", .{
                self.getPackageName(),
                target.toString(),
                target.getFileExtension(),
            });
            defer self.allocator.free(filename);

            return try std.fs.path.join(self.allocator, &[_][]const u8{ output_dir, filename });
        } else {
            // Auto-generated filename in current directory
            return try std.fmt.allocPrint(self.allocator, "{s}-{s}{s}", .{
                self.getPackageName(),
                target.toString(),
                target.getFileExtension(),
            });
        }
    }

    /// Extract package name from package specification
    fn getPackageName(self: *BuildPipeline) []const u8 {
        // If it's a URL, extract the repository name
        if (std.mem.indexOf(u8, self.options.package, "://")) |_| {
            if (std.mem.lastIndexOf(u8, self.options.package, "/")) |last_slash| {
                var name = self.options.package[last_slash + 1 ..];
                if (std.mem.endsWith(u8, name, ".git")) {
                    name = name[0 .. name.len - 4];
                }
                return name;
            }
        }
        return self.options.package;
    }

    /// Create build metadata for target
    fn createBuildMetadata(self: *BuildPipeline, target: TargetPlatform) BuildMetadata {
        return BuildMetadata{
            .build_time = std.time.timestamp(),
            .bundlr_version = "1.0.3",
            .python_version = self.options.python_version,
            .target_platform = target.toString(),
        };
    }

    /// Get file size in bytes
    fn getFileSize(self: *BuildPipeline, path: []const u8) !u64 {
        _ = self;
        const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
        defer file.close();
        const stat = try file.stat();
        return stat.size;
    }

    /// For git packages, discover the actual Python module name by scanning
    /// the repository for directories containing __main__.py.
    /// Returns null for PyPI packages or if no __main__.py is found.
    fn discoverModuleName(self: *BuildPipeline) !?[]const u8 {
        // Only applies to git URLs
        if (std.mem.indexOf(u8, self.options.package, "://") == null) return null;

        std.debug.print("🔍 Discovering Python module name...\n", .{});

        // Download and extract the repository
        var git_manager = bundlr.git.archive.GitArchiveManager.init(self.allocator);
        const extract_dir = try git_manager.downloadRepository(
            self.options.package,
            null,
            null,
            null,
            null,
        );
        defer self.allocator.free(extract_dir);

        // GitHub archives extract to a subdirectory like "repo-branch/"
        const repo_dir = try self.findRepoRoot(extract_dir);
        defer if (repo_dir) |d| self.allocator.free(d);

        const search_base = repo_dir orelse extract_dir;

        // Try src layout first (PEP 621), then flat layout
        if (try self.scanForMainModule(search_base, "src")) |name| {
            std.debug.print("✅ Discovered module: {s} (src layout)\n", .{name});
            return name;
        }
        if (try self.scanForMainModule(search_base, null)) |name| {
            std.debug.print("✅ Discovered module: {s} (flat layout)\n", .{name});
            return name;
        }

        std.debug.print("⚠️  No __main__.py found, using URL-derived name\n", .{});
        return null;
    }

    /// Find the first subdirectory inside an extracted GitHub archive
    fn findRepoRoot(self: *BuildPipeline, extract_dir: []const u8) !?[]const u8 {
        var dir = std.fs.openDirAbsolute(extract_dir, .{ .iterate = true }) catch return null;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory and entry.name[0] != '.') {
                return try std.fs.path.join(self.allocator, &.{ extract_dir, entry.name });
            }
        }
        return null;
    }

    /// Scan a directory's immediate children for subdirs containing __main__.py
    fn scanForMainModule(self: *BuildPipeline, base_dir: []const u8, sub_dir: ?[]const u8) !?[]const u8 {
        const search_path = if (sub_dir) |sd|
            try std.fs.path.join(self.allocator, &.{ base_dir, sd })
        else
            try self.allocator.dupe(u8, base_dir);
        defer self.allocator.free(search_path);

        var dir = std.fs.openDirAbsolute(search_path, .{ .iterate = true }) catch return null;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name[0] == '.' or std.mem.eql(u8, entry.name, "__pycache__")) continue;

            const main_path = try std.fs.path.join(self.allocator, &.{ search_path, entry.name, "__main__.py" });
            defer self.allocator.free(main_path);

            std.fs.accessAbsolute(main_path, .{}) catch continue;
            return try self.allocator.dupe(u8, entry.name);
        }
        return null;
    }
};

/// Parse build options from command line arguments
pub fn parseBuildOptions(allocator: std.mem.Allocator, args: []const []const u8) !BuildOptions {
    var options = BuildOptions{
        .package = "",
    };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--target") and i + 1 < args.len) {
            i += 1;
            options.target = try TargetPlatform.fromString(args[i]);
        } else if (std.mem.eql(u8, arg, "--output") and i + 1 < args.len) {
            i += 1;
            options.output_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--output-dir") and i + 1 < args.len) {
            i += 1;
            options.output_dir = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--python-version") and i + 1 < args.len) {
            i += 1;
            options.python_version = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--optimise-size")) {
            options.optimize_level = .size;
        } else if (std.mem.eql(u8, arg, "--optimise-speed")) {
            options.optimize_level = .speed;
        } else if (std.mem.eql(u8, arg, "--optimise-compatibility")) {
            options.optimize_level = .compatibility;
        } else if (std.mem.eql(u8, arg, "--exclude-dev-deps")) {
            options.exclude_dev_deps = true;
        } else if (std.mem.eql(u8, arg, "--entry-point") and i + 1 < args.len) {
            i += 1;
            options.entry_point = try allocator.dupe(u8, args[i]);
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            // First non-flag argument is the package
            if (options.package.len == 0) {
                options.package = try allocator.dupe(u8, arg);
            }
        }
    }

    if (options.package.len == 0) {
        return error.MissingPackageArgument;
    }

    return options;
}

// Tests
test "target platform parsing" {
    const target = try TargetPlatform.fromString("linux-x86_64");
    try std.testing.expect(target == .linux_x86_64);
    try std.testing.expectEqualStrings("linux-x86_64", target.toString());
}

test "build options parsing" {
    const allocator = std.testing.allocator;

    const args = [_][]const u8{
        "cowsay",
        "--target",
        "windows-x86_64",
        "--output",
        "cowsay.exe",
        "--optimise-size",
    };

    const options = try parseBuildOptions(allocator, &args);
    defer if (options.output_path) |path| allocator.free(path);
    defer allocator.free(options.package);

    try std.testing.expectEqualStrings("cowsay", options.package);
    try std.testing.expect(options.target == .windows_x86_64);
    try std.testing.expectEqualStrings("cowsay.exe", options.output_path.?);
    try std.testing.expect(options.optimize_level == .size);
}
