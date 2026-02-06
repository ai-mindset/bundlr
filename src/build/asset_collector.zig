//! Asset collection for build-time bundling
//! Downloads and manages platform-specific wheels and assets

const std = @import("std");
const bundlr = @import("../bundlr.zig");
const pipeline = @import("pipeline.zig");
const dependency_resolver = @import("dependency_resolver.zig");

/// Asset type classification
pub const AssetType = enum {
    wheel,           // Python wheel file
    source_dist,     // Source distribution
    compiled_ext,    // Compiled extension
    data_file,       // Data/resource file
};

/// Individual asset information
pub const Asset = struct {
    /// Asset type
    type: AssetType,

    /// File path (local or URL)
    path: []const u8,

    /// Local cached path after download
    local_path: ?[]const u8 = null,

    /// Size in bytes
    size: u64 = 0,

    /// SHA256 hash for verification
    hash: ?[]const u8 = null,

    /// Associated package name
    package_name: []const u8,

    /// Package version
    package_version: []const u8,

    /// Platform compatibility tags
    platform_tags: [][]const u8 = &[_][]const u8{},

    pub fn deinit(self: *Asset, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.local_path) |local| allocator.free(local);
        if (self.hash) |hash| allocator.free(hash);
        allocator.free(self.package_name);
        allocator.free(self.package_version);
        for (self.platform_tags) |tag| {
            allocator.free(tag);
        }
        allocator.free(self.platform_tags);
    }
};

/// Collection of all assets for a build
pub const AssetBundle = struct {
    /// List of all assets
    assets: []Asset,

    /// Total size of all assets
    total_size: u64,

    /// Target platform
    target_platform: pipeline.TargetPlatform,

    /// Collection metadata
    metadata: CollectionMetadata,

    pub fn deinit(self: *AssetBundle, allocator: std.mem.Allocator) void {
        for (self.assets) |*asset| {
            asset.deinit(allocator);
        }
        allocator.free(self.assets);
        self.metadata.deinit(allocator);
    }
};

/// Metadata about the asset collection process
pub const CollectionMetadata = struct {
    /// Number of assets collected
    asset_count: u32,

    /// Number of packages processed
    package_count: u32,

    /// Collection timestamp
    collected_at: i64,

    /// Cache hit rate (percentage)
    cache_hit_rate: f32,

    /// Download duration in milliseconds
    download_duration_ms: u64,

    pub fn deinit(self: *CollectionMetadata, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
    }
};

