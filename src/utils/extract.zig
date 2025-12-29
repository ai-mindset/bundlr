//! File and archive extraction utilities for bundlr
//! Supports file extraction and archive formats (tar.gz, ZIP)

const std = @import("std");
const fs = std.fs;
const builtin = @import("builtin");
const paths_module = @import("../platform/paths.zig");

/// Archive type detection based on file extension
pub const ArchiveType = enum {
    single_file,
    tar_gz,
    zip,
    unsupported,

    /// Detect archive type from filename
    pub fn fromFilename(filename: []const u8) ArchiveType {
        if (std.mem.endsWith(u8, filename, ".tar.gz") or std.mem.endsWith(u8, filename, ".tgz")) {
            return .tar_gz;
        } else if (std.mem.endsWith(u8, filename, ".zip")) {
            return .zip;
        } else {
            return .single_file;
        }
    }
};

/// Extract a single file to a directory
/// This is the original extractFile function from main.zig
pub fn extractFile(allocator: std.mem.Allocator, target_dir: []const u8, filename: []const u8, data: []const u8) !void {
    // Ensure target directory exists - use ensureDirExists for consistent cross-platform directory creation
    var paths = paths_module.Paths.init(allocator);
    try paths.ensureDirExists(target_dir);

    // Build full path and write file - use path.join for cross-platform compatibility
    const file_path = try fs.path.join(allocator, &.{ target_dir, filename });
    defer allocator.free(file_path);

    if (fs.path.isAbsolute(target_dir)) {
        const file = try fs.createFileAbsolute(file_path, .{});
        defer file.close();
        try file.writeAll(data);
    } else {
        const file = try fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(data);
    }
}

/// Extract an archive (auto-detects format from filename)
/// For archives, writes data to a temporary file and uses system tools
pub fn extractArchive(allocator: std.mem.Allocator, target_dir: []const u8, filename: []const u8, data: []const u8) !void {
    const archive_type = ArchiveType.fromFilename(filename);

    switch (archive_type) {
        .single_file => {
            return extractFile(allocator, target_dir, filename, data);
        },
        .tar_gz, .zip => {
            // Write data to temporary file and use system tools
            var paths = paths_module.Paths.init(allocator);
            const temp_dir = try paths.getTemporaryDir();
            defer allocator.free(temp_dir);

            const temp_file_path = try fs.path.join(allocator, &.{ temp_dir, filename });
            defer allocator.free(temp_file_path);

            // Write data to temp file
            const file = try fs.createFileAbsolute(temp_file_path, .{});
            defer file.close();
            try file.writeAll(data);

            // Ensure temp file is also cleaned up if an error occurs after this point
            errdefer fs.deleteFileAbsolute(temp_file_path) catch {};

            // Extract using system tools
            try extractUsingSystemTools(allocator, target_dir, temp_file_path);

            // Clean up temp file on success
            fs.deleteFileAbsolute(temp_file_path) catch {};
        },
        .unsupported => {
            return error.UnsupportedArchiveFormat;
        },
    }
}

/// Extract using system commands (fallback for complex archives)
/// This is a more practical approach for MVP implementation
pub fn extractUsingSystemTools(
    allocator: std.mem.Allocator,
    target_dir: []const u8,
    archive_path: []const u8,
) !void {
    const archive_type = ArchiveType.fromFilename(archive_path);

    switch (archive_type) {
        .tar_gz => {
            try extractTarGzWithSystemTar(allocator, target_dir, archive_path);
        },
        .zip => {
            try extractZipWithSystemUnzip(allocator, target_dir, archive_path);
        },
        else => {
            return error.UnsupportedForSystemExtraction;
        },
    }
}

/// Extract tar.gz using system tar command
fn extractTarGzWithSystemTar(allocator: std.mem.Allocator, target_dir: []const u8, archive_path: []const u8) !void {
    const args = [_][]const u8{ "tar", "-xzf", archive_path, "-C", target_dir };

    var process = std.process.Child.init(&args, allocator);
    const result = try process.spawnAndWait();

    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                return error.ExtractionFailed;
            }
        },
        else => return error.ExtractionFailed,
    }
}

/// Extract ZIP using system unzip command
fn extractZipWithSystemUnzip(allocator: std.mem.Allocator, target_dir: []const u8, archive_path: []const u8) !void {
    // Ensure target directory exists - use ensureDirExists for consistent cross-platform directory creation
    var paths = paths_module.Paths.init(allocator);
    try paths.ensureDirExists(target_dir);

    // Use different commands based on platform
    switch (builtin.os.tag) {
        .windows => {
            // Windows PowerShell command - build single command string for -Command
            const command = try std.fmt.allocPrint(
                allocator,
                "& {{Expand-Archive -LiteralPath '{s}' -DestinationPath '{s}' -Force}}",
                .{ archive_path, target_dir },
            );
            defer allocator.free(command);

            const args = [_][]const u8{
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy", "Bypass",
                "-Command",
                command,
            };

            var process = std.process.Child.init(&args, allocator);
            const result = try process.spawnAndWait();

            switch (result) {
                .Exited => |code| {
                    if (code != 0) {
                        return error.ExtractionFailed;
                    }
                },
                else => return error.ExtractionFailed,
            }
        },
        else => {
            const args = [_][]const u8{ "unzip", "-q", archive_path, "-d", target_dir };

            var process = std.process.Child.init(&args, allocator);
            const result = try process.spawnAndWait();

            switch (result) {
                .Exited => |code| {
                    if (code != 0) {
                        return error.ExtractionFailed;
                    }
                },
                else => return error.ExtractionFailed,
            }
        },
    }
}

/// Utility function to set executable permissions on Unix systems
pub fn setExecutablePermissions(file_path: []const u8) !void {
    switch (builtin.os.tag) {
        .windows => {
            // Windows doesn't use Unix permissions
            return;
        },
        else => {
            // Set executable permissions (0o755)
            const file = std.fs.openFileAbsolute(file_path, .{}) catch return;
            defer file.close();
            try file.chmod(0o755);
        },
    }
}

// Tests
test "archive type detection" {
    try std.testing.expect(ArchiveType.fromFilename("python.tar.gz") == .tar_gz);
    try std.testing.expect(ArchiveType.fromFilename("python.tgz") == .tar_gz);
    try std.testing.expect(ArchiveType.fromFilename("python.zip") == .zip);
    try std.testing.expect(ArchiveType.fromFilename("hello.txt") == .single_file);
}

test "extractFile creates file with correct content" {
    const allocator = std.testing.allocator;
    // Use a temporary directory
    const test_dir = "test_extract_dir";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const test_data = "Hello from bundlr extract module!";
    try extractFile(allocator, test_dir, "test_output.txt", test_data);

    // Read it back and verify
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&path_buf, "{s}/test_output.txt", .{test_dir});

    const file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    var buf: [256]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    try std.testing.expectEqualStrings(test_data, buf[0..bytes_read]);
}

test "single file extraction via extractArchive" {
    const allocator = std.testing.allocator;
    const test_dir = "test_archive_dir";
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    const test_data = "Archive test data";
    try extractArchive(allocator, test_dir, "test.txt", test_data);

    // Verify file was created
    const file_path = try std.fs.path.join(allocator, &.{ test_dir, "test.txt" });
    defer allocator.free(file_path);

    const file = try fs.cwd().openFile(file_path, .{});
    defer file.close();

    var buf: [256]u8 = undefined;
    const bytes_read = try file.readAll(&buf);
    try std.testing.expectEqualStrings(test_data, buf[0..bytes_read]);
}