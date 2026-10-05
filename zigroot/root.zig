const std = @import("std");
pub const Package = @import("Package.zig");
pub const introspect = struct {
    pub const resolveGlobalCacheDir = std.zig.resolveGlobalCacheDir;
};

