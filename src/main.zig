// SPDX-License-Identifier: BSD-2-Clause

//! fluxion-files: the file manager of Fluxion Desktop.
//!
//! ```bash
//! fluxion-files                 # Home (Quick access in Windows 10's look)
//! fluxion-files ~/Documents     # a folder
//! fluxion-files file:///tmp     # as a URI, as other apps hand one over
//! ```

const std = @import("std");

const Files = @import("Files.zig");
const Places = @import("Places.zig");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.c_allocator;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    // A folder to open at - a path or a file:// URI.
    var start: ?[]const u8 = null;
    if (args.len > 1) {
        const given: []const u8 = args[1];
        const path = if (std.mem.startsWith(u8, given, "file://")) Places.unescape(arena, given["file://".len..]) orelse given else given;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().realPathFile(init.io, path, &buffer) catch 0;
        start = if (n > 0) try arena.dupe(u8, buffer[0..n]) else path;
    }

    var files: Files = undefined;
    try files.init(gpa, init.io, start);
    defer files.deinit();
    files.window.run() catch |err| switch (err) {
        // The compositor has gone, and the window with it.
        error.ConnectionLost => {},
        else => return err,
    };
}

test {
    _ = @import("Look.zig");
    _ = @import("Mime.zig");
    _ = @import("Folder.zig");
    _ = @import("Places.zig");
    _ = @import("OpenWith.zig");
    _ = @import("views.zig");
    _ = @import("ImageFile.zig");
    _ = @import("apps.zig");
}
