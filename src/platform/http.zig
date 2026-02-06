const std = @import("std");
const print = std.debug.print;

/// Progress callback function signature
pub const ProgressFn = *const fn (downloaded: u64, total: ?u64) void;

/// HTTP client errors
pub const HttpError = error{
    NetworkError,
    InvalidUrl,
    FileNotFound,
    ServerError,
    OutOfMemory,
    AccessDenied,
    Timeout,
    TooManyRetries,
    NoSpaceLeft,
};

/// HTTP client configuration
pub const Config = struct {
    /// Maximum number of retry attempts
    max_retries: u32 = 3,
    /// Timeout in milliseconds
    timeout_ms: u32 = 30000,
    /// User agent string
    user_agent: []const u8 = "bundlr/1.0",
};

/// Simple HTTP client for downloading files
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, config: Config) Self {
        return Self{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Download a file from the given URL to the specified path
    /// Optional progress callback for download progress reporting
    pub fn downloadFile(
        self: *Self,
        url: []const u8,
        output_path: []const u8,
        progress_fn: ?ProgressFn,
    ) HttpError!void {
        var retries: u32 = 0;

        while (retries < self.config.max_retries) {
            self.downloadFileAttempt(url, output_path, progress_fn) catch |err| {
                retries += 1;
                if (retries >= self.config.max_retries) {
                    print("Failed to download after {} retries: {}\n", .{ self.config.max_retries, err });
                    return HttpError.TooManyRetries;
                }

                // Wait before retry (exponential backoff)
                const delay_ms = @as(u64, 1000) * (@as(u64, 1) << @intCast(retries - 1));
                print("Download failed, retrying in {}ms... (attempt {}/{})\n", .{ delay_ms, retries + 1, self.config.max_retries });
                std.Thread.sleep(delay_ms * std.time.ns_per_ms);
                continue;
            };

            // Success - no need to retry
            return;
        }
    }

    /// Single download attempt without retries using system tools
    fn downloadFileAttempt(
        self: *Self,
        url: []const u8,
        output_path: []const u8,
        progress_fn: ?ProgressFn,
    ) HttpError!void {
        // Validate URL format
        _ = std.Uri.parse(url) catch return HttpError.InvalidUrl;

        std.log.info("Downloading {s} to {s}", .{ url, output_path });

        // Report initial progress
        if (progress_fn) |callback| {
            callback(0, null);
        }

        // Use system curl command for reliable HTTP downloads
        // This is a pragmatic approach for the MVP

        // Convert timeout from milliseconds to seconds
        const timeout_seconds = (self.config.timeout_ms + 999) / 1000; // Round up
        var timeout_buf: [16]u8 = undefined;
        const timeout_str = try std.fmt.bufPrint(&timeout_buf, "{}", .{timeout_seconds});

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "curl", "-L", "-f", "-m", timeout_str, "-o", output_path, url },
            .cwd = null,
            .env_map = null,
        }) catch |err| {
            std.log.err("Failed to execute curl: {}", .{err});
            return HttpError.NetworkError;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    // Success - get file size for final progress report
                    const file = std.fs.cwd().openFile(output_path, .{}) catch {
                        if (progress_fn) |callback| callback(1, 1);
                        return;
                    };
                    defer file.close();

                    const file_size = file.getEndPos() catch {
                        if (progress_fn) |callback| callback(1, 1);
                        return;
                    };

                    if (progress_fn) |callback| {
                        callback(file_size, file_size);
                    }

                    // Download completed successfully
                } else if (code == 22) {
                    // HTTP error codes
                    std.log.err("HTTP error downloading {s}", .{url});
                    return HttpError.ServerError;
                } else if (code == 7) {
                    // Connection failed
                    std.log.err("Connection failed for {s}", .{url});
                    return HttpError.NetworkError;
                } else {
                    std.log.err("curl failed with exit code {}: {s}", .{ code, result.stderr });
                    return HttpError.NetworkError;
                }
            },
            else => {
                std.log.err("curl process terminated abnormally", .{});
                return HttpError.NetworkError;
            },
        }
    }

    /// Simple GET request that returns the response body as a string
    pub fn get(self: *Self, url: []const u8) HttpError![]u8 {
        // Validate URL format
        _ = std.Uri.parse(url) catch return HttpError.InvalidUrl;

        std.log.info("HTTP GET {s}", .{url});

        // Use curl to get response body with timeout
        const timeout_seconds = (self.config.timeout_ms + 999) / 1000; // Round up
        var timeout_buf: [16]u8 = undefined;
        const timeout_str = try std.fmt.bufPrint(&timeout_buf, "{}", .{timeout_seconds});

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "curl", "-L", "-f", "-s", "-m", timeout_str, url },
            .cwd = null,
            .env_map = null,
        }) catch |err| {
            std.log.err("Failed to execute curl for GET: {}", .{err});
            return HttpError.NetworkError;
        };
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    // Success - return the stdout as response body
                    return result.stdout; // Caller owns this memory
                } else if (code == 22) {
                    // HTTP error codes
                    self.allocator.free(result.stdout);
                    return HttpError.FileNotFound;
                } else {
                    std.log.err("curl GET failed with exit code {}: {s}", .{ code, result.stderr });
                    self.allocator.free(result.stdout);
                    return HttpError.NetworkError;
                }
            },
            else => {
                std.log.err("curl GET process terminated abnormally", .{});
                self.allocator.free(result.stdout);
                return HttpError.NetworkError;
            },
        }
    }
};

/// Simple progress callback that prints download progress
pub fn printProgress(downloaded: u64, total: ?u64) void {
    if (total) |total_bytes| {
        const percentage = (@as(f64, @floatFromInt(downloaded)) / @as(f64, @floatFromInt(total_bytes))) * 100.0;
        print("\rDownloading... {:.1}% ({} / {} bytes)", .{ percentage, downloaded, total_bytes });
    } else {
        print("\rDownloading... {} bytes", .{downloaded});
    }

    if (total != null and downloaded >= total.?) {
        print("\n", .{});
    }
}

// Tests
test "Client initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config{ .max_retries = 5 };
    const client = Client.init(allocator, config);

    try std.testing.expect(client.config.max_retries == 5);
    try std.testing.expect(client.allocator.ptr == allocator.ptr);
}

test "URL parsing validation" {
    // This test ensures our error handling for invalid URLs works
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = Client.init(allocator, Config{});

    // Test with invalid URL - should return InvalidUrl error
    const result = client.get("not-a-url");
    try std.testing.expectError(HttpError.InvalidUrl, result);
}