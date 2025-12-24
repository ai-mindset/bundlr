//! Git repository archive manager
//! Downloads and extracts GitHub repository archives without requiring git

const std = @import("std");
const paths_module = @import("../platform/paths.zig");
const http = @import("../platform/http.zig");
const extract = @import("../utils/extract.zig");

/// Git reference type for archive downloads
pub const GitRef = union(enum) {
    branch: []const u8,
    tag: []const u8,
    commit: []const u8,

    /// Get the default reference (main branch)
    pub fn default() GitRef {
        return GitRef{ .branch = "main" };
    }

    /// Convert to string for archive URL construction
    pub fn toString(self: GitRef, allocator: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .branch => |branch| try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch}),
            .tag => |tag| try std.fmt.allocPrint(allocator, "refs/tags/{s}", .{tag}),
            .commit => |commit| try allocator.dupe(u8, commit),
        };
    }
};

/// Git repository information
pub const GitRepositoryInfo = struct {
    url: []const u8,
    ref: GitRef,

    /// Extract owner and repository name from GitHub URL
    pub fn parseGitHubUrl(self: *const GitRepositoryInfo, allocator: std.mem.Allocator) !struct { owner: []u8, repo: []u8 } {
        // Remove protocol and domain
        var url = self.url;
        if (std.mem.startsWith(u8, url, "https://github.com/")) {
            url = url["https://github.com/".len..];
        } else if (std.mem.startsWith(u8, url, "http://github.com/")) {
            url = url["http://github.com/".len..];
        } else if (std.mem.startsWith(u8, url, "github.com/")) {
            url = url["github.com/".len..];
        } else {
            return error.InvalidGitHubUrl;
        }

        // Remove trailing .git if present
        if (std.mem.endsWith(u8, url, ".git")) {
            url = url[0 .. url.len - ".git".len];
        }

        // Remove trailing slash if present
        if (std.mem.endsWith(u8, url, "/")) {
            url = url[0 .. url.len - 1];
        }

        // Split owner/repo
        const slash_index = std.mem.indexOf(u8, url, "/") orelse return error.InvalidGitHubUrl;

        const owner = try allocator.dupe(u8, url[0..slash_index]);
        const repo = try allocator.dupe(u8, url[slash_index + 1 ..]);

        return .{ .owner = owner, .repo = repo };
    }

    /// Generate archive download URL for GitHub
    pub fn archiveUrl(self: *const GitRepositoryInfo, allocator: std.mem.Allocator) ![]u8 {
        const parsed = try self.parseGitHubUrl(allocator);
        defer allocator.free(parsed.owner);
        defer allocator.free(parsed.repo);

        const ref_string = try self.ref.toString(allocator);
        defer allocator.free(ref_string);

        return try std.fmt.allocPrint(
            allocator,
            "https://github.com/{s}/{s}/archive/{s}.tar.gz",
            .{ parsed.owner, parsed.repo, ref_string },
        );
    }

    /// Generate a cache-friendly filename
    pub fn cacheFilename(self: *const GitRepositoryInfo, allocator: std.mem.Allocator) ![]u8 {
        const parsed = try self.parseGitHubUrl(allocator);
        defer allocator.free(parsed.owner);
        defer allocator.free(parsed.repo);

        const ref_name = switch (self.ref) {
            .branch => |branch| branch,
            .tag => |tag| tag,
            .commit => |commit| commit[0..@min(commit.len, 8)], // Use first 8 chars of commit
        };

        // Replace invalid filename characters
        const safe_ref = try allocator.dupe(u8, ref_name);
        defer allocator.free(safe_ref);
        for (safe_ref) |*char| {
            if (char.* == '/' or char.* == '\\' or char.* == ':' or char.* == '*' or
                char.* == '?' or char.* == '"' or char.* == '<' or char.* == '>' or char.* == '|') {
                char.* = '_';
            }
        }

        return try std.fmt.allocPrint(
            allocator,
            "{s}-{s}-{s}.tar.gz",
            .{ parsed.owner, parsed.repo, safe_ref },
        );
    }
};

