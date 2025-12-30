//! Ultra-simple GUI using OS-provided input dialogues
//! Minimal, lightweight, OS-independent dialogue interface

const std = @import("std");
const builtin = @import("builtin");
const print = std.debug.print;

/// Simple input dialogue result
pub const DialogueResult = struct {
    text: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *DialogueResult) void {
        self.allocator.free(self.text);
    }
};

/// Show an input dialogue to get text from user
pub fn showInputDialogue(allocator: std.mem.Allocator, title: []const u8, prompt: []const u8, default_value: []const u8) !DialogueResult {
    switch (builtin.os.tag) {
        .windows => return showWindowsDialogue(allocator, title, prompt, default_value),
        .macos => return showMacDialogue(allocator, title, prompt, default_value),
        .linux => return showLinuxDialogue(allocator, title, prompt, default_value),
        else => return showFallbackDialogue(allocator, title, prompt, default_value),
    }
}

/// Windows implementation using PowerShell Add-Type
fn showWindowsDialogue(allocator: std.mem.Allocator, title: []const u8, prompt: []const u8, default_value: []const u8) !DialogueResult {
    // Use PowerShell to show input dialogue
    const script = try std.fmt.allocPrint(allocator,
        \\Add-Type -AssemblyName Microsoft.VisualBasic
        \\[Microsoft.VisualBasic.Interaction]::InputBox('{s}', '{s}', '{s}')
    , .{ prompt, title, default_value });
    defer allocator.free(script);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "powershell", "-Command", script },
        .cwd = null,
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.DialogueCancelled;
    }

    // Trim whitespace from result
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    const text = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);

    return DialogueResult{
        .text = text,
        .allocator = allocator,
    };
}

/// macOS implementation using osascript
fn showMacDialogue(allocator: std.mem.Allocator, title: []const u8, prompt: []const u8, default_value: []const u8) !DialogueResult {
    const script = try std.fmt.allocPrint(allocator,
        \\display dialog "{s}" default answer "{s}" with title "{s}" buttons {{"Cancel", "OK"}} default button "OK"
        \\text returned of result
    , .{ prompt, default_value, title });
    defer allocator.free(script);

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "osascript", "-e", script },
        .cwd = null,
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.DialogueCancelled;
    }

    // Trim whitespace from result
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    const text = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);

    return DialogueResult{
        .text = text,
        .allocator = allocator,
    };
}

/// Linux implementation using zenity (with fallback)
fn showLinuxDialogue(allocator: std.mem.Allocator, title: []const u8, prompt: []const u8, default_value: []const u8) !DialogueResult {
    // Try zenity first
    if (showZenityDialogue(allocator, title, prompt, default_value)) |result| {
        return result;
    } else |_| {
        // Fallback to kdialog
        if (showKdialogDialogue(allocator, title, prompt, default_value)) |result| {
            return result;
        } else |_| {
            // Final fallback to terminal input
            return showFallbackDialogue(allocator, title, prompt, default_value);
        }
    }
}

/// Try zenity dialogue
fn showZenityDialogue(allocator: std.mem.Allocator, title: []const u8, prompt: []const u8, default_value: []const u8) !DialogueResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "zenity",
            "--entry",
            "--title",
            title,
            "--text",
            prompt,
            "--entry-text",
            default_value,
        },
        .cwd = null,
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.DialogueCancelled;
    }

    // Trim whitespace from result
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    const text = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);

    return DialogueResult{
        .text = text,
        .allocator = allocator,
    };
}

/// Try kdialog
fn showKdialogDialogue(allocator: std.mem.Allocator, title: []const u8, prompt: []const u8, default_value: []const u8) !DialogueResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "kdialog",
            "--inputbox",
            prompt,
            default_value,
            "--title",
            title,
        },
        .cwd = null,
    });
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return error.DialogueCancelled;
    }

    // Trim whitespace from result
    const trimmed = std.mem.trim(u8, result.stdout, " \t\n\r");
    const text = try allocator.dupe(u8, trimmed);
    allocator.free(result.stdout);

    return DialogueResult{
        .text = text,
        .allocator = allocator,
    };
}

