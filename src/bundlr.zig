//! Bundlr - A Python application packaging tool
//! This is the main library module for the bundlr project.

const std = @import("std");

// Re-export modules as they're implemented
pub const config = @import("config.zig");
pub const platform = struct {
    pub const paths = @import("platform/paths.zig");
    pub const http = @import("platform/http.zig");
    pub const process = @import("platform/process.zig");
};
pub const python = struct {
    pub const distribution = @import("python/distribution.zig");
    pub const venv = @import("python/venv.zig");
    pub const installer = @import("python/installer.zig");
};
pub const utils = struct {
    pub const extract = @import("utils/extract.zig");
    pub const cache = @import("utils/cache.zig");
};
pub const uv = struct {
    pub const bootstrap = @import("uv/bootstrap.zig");
    pub const venv = @import("uv/venv.zig");
    pub const installer = @import("uv/installer.zig");
};
pub const git = struct {
    pub const archive = @import("git/archive.zig");
};
pub const gui = struct {
    pub const dialogues = @import("gui/simple_dialogues.zig");
};