/// Git archive manager - handles downloading and extracting Git repository archives
pub const GitArchiveManager = struct {
    allocator: std.mem.Allocator,
    http_client: http.Client,
    paths: paths_module.Paths,

    pub fn init(allocator: std.mem.Allocator) GitArchiveManager {
        return GitArchiveManager{
            .allocator = allocator,
            .http_client = http.Client.init(allocator, http.Config{}),
            .paths = paths_module.Paths.init(allocator),
        };
    }


    /// Download a Git repository archive
    pub fn downloadRepository(
        self: *GitArchiveManager,
        repo_url: []const u8,
        git_branch: ?[]const u8,
        git_tag: ?[]const u8,
        git_commit: ?[]const u8,
        progress_fn: ?http.ProgressFn,
    ) ![]u8 {
        // Determine the Git reference to use
        const git_ref = if (git_tag) |tag|
            GitRef{ .tag = tag }
        else if (git_commit) |commit|
            GitRef{ .commit = commit }
        else if (git_branch) |branch|
            GitRef{ .branch = branch }
        else
            GitRef.default();

        const repo_info = GitRepositoryInfo{
            .url = repo_url,
            .ref = git_ref,
        };

        // Generate archive URL and filename
        const archive_url = try repo_info.archiveUrl(self.allocator);
        defer self.allocator.free(archive_url);

        const cache_filename = try repo_info.cacheFilename(self.allocator);
        defer self.allocator.free(cache_filename);

        // Get cache directory paths
        const cache_dir = try self.paths.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        const git_archives_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_dir, "git_archives" });
        defer self.allocator.free(git_archives_dir);

        // Ensure git archives directory exists
        std.fs.makeDirAbsolute(git_archives_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const archive_path = try std.fs.path.join(self.allocator, &[_][]const u8{ git_archives_dir, cache_filename });
        errdefer self.allocator.free(archive_path);

        // Check if archive already exists
        std.fs.accessAbsolute(archive_path, .{}) catch {
            // Archive doesn't exist, download it
            try self.http_client.downloadFile(archive_url, archive_path, progress_fn);
        };

        return archive_path;
    }

    /// Extract a repository archive to a working directory
    pub fn extractRepository(self: *GitArchiveManager, archive_path: []const u8, project_name: []const u8) ![]u8 {
        // Create a unique extraction directory
        const cache_dir = try self.paths.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        const extracts_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_dir, "git_extracts" });
        defer self.allocator.free(extracts_dir);

        // Ensure extracts directory exists
        std.fs.makeDirAbsolute(extracts_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Generate unique extract directory name with timestamp
        const timestamp = std.time.timestamp();
        const extract_dir_name = try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ project_name, timestamp });
        defer self.allocator.free(extract_dir_name);

        const extract_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ extracts_dir, extract_dir_name });
        defer self.allocator.free(extract_dir);

        // Ensure extract directory exists
        std.fs.makeDirAbsolute(extract_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Extract the archive
        try extract.extractUsingSystemTools(self.allocator, extract_dir, archive_path);

        // GitHub archives create a subdirectory like "repo-name-branch"
        // Find and return the actual project directory
        const project_dir = try self.findProjectDirectory(extract_dir);
        return project_dir;
    }

    /// Find the actual project directory inside the extracted archive
    fn findProjectDirectory(self: *GitArchiveManager, extract_dir: []const u8) ![]u8 {
        var dir = std.fs.openDirAbsolute(extract_dir, .{ .iterate = true }) catch |err| {
            return err;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .directory) {
                // Return the first directory found (GitHub creates one top-level dir)
                return try std.fs.path.join(self.allocator, &[_][]const u8{ extract_dir, entry.name });
            }
        }

        // No subdirectory found, return the extract directory itself
        return try self.allocator.dupe(u8, extract_dir);
    }

    /// Clean up temporary extraction directory after use
    pub fn cleanupExtraction(_: *GitArchiveManager, extract_path: []const u8) void {
        std.fs.deleteTreeAbsolute(extract_path) catch |err| {
            std.log.warn("Failed to cleanup extraction directory {s}: {}", .{ extract_path, err });
        };
    }

    /// Clean up old extraction directories (older than specified hours)
    pub fn cleanupOldExtractions(self: *GitArchiveManager, hours_old: u64) !void {
        const cache_dir = try self.paths.getBundlrCacheDir();
        defer self.allocator.free(cache_dir);

        const extracts_dir = try std.fs.path.join(self.allocator, &[_][]const u8{ cache_dir, "git_extracts" });
        defer self.allocator.free(extracts_dir);

        var dir = std.fs.openDirAbsolute(extracts_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return, // No extracts directory exists
            else => return err,
        };
        defer dir.close();

        const current_time = std.time.timestamp();
        const cutoff_time = current_time - (@as(i64, @intCast(hours_old)) * 3600);

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .directory) continue;

            // Extract timestamp from directory name (format: project-name-timestamp)
            const last_dash = std.mem.lastIndexOf(u8, entry.name, "-") orelse continue;
            const timestamp_str = entry.name[last_dash + 1 ..];
            const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch continue;

            if (timestamp < cutoff_time) {
                const old_dir_path = try std.fs.path.join(self.allocator, &[_][]const u8{ extracts_dir, entry.name });
                defer self.allocator.free(old_dir_path);
                std.fs.deleteTreeAbsolute(old_dir_path) catch |err| {
                    std.log.warn("Failed to cleanup old extraction {s}: {}", .{ old_dir_path, err });
                };
            }
        }
    }
};

// Tests
test "git ref conversion" {
    const allocator = std.testing.allocator;

    const branch_ref = GitRef{ .branch = "main" };
    const branch_str = try branch_ref.toString(allocator);
    defer allocator.free(branch_str);
    try std.testing.expectEqualStrings("refs/heads/main", branch_str);

    const tag_ref = GitRef{ .tag = "v1.0.0" };
    const tag_str = try tag_ref.toString(allocator);
    defer allocator.free(tag_str);
    try std.testing.expectEqualStrings("refs/tags/v1.0.0", tag_str);

    const commit_ref = GitRef{ .commit = "abc123def456" };
    const commit_str = try commit_ref.toString(allocator);
    defer allocator.free(commit_str);
    try std.testing.expectEqualStrings("abc123def456", commit_str);
}

test "github url parsing" {
    const allocator = std.testing.allocator;

    const repo_info = GitRepositoryInfo{
        .url = "https://github.com/ai-mindset/distil",
        .ref = GitRef{ .branch = "main" },
    };

    const parsed = try repo_info.parseGitHubUrl(allocator);
    defer allocator.free(parsed.owner);
    defer allocator.free(parsed.repo);

    try std.testing.expectEqualStrings("ai-mindset", parsed.owner);
    try std.testing.expectEqualStrings("distil", parsed.repo);

    const archive_url = try repo_info.archiveUrl(allocator);
    defer allocator.free(archive_url);
    try std.testing.expectEqualStrings("https://github.com/ai-mindset/distil/archive/refs/heads/main.tar.gz", archive_url);

    const filename = try repo_info.cacheFilename(allocator);
    defer allocator.free(filename);
    try std.testing.expectEqualStrings("ai-mindset-distil-main.tar.gz", filename);
}

test "git archive manager creation" {
    const allocator = std.testing.allocator;
    var manager = GitArchiveManager.init(allocator);
    defer manager.deinit();

    try std.testing.expect(manager.allocator.vtable == allocator.vtable);
}