/// Fallback to terminal input for any OS
fn showFallbackDialogue(allocator: std.mem.Allocator, title: []const u8, prompt: []const u8, default_value: []const u8) !DialogueResult {
    print("\n" ++ "=" ** 50 ++ "\n", .{});
    print("  {s}\n", .{title});
    print("=" ** 50 ++ "\n", .{});
    print("{s}", .{prompt});
    if (default_value.len > 0) {
        print(" [{s}]", .{default_value});
    }
    // Auto-select default value immediately (no stdin reading)
    if (default_value.len > 0) {
        print(" -> {s}\n", .{default_value});
        const text = try allocator.dupe(u8, default_value);
        return DialogueResult{
            .text = text,
            .allocator = allocator,
        };
    }

    print(" -> <cancelled>\n", .{});
    return error.DialogueCancelled;
}

/// Show console output in a new terminal window
pub fn showConsoleOutput(allocator: std.mem.Allocator, title: []const u8, command: []const []const u8) !void {
    switch (builtin.os.tag) {
        .windows => try showWindowsConsole(allocator, title, command),
        .macos => try showMacConsole(allocator, title, command),
        .linux => try showLinuxConsole(allocator, title, command),
        else => try showFallbackConsole(allocator, title, command),
    }
}

/// Windows console implementation using cmd
/// Escapes a Windows command-line argument according to CMD rules
/// Caller must free the returned string
fn escapeWindowsArgument(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    // Quick check if escaping is needed
    var needs_quotes = false;
    var has_quotes = false;
    var backslash_count: usize = 0;

    // Check if argument contains spaces, tabs, or quotes
    for (arg) |char| {
        switch (char) {
            ' ', '\t' => needs_quotes = true,
            '"' => {
                needs_quotes = true;
                has_quotes = true;
            },
            '\\' => backslash_count += 1,
            else => backslash_count = 0,
        }
    }

    // If no special characters, return copy of original
    if (!needs_quotes and !has_quotes) {
        return try allocator.dupe(u8, arg);
    }

    // Calculate required length for escaped string
    var escaped_len: usize = arg.len;
    if (needs_quotes) escaped_len += 2; // opening and closing quotes

    // Count additional escaping needed
    var i: usize = 0;
    while (i < arg.len) {
        const char = arg[i];
        if (char == '"') {
            escaped_len += 1; // for backslash before quote
        } else if (char == '\\') {
            // Count consecutive backslashes
            var slash_count: usize = 0;
            var j = i;
            while (j < arg.len and arg[j] == '\\') {
                slash_count += 1;
                j += 1;
            }
            // If backslashes are followed by quote or end of string (with quotes), double them
            if (j < arg.len and arg[j] == '"') {
                escaped_len += slash_count; // double the backslashes
            } else if (j == arg.len and needs_quotes) {
                escaped_len += slash_count; // double backslashes before closing quote
            }
            i = j - 1; // will be incremented by loop
        }
        i += 1;
    }

    // Build escaped string
    const escaped = try allocator.alloc(u8, escaped_len);
    var pos: usize = 0;

    if (needs_quotes) {
        escaped[pos] = '"';
        pos += 1;
    }

    i = 0;
    while (i < arg.len) {
        const char = arg[i];
        if (char == '"') {
            // Escape quote
            escaped[pos] = '\\';
            pos += 1;
            escaped[pos] = '"';
            pos += 1;
        } else if (char == '\\') {
            // Handle backslashes
            var slash_count: usize = 0;
            var j = i;
            while (j < arg.len and arg[j] == '\\') {
                slash_count += 1;
                j += 1;
            }

            // Check if we need to double backslashes
            var double_slashes = false;
            if (j < arg.len and arg[j] == '"') {
                double_slashes = true; // before quote
            } else if (j == arg.len and needs_quotes) {
                double_slashes = true; // before closing quote
            }

            // Write backslashes (doubled if needed)
            const total_slashes = if (double_slashes) slash_count * 2 else slash_count;
            for (0..total_slashes) |_| {
                escaped[pos] = '\\';
                pos += 1;
            }

            i = j - 1; // will be incremented by loop
        } else {
            escaped[pos] = char;
            pos += 1;
        }
        i += 1;
    }

    if (needs_quotes) {
        escaped[pos] = '"';
        pos += 1;
    }

    return escaped;
}

