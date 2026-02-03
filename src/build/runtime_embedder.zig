//! Python runtime embedding for portable executables
//! Creates optimised Python runtime bundles for different platforms

const std = @import("std");
const bundlr = @import("../bundlr.zig");
const pipeline = @import("pipeline.zig");

/// Python runtime configuration options
pub const RuntimeConfig = struct {
    /// Python version to embed
    python_version: []const u8,

    /// Target platform
    target_platform: pipeline.TargetPlatform,

    /// Optimization level
    optimize_level: pipeline.OptimizeLevel,

    /// Whether to include development tools (pip, etc.)
    include_dev_tools: bool = false,

    /// Modules to exclude from standard library
    excluded_modules: [][]const u8 = &[_][]const u8{},

    /// Custom Python configuration
    python_config: PythonEmbedConfig = .{},
};

/// Python embedding configuration
pub const PythonEmbedConfig = struct {
    /// Site packages directory name
    site_packages_dir: []const u8 = "site-packages",

    /// Whether to enable bytecode compilation
    compile_bytecode: bool = true,

    /// Compression level for embedded files
    compression_level: u8 = 6,

    /// Maximum memory usage for Python (0 = unlimited)
    max_memory_mb: u32 = 0,
};

/// Embedded Python runtime bundle
pub const RuntimeBundle = struct {
    /// Path to the runtime archive
    runtime_path: []const u8,

    /// Size of runtime bundle in bytes
    size_bytes: u64,

    /// Python executable path within bundle
    python_exe_path: []const u8,

    /// Site packages path within bundle
    site_packages_path: []const u8,

    /// Runtime metadata
    metadata: RuntimeMetadata,

    pub fn deinit(self: *RuntimeBundle, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_path);
        allocator.free(self.python_exe_path);
        allocator.free(self.site_packages_path);
        self.metadata.deinit(allocator);
    }
};

/// Metadata about the embedded runtime
pub const RuntimeMetadata = struct {
    /// Python version
    python_version: []const u8,

    /// Target platform
    target_platform: []const u8,

    /// List of included modules
    included_modules: [][]const u8,

    /// List of excluded modules
    excluded_modules: [][]const u8,

    /// Runtime creation timestamp
    created_at: i64,

    /// Original runtime size before optimisation
    original_size_bytes: u64,

    /// Final runtime size after optimisation
    optimised_size_bytes: u64,

    /// Compression ratio achieved
    compression_ratio: f32,

    pub fn deinit(self: *RuntimeMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.python_version);
        allocator.free(self.target_platform);
        for (self.included_modules) |module| {
            allocator.free(module);
        }
        allocator.free(self.included_modules);
        for (self.excluded_modules) |module| {
            allocator.free(module);
        }
        allocator.free(self.excluded_modules);
    }
};

