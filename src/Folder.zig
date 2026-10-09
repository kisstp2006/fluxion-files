// SPDX-License-Identifier: BSD-2-Clause

//! A folder as listed: its entries - name, kind, size, when it was last
//! changed, what kind of file it is - sorted as Windows sorts them, folders
//! first and numbers in names by their value ("file2" before "file10").

const std = @import("std");

const Mime = @import("Mime.zig");

const Folder = @This();

pub const Kind = enum { folder, file, other };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    /// A symbolic link - to `kind` - shown with a shortcut's arrow.
    link: bool = false,
    size: u64 = 0,
    /// Last changed, in nanoseconds since the epoch.
    mtime: i128 = 0,
    mime: []const u8 = Mime.unknown,
    /// A dotfile, or named in the folder's `.hidden`: shown only with
    /// "Hidden items" on.
    hidden: bool = false,
    executable: bool = false,

    pub fn isFolder(self: Entry) bool {
        return self.kind == .folder;
    }
};

pub const Column = enum { name, modified, type, size };

arena: std.heap.ArenaAllocator,
path: []const u8,
entries: std.ArrayList(Entry) = .empty,
/// Why it could not be read, if it could not.
failure: ?anyerror = null,

/// Read the folder at `path`.
pub fn read(gpa: std.mem.Allocator, io: std.Io, mime: *const Mime, path: []const u8) Folder {
    var self: Folder = .{ .arena = .init(gpa), .path = "" };
    const a = self.arena.allocator();
    self.path = a.dupe(u8, path) catch path;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        self.failure = err;
        return self;
    };
    defer dir.close(io);
    const hidden_list = dir.readFileAlloc(io, ".hidden", a, .limited(64 << 10)) catch "";
    var it = dir.iterate();
    while (it.next(io) catch |err| blk: {
        self.failure = err;
        break :blk null;
    }) |item| {
        var entry: Entry = .{ .name = a.dupe(u8, item.name) catch continue, .kind = .other };
        entry.hidden = item.name[0] == '.' or listed(hidden_list, item.name);
        entry.link = item.kind == .sym_link;
        // Followed through a link, to what it points at.
        if (dir.statFile(io, item.name, .{})) |stat| {
            entry.kind = switch (stat.kind) {
                .directory => .folder,
                .file => .file,
                else => .other,
            };
            entry.size = stat.size;
            entry.mtime = stat.mtime.nanoseconds;
            entry.executable = stat.permissions.toMode() & 0o111 != 0;
        } else |_| {
            entry.kind = switch (item.kind) {
                .directory => .folder,
                .file => .file,
                else => .other,
            };
        }
        entry.mime = if (entry.kind == .folder) Mime.directory else mime.byName(item.name) orelse guess(io, dir, item.name, entry.executable);
        self.entries.append(a, entry) catch continue;
    }
    return self;
}

pub fn deinit(self: *Folder) void {
    self.arena.deinit();
}

/// Whether `name` is a line of the folder's `.hidden`.
fn listed(list: []const u8, name: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    while (lines.next()) |line| if (std.mem.eql(u8, std.mem.trimEnd(u8, line, "\r"), name)) return true;
    return false;
}

/// The kind of a file whose name says none: its first bytes.
fn guess(io: std.Io, dir: std.Io.Dir, name: []const u8, executable: bool) []const u8 {
    var buffer: [512]u8 = undefined;
    const head = dir.readFile(io, name, &buffer) catch return Mime.unknown;
    return Mime.byContent(head, executable);
}