/// Escapes a command string for nested cmd /k execution
/// Caller must free the returned string
fn escapeForNestedCmd(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    // For cmd /k, we need to escape quotes within the command string
    // and wrap the entire command in quotes

    var quote_count: usize = 0;
    for (command) |char| {
        if (char == '"') quote_count += 1;
    }

    // Allocate space: original + quotes to escape + wrapping quotes
    const escaped_len = command.len + quote_count + 2;
    const escaped = try allocator.alloc(u8, escaped_len);
    var pos: usize = 0;

    // Opening quote
    escaped[pos] = '"';
    pos += 1;

    // Escape internal quotes
    for (command) |char| {
        if (char == '"') {
            escaped[pos] = '\\';
            pos += 1;
            escaped[pos] = '"';
            pos += 1;
        } else {
            escaped[pos] = char;
            pos += 1;
        }
    }

    // Closing quote
    escaped[pos] = '"';
    pos += 1;

    return escaped;
}

fn showWindowsConsole(allocator: std.mem.Allocator, title: []const u8, command: []const []const u8) !void {
    // Build command string using proper Windows argument escaping
    // First, escape each argument and calculate total length
    var escaped_args: [][]u8 = try allocator.alloc([]u8, command.len);
    var escaped_count: usize = 0;
    defer {
        // Only free successfully allocated arguments
        for (escaped_args[0..escaped_count]) |arg| {
            allocator.free(arg);
        }
        allocator.free(escaped_args);
    }

    var total_len: usize = 0;
    for (command, 0..) |arg, i| {
        escaped_args[i] = try escapeWindowsArgument(allocator, arg);
        escaped_count = i + 1; // Track successful allocations
        if (i > 0) total_len += 1; // space
        total_len += escaped_args[i].len;
    }

    // Add space for pause command
    const pause_cmd = " && echo. && echo Press any key to close... && pause";
    total_len += pause_cmd.len;

    // Build final command string
    const cmd_str = try allocator.alloc(u8, total_len);
    defer allocator.free(cmd_str);

    var pos: usize = 0;
    for (escaped_args, 0..) |part, i| {
        if (i > 0) {
            cmd_str[pos] = ' ';
            pos += 1;
        }
        @memcpy(cmd_str[pos..pos + part.len], part);
        pos += part.len;
    }

    // Add pause to keep window open
    @memcpy(cmd_str[pos..pos + pause_cmd.len], pause_cmd);
    pos += pause_cmd.len;

    // Escape the entire command string for nested cmd /k usage
    const escaped_cmd = try escapeForNestedCmd(allocator, cmd_str[0..pos]);
    defer allocator.free(escaped_cmd);
    const full_cmd = try std.fmt.allocPrint(allocator, "start \"{s}\" cmd /k {s}", .{ title, escaped_cmd });
    defer allocator.free(full_cmd);

    // Spawn terminal asynchronously
    var child = std.process.Child.init(&[_][]const u8{ "cmd", "/c", full_cmd }, allocator);
    child.spawn() catch |err| {
        std.log.err("Failed to open Windows console: {}", .{err});
        return;
    };
}

/// macOS console implementation using Terminal app
fn showMacConsole(allocator: std.mem.Allocator, title: []const u8, command: []const []const u8) !void {
    // Build command string manually
    var total_len: usize = 0;
    for (command, 0..) |arg, i| {
        if (i > 0) total_len += 1; // space
        total_len += 2; // quotes
        total_len += arg.len * 2; // worst case: every char might need escaping
    }
    total_len += 50; // pause command

    const cmd_str = try allocator.alloc(u8, total_len);
    defer allocator.free(cmd_str);

    var pos: usize = 0;
    for (command, 0..) |arg, i| {
        if (i > 0) {
            cmd_str[pos] = ' ';
            pos += 1;
        }
        // Escape single quotes and wrap in quotes
        cmd_str[pos] = '\'';
        pos += 1;
        var j: usize = 0;
        while (j < arg.len) {
            if (arg[j] == '\'') {
                const escape_seq = "'\\''";
                @memcpy(cmd_str[pos..pos + escape_seq.len], escape_seq);
                pos += escape_seq.len;
            } else {
                cmd_str[pos] = arg[j];
                pos += 1;
            }
            j += 1;
        }
        cmd_str[pos] = '\'';
        pos += 1;
    }

    // Add pause to keep window open
    const pause_cmd = "; echo; echo 'Press any key to close...'; read -n 1";
    @memcpy(cmd_str[pos..pos + pause_cmd.len], pause_cmd);
    pos += pause_cmd.len;

    const script = try std.fmt.allocPrint(allocator,
        \\tell application "Terminal"
        \\    set newTab to do script "{s}"
        \\    set custom title of newTab to "{s}"
        \\end tell
    , .{ cmd_str[0..pos], title });
    defer allocator.free(script);

    // Spawn terminal asynchronously
    var child = std.process.Child.init(&[_][]const u8{ "osascript", "-e", script }, allocator);
    child.spawn() catch |err| {
        std.log.err("Failed to open macOS Terminal: {}", .{err});
        return;
    };
}

