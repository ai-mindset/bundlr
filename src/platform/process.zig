const std = @import("std");
const builtin = @import("builtin");

/// Process execution result
pub const ProcessResult = struct {
    exit_code: u32,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: ProcessResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Execute command with arguments and environment
pub fn execute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    env_vars: ?[]const []const u8,
    working_dir: ?[]const u8,
) !ProcessResult {
    var process = std.process.Child.init(args, allocator);

    if (env_vars) |env| {
        var env_map = std.process.EnvMap.init(allocator);
        defer env_map.deinit();

        var i: usize = 0;
        while (i < env.len) : (i += 2) {
            if (i + 1 < env.len) {
                try env_map.put(env[i], env[i + 1]);
            }
        }

        process.env_map = &env_map;
    }

    if (working_dir) |dir| {
        process.cwd = dir;
    }

    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    try process.spawn();

    const stdout = try process.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    const stderr = try process.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    const result = try process.wait();

    const exit_code = switch (result) {
        .Exited => |code| code,
        else => 1,
    };

    return ProcessResult{
        .exit_code = exit_code,
        .stdout = stdout,
        .stderr = stderr,
    };
}

/// Execute command and return only exit code
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    working_dir: ?[]const u8,
) !u32 {
    var process = std.process.Child.init(args, allocator);
    if (working_dir) |dir| process.cwd = dir;

    const result = try process.spawnAndWait();
    return switch (result) {
        .Exited => |code| code,
        else => 1,
    };
}

/// Execute command with environment variables and return only exit code
pub fn runWithEnv(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    working_dir: ?[]const u8,
    env_vars: []const []const u8,
) !u32 {
    var process = std.process.Child.init(args, allocator);
    if (working_dir) |dir| process.cwd = dir;

    // Set up environment variables
    var env_map = std.process.EnvMap.init(allocator);
    defer env_map.deinit();

    var i: usize = 0;
    while (i < env_vars.len) : (i += 2) {
        if (i + 1 < env_vars.len) {
            try env_map.put(env_vars[i], env_vars[i + 1]);
        }
    }

    process.env_map = &env_map;

    const result = try process.spawnAndWait();
    return switch (result) {
        .Exited => |code| code,
        else => 1,
    };
}