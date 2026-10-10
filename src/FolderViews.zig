// SPDX-License-Identifier: BSD-2-Clause

//! Each folder as it was last shown, as File Explorer remembers it: its
//! view, what it is sorted and grouped by, and - in Details - which columns
//! and how wide. A folder never shown takes after its kind, as Windows'
//! folder templates have it: Pictures and Videos in Large icons, the rest
//! in Details - or as Folder Options' "Apply to Folders" set that kind;
//! "Reset Folders" forgets it all.
//!
//! Kept in `$XDG_STATE_HOME/fluxion/files-views`, a line a folder, a kind's
//! own under "@pictures" and the like.

const std = @import("std");

const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const Places = @import("Places.zig");

const FolderViews = @This();

const log = std.log.scoped(.views);

/// Windows' folder templates.
pub const Kind = enum { general, documents, pictures, music, videos };

pub const Shown = struct {
    view: Tab.View = .details,
    sort_by: Folder.Column = .name,
    ascending: bool = true,
    group_by: ?Folder.Column = null,
    /// The columns of Details, a bit each; and their widths, nought for
    /// their own.
    columns: u16 = Tab.default_columns,
    widths: [Folder.column_count]u16 = @splat(0),
};

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
/// By path - or "@pictures" for a kind.
list: std.StringHashMapUnmanaged(Shown) = .empty,
read: bool = false,

pub fn init(gpa: std.mem.Allocator) FolderViews {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *FolderViews) void {
    self.arena.deinit();
}

fn load(self: *FolderViews, io: std.Io) void {
    if (self.read) return;
    self.read = true;
    const a = self.arena.allocator();
    var buffer: [512]u8 = undefined;
    const file = statePath(&buffer) orelse return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(4 << 20)) catch return;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const parsed = parseLine(line) orelse continue;
        self.list.put(a, parsed.path, parsed.shown) catch return;
    }
}

const Line = struct { path: []const u8, shown: Shown };

fn parseLine(line: []const u8) ?Line {
    var parts = std.mem.splitScalar(u8, line, '\t');
    const path = parts.next() orelse return null;
    var s: Shown = .{};
    s.view = std.meta.stringToEnum(Tab.View, parts.next() orelse return null) orelse return null;
    s.sort_by = std.meta.stringToEnum(Folder.Column, parts.next() orelse return null) orelse .name;
    s.ascending = std.mem.eql(u8, parts.next() orelse "1", "1");
    const group = parts.next() orelse "-";
    s.group_by = if (std.mem.eql(u8, group, "-")) null else std.meta.stringToEnum(Folder.Column, group);
    s.columns = std.fmt.parseInt(u16, parts.next() orelse "0", 10) catch Tab.default_columns;
    if (s.columns == 0) s.columns = Tab.default_columns;
    var widths = std.mem.splitScalar(u8, parts.next() orelse "", ',');
    for (&s.widths) |*w| w.* = std.fmt.parseInt(u16, widths.next() orelse "0", 10) catch 0;
    return .{ .path = path, .shown = s };
}

fn save(self: *FolderViews, io: std.Io) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.gpa);
    var it = self.list.iterator();
    while (it.next()) |e| {
        const s = e.value_ptr.*;
        out.print(self.gpa, "{s}\t{t}\t{t}\t{d}\t{s}\t{d}\t", .{ e.key_ptr.*, s.view, s.sort_by, @intFromBool(s.ascending), if (s.group_by) |g| @tagName(g) else "-", s.columns }) catch return;
        for (s.widths, 0..) |w, i| out.print(self.gpa, "{s}{d}", .{ if (i > 0) "," else "", w }) catch return;
        out.append(self.gpa, '\n') catch return;
    }
    var buffer: [512]u8 = undefined;
    const file = statePath(&buffer) orelse return;
    if (std.fs.path.dirname(file)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = out.items }) catch |err| log.warn("could not save the views: {t}", .{err});
}