/// Asset collector for downloading and managing build assets
pub const AssetCollector = struct {
    allocator: std.mem.Allocator,
    cache_manager: bundlr.utils.cache.Cache,
    http_client: bundlr.platform.http.Client,

    pub fn init(allocator: std.mem.Allocator) !AssetCollector {
        return AssetCollector{
            .allocator = allocator,
            .cache_manager = try bundlr.utils.cache.Cache.init(allocator),
            .http_client = bundlr.platform.http.Client.init(allocator, bundlr.platform.http.Config{}),
        };
    }

    pub fn deinit(self: *AssetCollector) void {
        self.cache_manager.deinit();
        // http_client doesn't need cleanup
    }

    /// Collect all assets for the given packages and target platform
    pub fn collectAssets(
        self: *AssetCollector,
        packages: []dependency_resolver.PackageInfo,
        target: pipeline.TargetPlatform
    ) !AssetBundle {
        const start_time = std.time.milliTimestamp();

        std.debug.print("📥 Collecting assets for {} packages...\n", .{packages.len});

        // Simplified approach - allocate assets array directly
        var assets = try self.allocator.alloc(Asset, packages.len);
        var total_size: u64 = 0;
        var cache_hits: u32 = 0;

        var assets_filled: usize = 0;
        errdefer {
            // Clean up any partially filled assets on error
            for (0..assets_filled) |j| {
                assets[j].deinit(self.allocator);
            }
            self.allocator.free(assets);
        }

        for (packages, 0..) |package, i| {
            std.debug.print("  📦 Processing {s} v{s}...\n", .{ package.name, package.version });

            // Find compatible wheel for target platform
            var asset = self.findBestAsset(package, target) catch |err| blk: {
                std.log.warn("Failed to find asset for {s}: {}", .{ package.name, err });

                // Fallback to source distribution
                break :blk self.createSourceDistAsset(package) catch |fallback_err| {
                    std.log.err("Failed to create fallback asset for {s}: {}", .{ package.name, fallback_err });
                    return error.AssetCreationFailed;
                };
            };
            errdefer asset.deinit(self.allocator); // Clean up this asset if subsequent operations fail

            // Download or verify cached asset
            const downloaded_asset = self.ensureAssetAvailable(asset, &cache_hits) catch |err| {
                std.log.err("Failed to download asset for {s}: {}", .{ package.name, err });
                return error.AssetDownloadFailed;
            };

            total_size += downloaded_asset.size;
            assets[i] = downloaded_asset;
            assets_filled += 1;
        }

        const duration = @as(u64, @intCast(std.time.milliTimestamp() - start_time));
        const cache_hit_rate = if (packages.len > 0)
            (@as(f32, @floatFromInt(cache_hits)) / @as(f32, @floatFromInt(packages.len))) * 100.0
        else 0.0;

        const metadata = CollectionMetadata{
            .asset_count = @intCast(assets.len),
            .package_count = @intCast(packages.len),
            .collected_at = std.time.timestamp(),
            .cache_hit_rate = cache_hit_rate,
            .download_duration_ms = duration,
        };

        std.debug.print("✅ Collected {} assets ({} MB) in {}ms (cache hit rate: {d:.1}%)\n", .{
            assets.len,
            total_size / (1024 * 1024),
            duration,
            cache_hit_rate,
        });

        return AssetBundle{
            .assets = assets,
            .total_size = total_size,
            .target_platform = target,
            .metadata = metadata,
        };
    }

    /// Find the best compatible asset for a package on target platform
    fn findBestAsset(
        self: *AssetCollector,
        package: dependency_resolver.PackageInfo,
        target: pipeline.TargetPlatform
    ) !Asset {
        // If we already have a wheel URL, use it
        if (package.wheel_url) |wheel_url| {
            return Asset{
                .type = .wheel,
                .path = try self.allocator.dupe(u8, wheel_url),
                .local_path = null,
                .size = 0,
                .hash = if (package.wheel_hash) |hash| try self.allocator.dupe(u8, hash) else null,
                .package_name = try self.allocator.dupe(u8, package.name),
                .package_version = try self.allocator.dupe(u8, package.version),
                .platform_tags = try self.createPlatformTags(target),
            };
        }

        // Query PyPI API for available files
        var pypi_info = try self.queryPyPiPackage(package.name, package.version);
        defer pypi_info.deinit();

        // Find best matching wheel
        const wheel_url = try self.findBestWheelFromPyPi(pypi_info.value, target);

        return Asset{
            .type = .wheel,
            .path = wheel_url,
            .local_path = null,
            .size = 0,
            .hash = null,
            .package_name = try self.allocator.dupe(u8, package.name),
            .package_version = try self.allocator.dupe(u8, package.version),
            .platform_tags = try self.createPlatformTags(target),
        };
    }

    /// Create source distribution asset as fallback
    fn createSourceDistAsset(self: *AssetCollector, package: dependency_resolver.PackageInfo) !Asset {
        // Query PyPI simple index to get actual download URL
        const simple_url = try std.fmt.allocPrint(
            self.allocator,
            "https://pypi.org/simple/{s}/",
            .{package.name}
        );
        defer self.allocator.free(simple_url);

        // Fetch the simple index HTML
        const html_response = self.http_client.get(simple_url) catch |err| {
            std.log.warn("Failed to fetch PyPI simple index for {s}: {}", .{ package.name, err });
            // Fallback to direct URL construction
            const fallback_url = try std.fmt.allocPrint(
                self.allocator,
                "https://files.pythonhosted.org/packages/source/{c}/{s}/{s}-{s}.tar.gz",
                .{ package.name[0], package.name, package.name, package.version }
            );
            return Asset{
                .type = .source_dist,
                .path = fallback_url,
                .package_name = try self.allocator.dupe(u8, package.name),
                .package_version = try self.allocator.dupe(u8, package.version),
                .local_path = null,
                .size = 0,
                .hash = null,
                .platform_tags = &[_][]const u8{},
            };
        };
        defer self.allocator.free(html_response);

        // Parse HTML to find the download URL for the version we want
        const target_filename = try std.fmt.allocPrint(self.allocator, "{s}-{s}.tar.gz", .{ package.name, package.version });
        defer self.allocator.free(target_filename);

        const sdist_url = self.extractDownloadUrlFromHtml(html_response, target_filename) catch |err| blk: {
            std.log.warn("Failed to parse download URL from HTML for {s}: {}", .{ package.name, err });
            // Fallback to direct URL construction
            break :blk try std.fmt.allocPrint(
                self.allocator,
                "https://files.pythonhosted.org/packages/source/{c}/{s}/{s}-{s}.tar.gz",
                .{ package.name[0], package.name, package.name, package.version }
            );
        };

        return Asset{
            .type = .source_dist,
            .path = sdist_url,
            .package_name = try self.allocator.dupe(u8, package.name),
            .package_version = try self.allocator.dupe(u8, package.version),
            .local_path = null,
            .size = 0,
            .hash = null,
            .platform_tags = &[_][]const u8{}, // Empty slice for source distributions
        };
    }

    /// Extract download URL from PyPI simple index HTML
    fn extractDownloadUrlFromHtml(self: *AssetCollector, html: []const u8, target_filename: []const u8) ![]u8 {
        // Look for <a href="...">target_filename</a>
        const href_start = "href=\"";
        const href_end = "\"";

        var start_pos: usize = 0;
        while (std.mem.indexOf(u8, html[start_pos..], href_start)) |href_pos| {
            const absolute_href_pos = start_pos + href_pos + href_start.len;
            const url_end_pos = std.mem.indexOf(u8, html[absolute_href_pos..], href_end) orelse continue;
            const url = html[absolute_href_pos..absolute_href_pos + url_end_pos];

            // Check if this URL contains our target filename
            if (std.mem.indexOf(u8, url, target_filename) != null) {
                // Extract the base URL (before the # fragment)
                const fragment_pos = std.mem.indexOf(u8, url, "#") orelse url.len;
                return try self.allocator.dupe(u8, url[0..fragment_pos]);
            }

            start_pos = absolute_href_pos + url_end_pos;
        }

        return error.DownloadUrlNotFound;
    }

    /// Ensure asset is downloaded and available locally
    fn ensureAssetAvailable(self: *AssetCollector, asset: Asset, cache_hits: *u32) !Asset {
        _ = cache_hits; // Not using cache for now

        // Download the asset
        std.debug.print("    ⬇️  Downloading: {s}\n", .{asset.path});

        const download_path = try self.downloadAsset(asset);

        // For now, just return the downloaded asset without caching
        // TODO: Implement proper file caching
        var downloaded_asset = asset;
        downloaded_asset.local_path = download_path;
        downloaded_asset.size = try self.getFileSize(download_path);

        return downloaded_asset;
    }

    /// Download asset from URL
    fn downloadAsset(self: *AssetCollector, asset: Asset) ![]u8 {
        // Extract filename from URL to preserve wheel names
        const filename = if (std.mem.lastIndexOf(u8, asset.path, "/")) |last_slash|
            asset.path[last_slash + 1..]
        else
            "unknown_asset";

        const temp_file = try std.fmt.allocPrint(self.allocator, "/tmp/{s}", .{filename});
        defer self.allocator.free(temp_file);

        try self.http_client.downloadFile(asset.path, temp_file, bundlr.platform.http.printProgress);

        // Verify hash if available
        if (asset.hash) |expected_hash| {
            const actual_hash = try self.calculateFileHash(temp_file);
            defer self.allocator.free(actual_hash);

            if (!std.mem.eql(u8, expected_hash, actual_hash)) {
                return error.HashMismatch;
            }
        }

        return try self.allocator.dupe(u8, temp_file);
    }

    /// Generate cache key for asset
    fn generateCacheKey(self: *AssetCollector, asset: Asset) ![]u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "asset_{s}_{s}_{s}",
            .{ asset.package_name, asset.package_version, asset.path }
        );
    }

    /// Get file size in bytes
    fn getFileSize(self: *AssetCollector, path: []const u8) !u64 {
        _ = self;
        const file = std.fs.openFileAbsolute(path, .{}) catch return 0;
        defer file.close();
        const stat = try file.stat();
        return stat.size;
    }

    /// Calculate SHA256 hash of file
    fn calculateFileHash(self: *AssetCollector, file_path: []const u8) ![]u8 {
        _ = file_path;
        // TODO: Implement SHA256 hash calculation
        // For now, return empty hash
        return try self.allocator.dupe(u8, "");
    }

    /// Create platform tags for target
    fn createPlatformTags(self: *AssetCollector, target: pipeline.TargetPlatform) ![][]const u8 {
        const tag = switch (target) {
            .linux_x86_64 => "linux_x86_64",
            .linux_aarch64 => "linux_aarch64",
            .windows_x86_64 => "win_amd64",
            .windows_aarch64 => "win_arm64",
            .macos_x86_64 => "macosx_10_9_x86_64",
            .macos_aarch64 => "macosx_11_0_arm64",
            .all => "any",
        };

        var tags = try self.allocator.alloc([]const u8, 1);
        tags[0] = try self.allocator.dupe(u8, tag);
        return tags;
    }

    /// Query PyPI API for package information
    fn queryPyPiPackage(self: *AssetCollector, name: []const u8, version: []const u8) !std.json.Parsed(std.json.Value) {
        // Construct PyPI API URL
        const pypi_url = try std.fmt.allocPrint(
            self.allocator,
            "https://pypi.org/pypi/{s}/{s}/json",
            .{ name, version }
        );
        defer self.allocator.free(pypi_url);

        std.debug.print("    🌐 Querying PyPI: {s}\n", .{pypi_url});

        // Fetch JSON response from PyPI
        const response_body = try self.http_client.get(pypi_url);
        defer self.allocator.free(response_body);

        std.debug.print("    📄 Received {} bytes from PyPI\n", .{response_body.len});

        // Parse JSON response
        return try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            response_body,
            .{}
        );
    }

    /// Find best wheel from PyPI response
    fn findBestWheelFromPyPi(self: *AssetCollector, pypi_info: std.json.Value, target: pipeline.TargetPlatform) ![]u8 {
        // Get the releases URLs array from PyPI JSON
        const urls = pypi_info.object.get("urls") orelse return error.NoUrlsFound;
        const urls_array = urls.array;

        std.debug.print("    🔍 Analyzing {} files from PyPI...\n", .{urls_array.items.len});

        // Define platform tags for target
        const target_tags = try self.getPlatformWheelTags(target);
        defer {
            for (target_tags) |tag| self.allocator.free(tag);
            self.allocator.free(target_tags);
        }

        var best_wheel: ?[]const u8 = null;
        var best_score: i32 = -1;

        // Evaluate each file
        for (urls_array.items) |url_item| {
            const url_obj = url_item.object;

            // Get filename and URL
            const filename = url_obj.get("filename") orelse continue;
            const download_url = url_obj.get("url") orelse continue;
            const package_type = url_obj.get("packagetype") orelse continue;

            // Only consider wheels
            if (!std.mem.eql(u8, package_type.string, "bdist_wheel")) continue;

            std.debug.print("      📦 Evaluating wheel: {s}\n", .{filename.string});

            // Score this wheel for the target platform
            const score = try self.scoreWheelForPlatform(filename.string, target_tags);

            if (score > best_score) {
                best_score = score;
                best_wheel = download_url.string;
                std.debug.print("        ⭐ New best wheel (score: {}): {s}\n", .{ score, filename.string });
            }
        }

        if (best_wheel) |wheel_url| {
            return try self.allocator.dupe(u8, wheel_url);
        } else {
            return error.NoCompatibleWheel;
        }
    }

    /// Get platform-specific wheel tags for target platform
    fn getPlatformWheelTags(self: *AssetCollector, target: pipeline.TargetPlatform) ![][]const u8 {
        switch (target) {
            .linux_x86_64 => {
                const tags = [_][]const u8{ "linux_x86_64", "any" };
                var result = try self.allocator.alloc([]const u8, tags.len);
                for (tags, 0..) |tag, i| {
                    result[i] = try self.allocator.dupe(u8, tag);
                }
                return result;
            },
            .linux_aarch64 => {
                const tags = [_][]const u8{ "linux_aarch64", "any" };
                var result = try self.allocator.alloc([]const u8, tags.len);
                for (tags, 0..) |tag, i| {
                    result[i] = try self.allocator.dupe(u8, tag);
                }
                return result;
            },
            .windows_x86_64 => {
                const tags = [_][]const u8{ "win_amd64", "any" };
                var result = try self.allocator.alloc([]const u8, tags.len);
                for (tags, 0..) |tag, i| {
                    result[i] = try self.allocator.dupe(u8, tag);
                }
                return result;
            },
            .windows_aarch64 => {
                const tags = [_][]const u8{ "win_arm64", "any" };
                var result = try self.allocator.alloc([]const u8, tags.len);
                for (tags, 0..) |tag, i| {
                    result[i] = try self.allocator.dupe(u8, tag);
                }
                return result;
            },
            .macos_x86_64 => {
                const tags = [_][]const u8{ "macosx_10_9_x86_64", "macosx_10_9_universal2", "any" };
                var result = try self.allocator.alloc([]const u8, tags.len);
                for (tags, 0..) |tag, i| {
                    result[i] = try self.allocator.dupe(u8, tag);
                }
                return result;
            },
            .macos_aarch64 => {
                const tags = [_][]const u8{ "macosx_11_0_arm64", "macosx_10_9_universal2", "any" };
                var result = try self.allocator.alloc([]const u8, tags.len);
                for (tags, 0..) |tag, i| {
                    result[i] = try self.allocator.dupe(u8, tag);
                }
                return result;
            },
            .all => {
                const tags = [_][]const u8{"any"};
                var result = try self.allocator.alloc([]const u8, tags.len);
                for (tags, 0..) |tag, i| {
                    result[i] = try self.allocator.dupe(u8, tag);
                }
                return result;
            },
        }
    }

    /// Score a wheel filename for compatibility with target platform
    fn scoreWheelForPlatform(self: *AssetCollector, filename: []const u8, target_tags: [][]const u8) !i32 {
        _ = self;

        // Parse wheel filename: {name}-{version}-{python tag}-{abi tag}-{platform tag}.whl
        var parts = std.mem.splitSequence(u8, filename, "-");

        // Skip name and version
        _ = parts.next() orelse return 0;  // name
        _ = parts.next() orelse return 0;  // version

        // Get python, abi, and platform tags
        const python_tag = parts.next() orelse return 0;
        const abi_tag = parts.next() orelse return 0;

        // Platform tag might have multiple parts (separated by .)
        var platform_part = parts.rest();
        if (std.mem.endsWith(u8, platform_part, ".whl")) {
            platform_part = platform_part[0..platform_part.len - 4]; // Remove .whl
        }

        var score: i32 = 0;

        // Score based on platform compatibility
        for (target_tags, 0..) |target_tag, i| {
            if (std.mem.indexOf(u8, platform_part, target_tag)) |_| {
                // Higher score for more specific matches (earlier in the target_tags array)
                score += @intCast(target_tags.len - i);
            }
        }

        // Prefer pure Python wheels (py2.py3 or py3) over platform-specific
        if (std.mem.indexOf(u8, python_tag, "py3")) |_| {
            score += 10;
        }

        // Prefer none ABI tag (pure Python)
        if (std.mem.eql(u8, abi_tag, "none")) {
            score += 5;
        }

        return score;
    }

    /// Free JSON value resources (deprecated - using std.json.Parsed now)
    fn freeJsonValue(self: *AssetCollector, value: std.json.Value) void {
        _ = self;
        _ = value;
        // No-op - std.json.Parsed handles cleanup automatically
    }
};

// Tests
test "asset collector initialization" {
    const allocator = std.testing.allocator;
    var collector = AssetCollector.init(allocator);
    defer collector.deinit();

    // Test basic functionality
    const tags = try collector.createPlatformTags(.linux_x86_64);
    defer {
        for (tags) |tag| allocator.free(tag);
        allocator.free(tags);
    }

    try std.testing.expect(tags.len == 1);
    try std.testing.expectEqualStrings("linux_x86_64", tags[0]);
}

test "cache key generation" {
    const allocator = std.testing.allocator;
    var collector = AssetCollector.init(allocator);
    defer collector.deinit();

    const asset = Asset{
        .type = .wheel,
        .path = "https://pypi.org/test.whl",
        .package_name = "test-pkg",
        .package_version = "1.0.0",
    };

    const cache_key = try collector.generateCacheKey(asset);
    defer allocator.free(cache_key);

    try std.testing.expect(std.mem.indexOf(u8, cache_key, "test-pkg") != null);
    try std.testing.expect(std.mem.indexOf(u8, cache_key, "1.0.0") != null);
}