/// Linux console implementation using available terminal emulators
fn showLinuxConsole(allocator: std.mem.Allocator, title: []const u8, command: []const []const u8) !void {
    // Build command string manually
    var total_len: usize = 0;
    for (command, 0..) |arg, i| {
        if (i > 0) total_len += 1; // space
        total_len += 2; // quotes
        total_len += arg.len * 2; // worst case: every char might need escaping
    }
    total_len += 50; // pause command

    const cmd_str = try allocator.alloc(u8, total_len);
    defer allocator.free(cmd_str);

    var pos: usize = 0;
    for (command, 0..) |arg, i| {
        if (i > 0) {
            cmd_str[pos] = ' ';
            pos += 1;
        }
        // Escape shell metacharacters
        cmd_str[pos] = '\'';
        pos += 1;
        var j: usize = 0;
        while (j < arg.len) {
            if (arg[j] == '\'') {
                const escape_seq = "'\\''";
                @memcpy(cmd_str[pos..pos + escape_seq.len], escape_seq);
                pos += escape_seq.len;
            } else {
                cmd_str[pos] = arg[j];
                pos += 1;
            }
            j += 1;
        }
        cmd_str[pos] = '\'';
        pos += 1;
    }

    // Add pause to keep window open
    const pause_cmd = "; echo; echo 'Press Enter to close...'; read";
    @memcpy(cmd_str[pos..pos + pause_cmd.len], pause_cmd);
    pos += pause_cmd.len;

    // Try different terminal emulators in order of preference
    const terminals = [_]struct { name: []const u8, args: []const []const u8 }{
        .{ .name = "gnome-terminal", .args = &[_][]const u8{ "--title", title, "--", "bash", "-c" } },
        .{ .name = "konsole", .args = &[_][]const u8{ "--title", title, "-e", "bash", "-c" } },
        .{ .name = "xterm", .args = &[_][]const u8{ "-title", title, "-e", "bash", "-c" } },
        .{ .name = "x-terminal-emulator", .args = &[_][]const u8{ "-T", title, "-e", "bash", "-c" } },
    };

    for (terminals) |term| {
        // Build complete argument list using fixed array
        var full_args: [16][]const u8 = undefined;
        var full_arg_count: usize = 0;

        full_args[full_arg_count] = term.name;
        full_arg_count += 1;

        for (term.args) |arg| {
            if (full_arg_count >= full_args.len) break;
            full_args[full_arg_count] = arg;
            full_arg_count += 1;
        }

        if (full_arg_count < full_args.len) {
            full_args[full_arg_count] = cmd_str[0..pos];
            full_arg_count += 1;
        }

        // Spawn terminal asynchronously
        var child = std.process.Child.init(full_args[0..full_arg_count], allocator);
        child.spawn() catch {
            continue; // Try next terminal
        };

        // Don't wait for the terminal to complete - let it run independently
        return; // Success - terminal was launched
    }

    // All terminals failed, fall back to console output
    try showFallbackConsole(allocator, title, command);
}

