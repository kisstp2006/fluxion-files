// SPDX-License-Identifier: BSD-2-Clause

//! Which app opens a kind of file: the one `mimeapps.list` says - this
//! desktop's own list first (`fluxion-mimeapps.list`), then the shared one,
//! the user's before the system's, as the freedesktop specification orders
//! them - or else the first app whose desktop entry says it opens that
//! kind. "Open with" lists them all.

const std = @import("std");

const apps_mod = @import("apps.zig");
const App = apps_mod.App;

const OpenWith = @This();

arena: std.heap.ArenaAllocator,
/// `kind=first.desktop;second.desktop;`, as read, the first list read first.
defaults: std.StringHashMapUnmanaged([]const u8) = .empty,

pub fn load(gpa: std.mem.Allocator, io: std.Io) OpenWith {
    var self: OpenWith = .{ .arena = .init(gpa) };
    const a = self.arena.allocator();
    var dirs: std.ArrayList([]const u8) = .empty;
    if (std.c.getenv("XDG_CONFIG_HOME")) |d| {
        dirs.append(a, a.dupe(u8, std.mem.span(d)) catch "") catch {};
    } else if (std.c.getenv("HOME")) |home| {
        dirs.append(a, std.fmt.allocPrint(a, "{s}/.config", .{std.mem.span(home)}) catch "") catch {};
    }
    const config_dirs = if (std.c.getenv("XDG_CONFIG_DIRS")) |d| std.mem.span(d) else "/etc/xdg";
    var it = std.mem.tokenizeScalar(u8, config_dirs, ':');
    while (it.next()) |d| dirs.append(a, a.dupe(u8, d) catch continue) catch {};
    const data_dirs = if (std.c.getenv("XDG_DATA_DIRS")) |d| std.mem.span(d) else "/usr/local/share:/usr/share";
    var data = std.mem.tokenizeScalar(u8, data_dirs, ':');
    while (data.next()) |d| dirs.append(a, std.fmt.allocPrint(a, "{s}/applications", .{d}) catch continue) catch {};
    for (dirs.items) |dir| {
        for ([_][]const u8{ "fluxion-mimeapps.list", "mimeapps.list" }) |name| {
            const file = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch continue;
            const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch continue;
            self.parse(text);
        }
    }
    return self;
}

pub fn deinit(self: *OpenWith) void {
    self.arena.deinit();
}

/// A `mimeapps.list`'s `[Default Applications]`: what is already known
/// stays, as an earlier list is the stronger.
pub fn parse(self: *OpenWith, text: []const u8) void {
    const a = self.arena.allocator();
    var in_defaults = false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            in_defaults = std.mem.eql(u8, line, "[Default Applications]");
            continue;
        }
        if (!in_defaults) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const got = self.defaults.getOrPut(a, line[0..eq]) catch continue;
        if (!got.found_existing) got.value_ptr.* = line[eq + 1 ..];
    }
}

/// From now on `app_id` opens `mime`: written into this desktop's own
/// list, `fluxion-mimeapps.list` - read before the shared ones - and taken
/// at once.
pub fn setDefault(self: *OpenWith, io: std.Io, mime: []const u8, app_id: []const u8) !void {
    const a = self.arena.allocator();
    const config = if (std.c.getenv("XDG_CONFIG_HOME")) |d|
        try a.dupe(u8, std.mem.span(d))
    else
        try std.fmt.allocPrint(a, "{s}/.config", .{std.mem.span(std.c.getenv("HOME") orelse return error.NoHome)});
    const file = try std.fmt.allocPrint(a, "{s}/fluxion-mimeapps.list", .{config});
    const was = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch "[Default Applications]\n";
    var out: std.ArrayList(u8) = .empty;
    const value = try std.fmt.allocPrint(a, "{s};", .{app_id});
    try @import("actions.zig").setKey(a, &out, was, "Default Applications", mime, value);
    std.Io.Dir.cwd().createDirPath(io, config) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = out.items });
    try self.defaults.put(a, try a.dupe(u8, mime), value);
}

/// The app that opens `mime`, if any does.
pub fn defaultFor(self: *const OpenWith, apps: *const apps_mod.Apps, mime: []const u8) ?*const App {
    if (self.defaults.get(mime)) |list| {
        var ids = std.mem.tokenizeScalar(u8, list, ';');
        while (ids.next()) |id| if (apps.find(id)) |app| return app;
    }
    for (apps.list) |*app| if (opens(app, mime)) return app;
    // A kind of text no app names opens as text.
    if (std.mem.startsWith(u8, mime, "text/") and !std.mem.eql(u8, mime, "text/plain")) return self.defaultFor(apps, "text/plain");
    return null;
}

/// The apps that say they open `mime`, the default first: what Open with
/// lists.
pub fn appsFor(self: *const OpenWith, apps: *const apps_mod.Apps, mime: []const u8, out: []*const App) []*const App {
    var n: usize = 0;
    if (self.defaultFor(apps, mime)) |first| {
        out[0] = first;
        n = 1;
    }
    for (apps.list) |*app| {
        if (n == out.len) break;
        if (!opens(app, mime)) continue;
        if (n > 0 and out[0] == app) continue;
        out[n] = app;
        n += 1;
    }
    return out[0..n];
}

/// Whether `app`'s `MimeType=` names `mime`.
pub fn opens(app: *const App, mime: []const u8) bool {
    var kinds = std.mem.tokenizeScalar(u8, app.mime_types, ';');
    while (kinds.next()) |kind| if (std.mem.eql(u8, kind, mime)) return true;
    return false;
}

test "the first list read decides" {
    var open: OpenWith = .{ .arena = .init(std.testing.allocator) };
    defer open.deinit();
    open.parse("[Added Associations]\ntext/plain=nope.desktop;\n[Default Applications]\ntext/plain=first.desktop;\n");
    open.parse("[Default Applications]\ntext/plain=second.desktop;\nimage/png=viewer.desktop;\n");
    try std.testing.expectEqualStrings("first.desktop;", open.defaults.get("text/plain").?);
    try std.testing.expectEqualStrings("viewer.desktop;", open.defaults.get("image/png").?);
}