/// Sort as Windows does: folders before files, then by `by`, ties by name.
pub fn sort(self: *Folder, by: Column, ascending: bool, mime: *Mime) void {
    const Context = struct {
        by: Column,
        ascending: bool,
        mime: *Mime,

        fn lessThan(c: @This(), a: Entry, b: Entry) bool {
            if (a.isFolder() != b.isFolder()) return a.isFolder();
            const order: std.math.Order = switch (c.by) {
                .name => naturalOrder(a.name, b.name),
                .modified => std.math.order(a.mtime, b.mtime),
                .size => std.math.order(a.size, b.size),
                .type => blk: {
                    var ab: [64]u8 = undefined;
                    var bb: [64]u8 = undefined;
                    break :blk naturalOrder(c.mime.describe(a.mime, a.name, &ab), c.mime.describe(b.mime, b.name, &bb));
                },
            };
            const resolved = if (order == .eq) naturalOrder(a.name, b.name) else order;
            return if (c.ascending) resolved == .lt else resolved == .gt;
        }
    };
    std.mem.sort(Entry, self.entries.items, Context{ .by = by, .ascending = ascending, .mime = mime }, Context.lessThan);
}

/// Names compared as Windows' Explorer compares them: case aside, and a
/// run of digits by the number it is - "file2" before "file10".
pub fn naturalOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            // The numbers, leading noughts aside: the longer is larger.
            var ie = i;
            while (ie < a.len and std.ascii.isDigit(a[ie])) ie += 1;
            var je = j;
            while (je < b.len and std.ascii.isDigit(b[je])) je += 1;
            const an = std.mem.trimStart(u8, a[i..ie], "0");
            const bn = std.mem.trimStart(u8, b[j..je], "0");
            if (an.len != bn.len) return std.math.order(an.len, bn.len);
            const o = std.mem.order(u8, an, bn);
            if (o != .eq) return o;
            i = ie;
            j = je;
            continue;
        }
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[j]);
        if (ca != cb) return std.math.order(ca, cb);
        i += 1;
        j += 1;
    }
    return std.math.order(a.len - i, b.len - j);
}

/// "1.21 MB", as Windows' Size column says it: kilobytes rounded up below a
/// megabyte in Details, two or three figures above.
pub fn sizeText(bytes: u64, buffer: []u8) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buffer, "{d} bytes", .{bytes}) catch "";
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var value: f64 = @as(f64, @floatFromInt(bytes)) / 1024;
    var unit: usize = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    if (value >= 100) return std.fmt.bufPrint(buffer, "{d:.0} {s}", .{ value, units[unit] }) catch "";
    if (value >= 10) return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] }) catch "";
    return std.fmt.bufPrint(buffer, "{d:.2} {s}", .{ value, units[unit] }) catch "";
}

test "names sort with their numbers by value" {
    try std.testing.expectEqual(std.math.Order.lt, naturalOrder("file2", "file10"));
    try std.testing.expectEqual(std.math.Order.gt, naturalOrder("File10", "file9"));
    try std.testing.expectEqual(std.math.Order.lt, naturalOrder("a", "B"));
    try std.testing.expectEqual(std.math.Order.eq, naturalOrder("x01", "x1"));
    try std.testing.expectEqual(std.math.Order.lt, naturalOrder("ab", "abc"));
}

test "sizes read as Windows writes them" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 bytes", sizeText(512, &buffer));
    try std.testing.expectEqualStrings("2.00 KB", sizeText(2048, &buffer));
    try std.testing.expectEqualStrings("1.21 MB", sizeText(1_268_777, &buffer));
}

test "a folder is read, its folders first" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "b folder");
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".secret", .data = "x" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(io, &path_buffer);
    var mime: Mime = .{ .arena = .init(std.testing.allocator), .io = io };
    defer mime.deinit();
    mime.parseGlobs("50:text/plain:*.txt\n");
    var folder = read(std.testing.allocator, io, &mime, path_buffer[0..n]);
    defer folder.deinit();
    folder.sort(.name, true, &mime);
    try std.testing.expectEqual(@as(usize, 3), folder.entries.items.len);
    try std.testing.expectEqualStrings("b folder", folder.entries.items[0].name);
    try std.testing.expectEqualStrings("text/plain", folder.entries.items[2].mime);
    try std.testing.expect(folder.entries.items[1].hidden);
}