/// Runtime embedder for creating portable Python bundles
pub const RuntimeEmbedder = struct {
    allocator: std.mem.Allocator,
    distribution_manager: bundlr.python.distribution.DistributionManager,

    pub fn init(allocator: std.mem.Allocator) RuntimeEmbedder {
        return RuntimeEmbedder{
            .allocator = allocator,
            .distribution_manager = bundlr.python.distribution.DistributionManager.init(allocator),
        };
    }

    pub fn deinit(_: *RuntimeEmbedder) void {
        // Clean up resources
    }

    /// Check if a cached runtime bundle exists and return it if valid
    fn getCachedRuntimeBundle(
        self: *RuntimeEmbedder,
        python_version: []const u8,
        target: pipeline.TargetPlatform,
        optimize_level: pipeline.OptimizeLevel
    ) !?RuntimeBundle {
        // Create cache key based on version, target, and optimisation level
        const cache_key = try std.fmt.allocPrint(
            self.allocator,
            "runtime_{s}_{s}_{s}.tar.gz",
            .{ python_version, target.toString(), @tagName(optimize_level) }
        );
        defer self.allocator.free(cache_key);

        const cache_path = try std.fmt.allocPrint(self.allocator, "/tmp/{s}", .{cache_key});
        defer self.allocator.free(cache_path);

        // Check if cached bundle exists and is readable
        const cache_file = std.fs.openFileAbsolute(cache_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null, // Cache miss
            else => return err,
        };
        defer cache_file.close();

        const cache_stat = try cache_file.stat();
        if (cache_stat.size == 0) return null; // Invalid cache

        std.debug.print("📦 Found cached runtime: {s} ({} MB)\n", .{ cache_path, cache_stat.size / (1024 * 1024) });

        // Return cached runtime bundle
        const cached_path = try self.allocator.dupe(u8, cache_path);
        return RuntimeBundle{
            .runtime_path = cached_path,
            .size_bytes = cache_stat.size,
            .python_exe_path = try self.getPythonExePath(target),
            .site_packages_path = try self.getSitePackagesPath(),
            .metadata = RuntimeMetadata{
                .python_version = try self.allocator.dupe(u8, python_version),
                .target_platform = try self.allocator.dupe(u8, target.toString()),
                .included_modules = &[_][]const u8{},
                .excluded_modules = &[_][]const u8{},
                .created_at = std.time.timestamp(),
                .original_size_bytes = cache_stat.size,
                .optimised_size_bytes = cache_stat.size,
                .compression_ratio = 0.0,
            },
        };
    }

    /// Create an optimised runtime bundle for the target platform
    pub fn createRuntimeBundle(
        self: *RuntimeEmbedder,
        python_version: []const u8,
        target: pipeline.TargetPlatform,
        optimize_level: pipeline.OptimizeLevel
    ) !RuntimeBundle {
        std.debug.print("🐍 Creating Python {s} runtime bundle for {s}...\n", .{ python_version, target.toString() });

        // Check if optimised runtime already exists in cache
        if (try self.getCachedRuntimeBundle(python_version, target, optimize_level)) |cached_bundle| {
            std.debug.print("✅ Using cached runtime bundle\n", .{});
            return cached_bundle;
        }

        const excluded_modules = try self.getExcludedModules(optimize_level);
        defer self.allocator.free(excluded_modules); // Free the array (strings are owned by metadata)

        const config = RuntimeConfig{
            .python_version = python_version,
            .target_platform = target,
            .optimize_level = optimize_level,
            .include_dev_tools = false, // Don't include dev tools in production bundles
            .excluded_modules = excluded_modules,
        };

        // Step 1: Ensure base Python distribution is available
        const base_runtime = try self.ensureBaseRuntime(config);
        defer self.allocator.free(base_runtime);

        // Step 2: Create working directory for bundle creation
        const work_dir = try self.createWorkingDirectory();
        defer self.allocator.free(work_dir);
        defer self.cleanupWorkingDirectory(work_dir);

        // Step 3: Extract and optimize the Python runtime
        const optimized_runtime = try self.optimizeRuntime(base_runtime, work_dir, config);
        defer self.allocator.free(optimized_runtime);

        // Step 4: Create compressed runtime archive
        const bundle_path = try self.createRuntimeArchive(optimized_runtime, config);

        // Step 5: Generate metadata
        const metadata = try self.createRuntimeMetadata(base_runtime, bundle_path, config);

        const bundle_size = try self.getFileSize(bundle_path);

        std.debug.print("✅ Runtime bundle created: {} MB (compression: {d:.1}%)\n", .{
            bundle_size / (1024 * 1024),
            metadata.compression_ratio,
        });

        return RuntimeBundle{
            .runtime_path = bundle_path,
            .size_bytes = bundle_size,
            .python_exe_path = try self.getPythonExePath(target),
            .site_packages_path = try self.getSitePackagesPath(),
            .metadata = metadata,
        };
    }

    /// Ensure base Python distribution is available
    fn ensureBaseRuntime(self: *RuntimeEmbedder, config: RuntimeConfig) ![]u8 {
        // Use existing distribution manager to get Python
        try self.distribution_manager.ensureDistribution(
            config.python_version,
            bundlr.platform.http.printProgress
        );

        const python_exe = try self.distribution_manager.getPythonExecutable(config.python_version);
        defer self.allocator.free(python_exe);

        // Get the base distribution directory
        const python_dir = std.fs.path.dirname(python_exe) orelse return error.InvalidPythonPath;
        const base_dir = std.fs.path.dirname(python_dir) orelse return error.InvalidPythonPath;

        return try self.allocator.dupe(u8, base_dir);
    }

    /// Create working directory for bundle operations
    fn createWorkingDirectory(self: *RuntimeEmbedder) ![]u8 {
        const temp_name = try std.fmt.allocPrint(self.allocator, "bundlr_runtime_{}", .{std.time.timestamp()});
        defer self.allocator.free(temp_name);

        // Create temp directory in /tmp
        const tmp_path = try std.fmt.allocPrint(self.allocator, "/tmp/{s}", .{temp_name});
        defer self.allocator.free(tmp_path);
        try std.fs.makeDirAbsolute(tmp_path);

        // Return the full path to the temp directory
        return try std.fmt.allocPrint(self.allocator, "/tmp/{s}", .{temp_name});
    }

    /// Clean up working directory
    fn cleanupWorkingDirectory(self: *RuntimeEmbedder, work_dir: []const u8) void {
        _ = self;
        std.fs.deleteTreeAbsolute(work_dir) catch |err| {
            std.log.warn("Failed to cleanup work directory {s}: {}", .{ work_dir, err });
        };
    }

    /// Optimize the Python runtime by removing unnecessary components
    fn optimizeRuntime(
        self: *RuntimeEmbedder,
        base_runtime: []const u8,
        work_dir: []const u8,
        config: RuntimeConfig
    ) ![]u8 {
        std.debug.print("  🔧 Optimizing runtime...\n", .{});

        // Create optimized runtime directory
        const optimized_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ work_dir, "optimized" });
        try std.fs.makeDirAbsolute(optimized_dir);

        // Copy base runtime to working directory
        try self.copyDirectory(base_runtime, optimized_dir);

        // Apply optimizations based on level
        switch (config.optimize_level) {
            .size => try self.optimizeForSize(optimized_dir, config),
            .speed => try self.optimizeForSpeed(optimized_dir, config),
            .compatibility => try self.optimizeForCompatibility(optimized_dir, config),
            .balanced => {
                try self.optimizeForSize(optimized_dir, config);
                try self.optimizeForSpeed(optimized_dir, config);
            },
        }

        return optimized_dir;
    }

    /// Apply size optimizations
    fn optimizeForSize(self: *RuntimeEmbedder, runtime_dir: []const u8, config: RuntimeConfig) !void {
        std.debug.print("    📦 Applying size optimizations...\n", .{});

        // Remove unnecessary files
        const cleanup_patterns = [_][]const u8{
            "*.pyc",        // Remove compiled bytecode (we'll recompile)
            "__pycache__",  // Remove cache directories
            "test",         // Remove test modules
            "tests",        // Remove test directories
            "*.exe",        // Remove Windows executables on non-Windows
            "*.pdb",        // Remove debug symbols
            "*.a",          // Remove static libraries
            "include",      // Remove header files
        };

        for (cleanup_patterns) |pattern| {
            self.removePatternFromDirectory(runtime_dir, pattern) catch |err| {
                std.log.warn("Failed to remove pattern {s}: {}", .{ pattern, err });
            };
        }

        // Remove excluded modules
        for (config.excluded_modules) |module| {
            self.removeModule(runtime_dir, module) catch |err| {
                std.log.warn("Failed to remove module {s}: {}", .{ module, err });
            };
        }

        // Compile Python files to bytecode
        try self.compilePythonFiles(runtime_dir);
    }

    /// Apply speed optimizations
    fn optimizeForSpeed(self: *RuntimeEmbedder, runtime_dir: []const u8, config: RuntimeConfig) !void {
        _ = config;
        std.debug.print("    ⚡ Applying speed optimizations...\n", .{});

        // Precompile all Python files with optimization
        try self.precompilePythonFiles(runtime_dir);

        // Create import cache
        try self.createImportCache(runtime_dir);
    }

    /// Apply compatibility optimizations
    fn optimizeForCompatibility(_: *RuntimeEmbedder, runtime_dir: []const u8, config: RuntimeConfig) !void {
        _ = runtime_dir;
        _ = config;
        std.debug.print("    🔧 Applying compatibility optimizations...\n", .{});

        // Keep all modules for maximum compatibility
        // Just ensure proper file permissions and structure
    }

    /// Create compressed runtime archive
    fn createRuntimeArchive(
        self: *RuntimeEmbedder,
        runtime_dir: []const u8,
        config: RuntimeConfig
    ) ![]u8 {
        std.debug.print("  📦 Creating runtime archive...\n", .{});

        // Create archive in /tmp directory with predictable cache name
        const archive_name = try std.fmt.allocPrint(
            self.allocator,
            "runtime_{s}_{s}_{s}.tar.gz",
            .{ config.python_version, config.target_platform.toString(), @tagName(config.optimize_level) }
        );
        defer self.allocator.free(archive_name);

        const archive_path = try std.fmt.allocPrint(
            self.allocator,
            "/tmp/{s}",
            .{archive_name}
        );

        std.debug.print("  🔧 Creating archive: {s}\n", .{archive_path});
        std.debug.print("  📂 Source directory: {s}\n", .{runtime_dir});

        // Use platform-specific archive creation
        try self.createArchiveWithSystemTools(runtime_dir, archive_path);

        // Verify the file was created
        const file = std.fs.openFileAbsolute(archive_path, .{}) catch |err| {
            std.debug.print("  ❌ Archive file was not created: {s} (error: {})\n", .{ archive_path, err });
            return error.ArchiveCreationFailed;
        };
        file.close();

        std.debug.print("  ✅ Archive verified: {s}\n", .{archive_path});
        return archive_path;
    }

    /// Create archive using platform-appropriate tools
    fn createArchiveWithSystemTools(
        self: *RuntimeEmbedder,
        source_dir: []const u8,
        archive_path: []const u8
    ) !void {
        const builtin = @import("builtin");

        switch (builtin.os.tag) {
            .windows => {
                // On Windows, use PowerShell Compress-Archive (creates .zip, not .tar.gz)
                // For compatibility, we'll create a .zip file instead when tar is unavailable
                const zip_path = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}.zip",
                    .{archive_path[0..archive_path.len - 7]} // Remove .tar.gz extension
                );
                defer self.allocator.free(zip_path);

                const command = try std.fmt.allocPrint(
                    self.allocator,
                    "& {{Compress-Archive -LiteralPath '{s}' -DestinationPath '{s}' -CompressionLevel Fastest -Force}}",
                    .{ source_dir, zip_path },
                );
                defer self.allocator.free(command);

                const args = [_][]const u8{
                    "powershell",
                    "-NoProfile",
                    "-ExecutionPolicy", "Bypass",
                    "-Command",
                    command,
                };

                std.debug.print("  💻 Using PowerShell to create archive on Windows...\n", .{});
                const result = try bundlr.platform.process.run(
                    self.allocator,
                    &args,
                    "."
                );

                if (result != 0) {
                    // Fallback: try using tar on Windows 10+ (if available)
                    std.debug.print("  ⚠️  PowerShell failed, trying system tar...\n", .{});
                    try self.createArchiveWithTar(source_dir, archive_path);
                } else {
                    // Copy the zip file to the expected tar.gz location for consistency
                    try self.copyFile(zip_path, archive_path);
                    std.fs.deleteFileAbsolute(zip_path) catch {};
                }
            },
            else => {
                // Unix-like systems: use tar
                try self.createArchiveWithTar(source_dir, archive_path);
            },
        }
    }

    /// Create archive using tar command (Unix/Linux/macOS or Windows 10+)
    fn createArchiveWithTar(
        self: *RuntimeEmbedder,
        source_dir: []const u8,
        archive_path: []const u8
    ) !void {
        const tar_args = [_][]const u8{
            "tar",
            "-C",
            std.fs.path.dirname(source_dir).?,
            "-czf",
            archive_path,
            std.fs.path.basename(source_dir),
        };

        std.debug.print("  💻 Running tar command...\n", .{});
        const result = bundlr.platform.process.run(
            self.allocator,
            &tar_args,
            "."
        ) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("  ❌ tar executable not found\n", .{});
                return error.TarNotAvailable;
            }
            return err;
        };

        if (result != 0) {
            std.debug.print("  ❌ tar command failed with exit code: {}\n", .{result});
            return error.ArchiveCreationFailed;
        }
    }

    /// Copy file (simple implementation for fallback)
    fn copyFile(self: *RuntimeEmbedder, src_path: []const u8, dest_path: []const u8) !void {
        _ = self;
        const src_file = try std.fs.openFileAbsolute(src_path, .{});
        defer src_file.close();

        const dest_file = try std.fs.createFileAbsolute(dest_path, .{});
        defer dest_file.close();

        const buffer_size = 64 * 1024; // 64KB buffer
        var buffer: [buffer_size]u8 = undefined;

        while (true) {
            const bytes_read = try src_file.read(&buffer);
            if (bytes_read == 0) break;
            try dest_file.writeAll(buffer[0..bytes_read]);
        }
    }

    /// Generate runtime metadata
    fn createRuntimeMetadata(
        self: *RuntimeEmbedder,
        original_runtime: []const u8,
        bundle_path: []const u8,
        config: RuntimeConfig
    ) !RuntimeMetadata {
        const original_size = try self.getDirectorySize(original_runtime);
        const optimized_size = try self.getFileSize(bundle_path);

        const compression_ratio = if (original_size > 0)
            (1.0 - (@as(f32, @floatFromInt(optimized_size)) / @as(f32, @floatFromInt(original_size)))) * 100.0
        else 0.0;

        // Get included modules list
        const included_modules = try self.getIncludedModules(config);
        const excluded_modules = try self.allocator.dupe([]const u8, config.excluded_modules);

        return RuntimeMetadata{
            .python_version = try self.allocator.dupe(u8, config.python_version),
            .target_platform = try self.allocator.dupe(u8, config.target_platform.toString()),
            .included_modules = included_modules,
            .excluded_modules = excluded_modules,
            .created_at = std.time.timestamp(),
            .original_size_bytes = original_size,
            .optimised_size_bytes = optimized_size,
            .compression_ratio = compression_ratio,
        };
    }

    /// Get list of modules to exclude based on optimization level
    fn getExcludedModules(self: *RuntimeEmbedder, optimize_level: pipeline.OptimizeLevel) ![][]const u8 {
        // Common exclusions for all optimization levels
        const common_exclusions = [_][]const u8{
            "tkinter",      // GUI framework (rarely needed in CLI apps)
            "turtle",       // Graphics library
            "idlelib",      // IDLE development environment
            "lib2to3",      // Python 2to3 tool
            "test",         // Test suite
            "tests",        // Additional tests
        };

        // Additional exclusions for size optimization
        const size_exclusions = [_][]const u8{
            "pydoc",        // Documentation tool
            "doctest",      // Testing framework
            "unittest",     // Unit testing
            "distutils",    // Distribution utilities
            "email",        // Email handling (if not needed)
        };

        // Determine total count
        const total_count = common_exclusions.len + (if (optimize_level == .size) size_exclusions.len else 0);

        // Allocate result array
        var result = try self.allocator.alloc([]const u8, total_count);
        var index: usize = 0;

        // Add common exclusions
        for (common_exclusions) |module| {
            result[index] = try self.allocator.dupe(u8, module);
            index += 1;
        }

        // Add size exclusions if needed
        if (optimize_level == .size) {
            for (size_exclusions) |module| {
                result[index] = try self.allocator.dupe(u8, module);
                index += 1;
            }
        }

        return result;
    }

    /// Copy directory recursively
    fn copyDirectory(self: *RuntimeEmbedder, src: []const u8, dest: []const u8) !void {
        const cp_args = [_][]const u8{ "cp", "-r", src, dest };
        const result = try bundlr.platform.process.run(
            self.allocator,
            &cp_args,
            "."
        );

        if (result != 0) {
            return error.DirectoryCopyFailed;
        }
    }

    /// Remove files matching pattern from directory
    fn removePatternFromDirectory(self: *RuntimeEmbedder, dir: []const u8, pattern: []const u8) !void {
        _ = self;
        _ = dir;
        _ = pattern;
        // TODO: Implement pattern-based file removal
        // For now, skip this functionality
    }

    /// Remove specific module from runtime
    fn removeModule(self: *RuntimeEmbedder, runtime_dir: []const u8, module: []const u8) !void {
        _ = self;
        _ = runtime_dir;
        _ = module;
        // TODO: Implement module removal
    }

    /// Compile Python files to bytecode
    fn compilePythonFiles(self: *RuntimeEmbedder, runtime_dir: []const u8) !void {
        _ = self;
        _ = runtime_dir;
        // TODO: Implement Python compilation
    }

    /// Precompile Python files with optimization
    fn precompilePythonFiles(self: *RuntimeEmbedder, runtime_dir: []const u8) !void {
        _ = self;
        _ = runtime_dir;
        // TODO: Implement optimized compilation
    }

    /// Create import cache for faster startup
    fn createImportCache(self: *RuntimeEmbedder, runtime_dir: []const u8) !void {
        _ = self;
        _ = runtime_dir;
        // TODO: Implement import cache creation
    }

    /// Get Python executable path for target platform
    fn getPythonExePath(self: *RuntimeEmbedder, target: pipeline.TargetPlatform) ![]u8 {
        const exe_name = switch (target) {
            .windows_x86_64, .windows_aarch64 => "python.exe",
            else => "python",
        };

        return try std.fmt.allocPrint(self.allocator, "bin/{s}", .{exe_name});
    }

    /// Get site packages path
    fn getSitePackagesPath(self: *RuntimeEmbedder) ![]u8 {
        return try self.allocator.dupe(u8, "lib/python3.14/site-packages");
    }

    /// Get list of included modules
    fn getIncludedModules(self: *RuntimeEmbedder, config: RuntimeConfig) ![][]const u8 {
        _ = config;
        // TODO: Implement module discovery
        // For now, return standard library modules
        const modules = [_][]const u8{ "os", "sys", "json", "urllib", "http" };

        const result = try self.allocator.alloc([]const u8, modules.len);
        for (modules, 0..) |module, i| {
            result[i] = try self.allocator.dupe(u8, module);
        }

        return result;
    }

    /// Get directory size in bytes
    fn getDirectorySize(self: *RuntimeEmbedder, dir_path: []const u8) !u64 {
        _ = self;
        _ = dir_path;
        // TODO: Implement directory size calculation
        return 50 * 1024 * 1024; // Placeholder: 50MB
    }

    /// Get file size in bytes
    fn getFileSize(self: *RuntimeEmbedder, file_path: []const u8) !u64 {
        _ = self;
        const file = std.fs.openFileAbsolute(file_path, .{}) catch return 0;
        defer file.close();
        const stat = try file.stat();
        return stat.size;
    }
};

// Tests
test "runtime embedder initialization" {
    const allocator = std.testing.allocator;
    var embedder = RuntimeEmbedder.init(allocator);
    defer embedder.deinit();

    const excluded_modules = try embedder.getExcludedModules(.size);
    defer {
        for (excluded_modules) |module| allocator.free(module);
        allocator.free(excluded_modules);
    }

    try std.testing.expect(excluded_modules.len > 0);
}

test "python exe path generation" {
    const allocator = std.testing.allocator;
    var embedder = RuntimeEmbedder.init(allocator);
    defer embedder.deinit();

    const windows_path = try embedder.getPythonExePath(.windows_x86_64);
    defer allocator.free(windows_path);
    try std.testing.expectEqualStrings("bin/python.exe", windows_path);

    const linux_path = try embedder.getPythonExePath(.linux_x86_64);
    defer allocator.free(linux_path);
    try std.testing.expectEqualStrings("bin/python", linux_path);
}