/// Fallback console implementation - run in current terminal
fn showFallbackConsole(allocator: std.mem.Allocator, title: []const u8, command: []const []const u8) !void {
    print("\n" ++ "=" ** 50 ++ "\n", .{});
    print("  {s}\n", .{title});
    print("=" ** 50 ++ "\n\n", .{});

    // Execute command directly in current terminal
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = command,
        .cwd = null,
    }) catch |err| {
        print("❌ Failed to execute command: {}\n", .{err});
        return;
    };

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Print output
    if (result.stdout.len > 0) {
        print("{s}", .{result.stdout});
    }
    if (result.stderr.len > 0) {
        print("{s}", .{result.stderr});
    }

    if (result.term == .Exited) {
        if (result.term.Exited == 0) {
            print("\n✅ Command completed successfully\n", .{});
        } else {
            print("\n❌ Command failed with exit code: {}\n", .{result.term.Exited});
        }
    }

    print("\n" ++ "=" ** 50 ++ "\n", .{});
}

/// Show a simple message dialogue
pub fn showMessageDialogue(title: []const u8, message: []const u8) void {
    switch (builtin.os.tag) {
        .windows => showWindowsMessage(title, message),
        .macos => showMacMessage(title, message),
        .linux => showLinuxMessage(title, message),
        else => showFallbackMessage(title, message),
    }
}

fn showWindowsMessage(title: []const u8, message: []const u8) void {
    const script = std.fmt.allocPrint(std.heap.page_allocator,
        \\[System.Windows.Forms.MessageBox]::Show('{s}', '{s}')
    , .{ message, title }) catch return;
    defer std.heap.page_allocator.free(script);

    _ = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "powershell", "-Command", script },
        .cwd = null,
    }) catch {};
}

fn showMacMessage(title: []const u8, message: []const u8) void {
    const script = std.fmt.allocPrint(std.heap.page_allocator,
        \\display dialog "{s}" with title "{s}" buttons {{"OK"}} default button "OK"
    , .{ message, title }) catch return;
    defer std.heap.page_allocator.free(script);

    _ = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "osascript", "-e", script },
        .cwd = null,
    }) catch {};
}

fn showLinuxMessage(title: []const u8, message: []const u8) void {
    // Try zenity first
    _ = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "zenity", "--info", "--title", title, "--text", message },
        .cwd = null,
    }) catch {
        // Fallback to kdialog
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{ "kdialog", "--msgbox", message, "--title", title },
            .cwd = null,
        }) catch {
            // Final fallback
            showFallbackMessage(title, message);
        };
    };
}

fn showFallbackMessage(title: []const u8, message: []const u8) void {
    print("\n" ++ "=" ** 50 ++ "\n", .{});
    print("  {s}\n", .{title});
    print("=" ** 50 ++ "\n", .{});
    print("{s}\n", .{message});
    print("=" ** 50 ++ "\n\n", .{});
}

// Tests
test "dialogue result cleanup" {
    const allocator = std.testing.allocator;
    var result = DialogueResult{
        .text = try allocator.dupe(u8, "test"),
        .allocator = allocator,
    };
    defer result.deinit();

    try std.testing.expectEqualStrings("test", result.text);
}

test "Windows argument escaping - no special characters" {
    const allocator = std.testing.allocator;

    const result = try escapeWindowsArgument(allocator, "simple");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("simple", result);
}

test "Windows argument escaping - spaces" {
    const allocator = std.testing.allocator;

    const result = try escapeWindowsArgument(allocator, "path with spaces");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\"path with spaces\"", result);
}

test "Windows argument escaping - quotes" {
    const allocator = std.testing.allocator;

    const result = try escapeWindowsArgument(allocator, "path\"with\"quotes");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\"path\\\"with\\\"quotes\"", result);
}

test "Windows argument escaping - complex path" {
    const allocator = std.testing.allocator;

    const result = try escapeWindowsArgument(allocator, "C:\\Program Files\\App \"Version\"\\bundlr.exe");
    defer allocator.free(result);

    // Backslashes that are not before quotes don't need to be doubled for cmd.exe
    try std.testing.expectEqualStrings("\"C:\\Program Files\\App \\\"Version\\\"\\bundlr.exe\"", result);
}

test "escapeForNestedCmd basic functionality" {
    const allocator = std.testing.allocator;

    const result = try escapeForNestedCmd(allocator, "simple command");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\"simple command\"", result);
}

test "escapeForNestedCmd with quotes" {
    const allocator = std.testing.allocator;

    const result = try escapeForNestedCmd(allocator, "command \"with quotes\"");
    defer allocator.free(result);

    try std.testing.expectEqualStrings("\"command \\\"with quotes\\\"\"", result);
}