/// The kind of folder `path` is: a person's Pictures, or in it.
pub fn kindOf(places: *const Places, path: []const u8) Kind {
    const pairs = [_]struct { Places.Special, Kind }{ .{ .pictures, .pictures }, .{ .videos, .videos }, .{ .music, .music }, .{ .documents, .documents } };
    for (pairs) |pair| if (places.pathOf(pair[0])) |root| {
        if (std.mem.eql(u8, root, places.home)) continue;
        if (std.mem.startsWith(u8, path, root) and (path.len == root.len or path[root.len] == '/')) return pair[1];
    };
    return .general;
}

fn kindKey(kind: Kind) []const u8 {
    return switch (kind) {
        .general => "@general",
        .documents => "@documents",
        .pictures => "@pictures",
        .music => "@music",
        .videos => "@videos",
    };
}

/// How `path` is to be shown: as it was, or as its kind is.
pub fn lookup(self: *FolderViews, io: std.Io, places: *const Places, path: []const u8) Shown {
    self.load(io);
    if (self.list.get(path)) |s| return s;
    const kind = kindOf(places, path);
    if (self.list.get(kindKey(kind))) |s| return s;
    return switch (kind) {
        .pictures, .videos => .{ .view = .large },
        else => .{},
    };
}

/// The tab at `path`, shown as that folder was.
pub fn applyTo(self: *FolderViews, io: std.Io, places: *const Places, t: *Tab, path: []const u8) void {
    const s = self.lookup(io, places, path);
    t.view = s.view;
    t.sort_by = s.sort_by;
    t.ascending = s.ascending;
    t.group_by = s.group_by;
    t.columns = s.columns;
    t.widths = s.widths;
}

fn shownOf(t: *const Tab) Shown {
    return .{ .view = t.view, .sort_by = t.sort_by, .ascending = t.ascending, .group_by = t.group_by, .columns = t.columns, .widths = t.widths };
}

/// The folder the tab shows, as it is shown now: kept.
pub fn remember(self: *FolderViews, io: std.Io, t: *const Tab) void {
    const path = t.path() orelse return;
    if (t.inArchive()) return;
    self.load(io);
    const a = self.arena.allocator();
    const got = self.list.getOrPut(a, path) catch return;
    if (!got.found_existing) got.key_ptr.* = a.dupe(u8, path) catch return;
    got.value_ptr.* = shownOf(t);
    self.save(io);
}

/// Folder Options' Apply to Folders: every folder of this one's kind shown
/// as it is - those remembered on their own too.
pub fn applyToAll(self: *FolderViews, io: std.Io, places: *const Places, t: *const Tab) void {
    const path = t.path() orelse return;
    self.load(io);
    const kind = kindOf(places, path);
    const a = self.arena.allocator();
    // The folders of its kind forget their own.
    var drop: std.ArrayList([]const u8) = .empty;
    var it = self.list.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.*[0] == '@') continue;
        if (kindOf(places, e.key_ptr.*) == kind) drop.append(a, e.key_ptr.*) catch {};
    }
    for (drop.items) |k| _ = self.list.remove(k);
    self.list.put(a, kindKey(kind), shownOf(t)) catch return;
    self.save(io);
}

/// Folder Options' Reset Folders: every folder as its kind comes.
pub fn reset(self: *FolderViews, io: std.Io) void {
    self.load(io);
    self.list.clearRetainingCapacity();
    self.save(io);
}

fn statePath(buffer: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |dir| return std.fmt.bufPrint(buffer, "{s}/fluxion/files-views", .{std.mem.span(dir)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.local/state/fluxion/files-views", .{std.mem.span(home)}) catch null;
}

test "a folder's view is read back as it was written" {
    const line = parseLine("/home/k/Pictures\tlarge\tmodified\t0\ttype\t11\t300,0,120,0,0,0,0,0").?;
    try std.testing.expectEqualStrings("/home/k/Pictures", line.path);
    try std.testing.expectEqual(Tab.View.large, line.shown.view);
    try std.testing.expectEqual(Folder.Column.modified, line.shown.sort_by);
    try std.testing.expect(!line.shown.ascending);
    try std.testing.expectEqual(Folder.Column.type, line.shown.group_by.?);
    try std.testing.expectEqual(@as(u16, 11), line.shown.columns);
    try std.testing.expectEqual(@as(u16, 300), line.shown.widths[0]);
}
