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
    /// Where it is, for an entry not of one folder: a search's finding, or -
    /// in the Recycle Bin - where it was.
    dir: ?[]const u8 = null,
    /// In the Recycle Bin: its name there, and when it went in.
    stored: ?[]const u8 = null,
    deleted: i128 = 0,

    pub fn isFolder(self: Entry) bool {
        return self.kind == .folder;
    }
};

pub const Column = enum { name, modified, type, size };

/// An empty folder - for what is filled in by other means: a search, the
/// Recycle Bin.
pub fn empty(gpa: std.mem.Allocator, label: []const u8) Folder {
    var self: Folder = .{ .arena = .init(gpa), .path = "" };
    self.path = self.arena.allocator().dupe(u8, label) catch label;
    return self;
}

/// One entry more: a search's finding at `full`.
pub fn addFound(self: *Folder, io: std.Io, mime: *const Mime, full: []const u8) void {
    const a = self.arena.allocator();
    const dir = std.fs.path.dirname(full) orelse "/";
    const name = std.fs.path.basename(full);
    var entry: Entry = .{ .name = a.dupe(u8, name) catch return, .kind = .other, .dir = a.dupe(u8, dir) catch return };
    entry.hidden = name.len > 0 and name[0] == '.';
    if (std.Io.Dir.cwd().statFile(io, full, .{})) |stat| {
        entry.kind = switch (stat.kind) {
            .directory => .folder,
            .file => .file,
            else => .other,
        };
        entry.size = stat.size;
        entry.mtime = stat.mtime.nanoseconds;
    } else |_| {}
    entry.mime = if (entry.kind == .folder) Mime.directory else mime.byName(name) orelse Mime.unknown;
    self.entries.append(a, entry) catch {};
}

/// The Recycle Bin: each file in `trash/files` with what its `.trashinfo`
/// says - where it was, when it went.
pub fn readTrash(gpa: std.mem.Allocator, io: std.Io, mime: *const Mime, trash: []const u8) Folder {
    var self = empty(gpa, "Recycle Bin");
    const a = self.arena.allocator();
    var info_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const info_path = std.fmt.bufPrint(&info_buffer, "{s}/info", .{trash}) catch return self;
    var info_dir = std.Io.Dir.cwd().openDir(io, info_path, .{ .iterate = true }) catch return self;
    defer info_dir.close(io);
    var it = info_dir.iterate();
    while (it.next(io) catch null) |item| {
        if (!std.mem.endsWith(u8, item.name, ".trashinfo")) continue;
        var text_buffer: [8192]u8 = undefined;
        const text = info_dir.readFile(io, item.name, &text_buffer) catch continue;
        const original = trashKey(text, "Path=") orelse continue;
        const decoded = percentDecode(a, original) orelse continue;
        const stored = a.dupe(u8, item.name[0 .. item.name.len - ".trashinfo".len]) catch continue;
        const name = std.fs.path.basename(decoded);
        var entry: Entry = .{
            .name = name,
            .kind = .other,
            .dir = std.fs.path.dirname(decoded) orelse "/",
            .stored = stored,
            .deleted = deletionDate(trashKey(text, "DeletionDate=") orelse ""),
        };
        var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const file = std.fmt.bufPrint(&file_buffer, "{s}/files/{s}", .{ trash, stored }) catch continue;
        if (std.Io.Dir.cwd().statFile(io, file, .{ .follow_symlinks = false })) |stat| {
            entry.kind = switch (stat.kind) {
                .directory => .folder,
                .file => .file,
                else => .other,
            };
            entry.size = stat.size;
            entry.mtime = stat.mtime.nanoseconds;
        } else |_| continue;
        entry.mime = if (entry.kind == .folder) Mime.directory else mime.byName(name) orelse Mime.unknown;
        self.entries.append(a, entry) catch {};
    }
    return self;
}

fn trashKey(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.startsWith(u8, l, key)) return l[key.len..];
    }
    return null;
}

fn percentDecode(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var out = a.alloc(u8, text.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 3 <= text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                out[n] = byte;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[n] = text[i];
        n += 1;
    }
    return out[0..n];
}

/// `2026-10-09T20:40:00`, local time, as nanoseconds since the epoch.
fn deletionDate(text: []const u8) i128 {
    if (text.len < 19) return 0;
    var tm: Tm = std.mem.zeroes(Tm);
    tm.year = (std.fmt.parseInt(c_int, text[0..4], 10) catch return 0) - 1900;
    tm.mon = (std.fmt.parseInt(c_int, text[5..7], 10) catch return 0) - 1;
    tm.mday = std.fmt.parseInt(c_int, text[8..10], 10) catch return 0;
    tm.hour = std.fmt.parseInt(c_int, text[11..13], 10) catch return 0;
    tm.min = std.fmt.parseInt(c_int, text[14..16], 10) catch return 0;
    tm.sec = std.fmt.parseInt(c_int, text[17..19], 10) catch return 0;
    tm.isdst = -1;
    const t = mktime(&tm);
    return @as(i128, t) * std.time.ns_per_s;
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern fn mktime(tm: *Tm) i64;

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
