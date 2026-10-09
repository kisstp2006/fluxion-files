// SPDX-License-Identifier: BSD-2-Clause

//! What is done to files: made, named anew, copied, moved, put in the
//! Recycle Bin or deleted for good - done here at once, as milestone M1
//! has them; the job queue with its progress dialog is M2's.
//!
//! **The Recycle Bin is the freedesktop trash** - the one GTK and KDE apps
//! and the shell's Storage Sense use: `$XDG_DATA_HOME/Trash` for what is on
//! the home's drive, `$topdir/.Trash-$uid` on any other, each file with a
//! `.trashinfo` saying where it was and when it went.

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.ops);

/// A name a person may give a file: something, and no slash.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfScalar(u8, name, '/') == null and std.mem.indexOfScalar(u8, name, 0) == null;
}

fn exists(io: std.Io, dir: []const u8, name: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = join(&buffer, dir, name) catch return true;
    std.Io.Dir.cwd().access(io, full, .{}) catch |err| return err != error.FileNotFound;
    return true;
}

/// `dir/name`, with the root's slash not doubled.
pub fn join(buffer: []u8, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, name });
}

/// `name` split at its extension: "report" and ".pdf"; a folder, or a name
/// that starts with its only dot, has none.
fn splitExtension(name: []const u8, folder: bool) [2][]const u8 {
    if (folder) return .{ name, "" };
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .{ name, "" };
    if (dot == 0) return .{ name, "" };
    return .{ name[0..dot], name[dot..] };
}

/// A name in `dir` not taken, from `wanted`, as Windows makes one:
/// "New folder (2)"; a copy in its own folder "report - Copy.pdf", then
/// "report - Copy (2).pdf".
pub fn freeName(io: std.Io, dir: []const u8, wanted: []const u8, folder: bool, copy: bool, buffer: []u8) []const u8 {
    const stem, const ext = splitExtension(wanted, folder);
    if (!copy and !exists(io, dir, wanted)) return std.fmt.bufPrint(buffer, "{s}", .{wanted}) catch wanted;
    var n: usize = if (copy) 1 else 2;
    while (n < 10_000) : (n += 1) {
        const name = if (copy and n == 1)
            std.fmt.bufPrint(buffer, "{s} - Copy{s}", .{ stem, ext }) catch return wanted
        else if (copy)
            std.fmt.bufPrint(buffer, "{s} - Copy ({d}){s}", .{ stem, n, ext }) catch return wanted
        else
            std.fmt.bufPrint(buffer, "{s} ({d}){s}", .{ stem, n, ext }) catch return wanted;
        if (!exists(io, dir, name)) return name;
    }
    return wanted;
}

/// A new folder in `dir`: "New folder", or the first free number after it.
pub fn newFolder(io: std.Io, dir: []const u8, buffer: []u8) ![]const u8 {
    const name = freeName(io, dir, "New folder", true, false, buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.Io.Dir.cwd().createDir(io, try join(&path_buffer, dir, name), .default_dir);
    return name;
}

/// A new, empty text document in `dir`.
pub fn newTextFile(io: std.Io, dir: []const u8, buffer: []u8) ![]const u8 {
    const name = freeName(io, dir, "New Text Document.txt", false, false, buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try std.Io.Dir.cwd().createFile(io, try join(&path_buffer, dir, name), .{ .exclusive = true });
    file.close(io);
    return name;
}

/// `old` in `dir` named `new` - never over one already called that.
pub fn rename(io: std.Io, dir: []const u8, old: []const u8, new: []const u8) !void {
    if (!validName(new)) return error.BadName;
    if (std.mem.eql(u8, old, new)) return;
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const from = try join(&a, dir, old);
    const to = try join(&b, dir, new);
    // Only its case changed: renamed as asked, it is the same file.
    if (std.ascii.eqlIgnoreCase(old, new)) return std.Io.Dir.renameAbsolute(from, to, io);
    std.Io.Dir.cwd().renamePreserve(from, std.Io.Dir.cwd(), to, io) catch |err| switch (err) {
        // A filesystem that cannot keep from replacing: asked first.
        error.OperationUnsupported => {
            if (exists(io, dir, new)) return error.PathAlreadyExists;
            return std.Io.Dir.renameAbsolute(from, to, io);
        },
        else => return err,
    };
}

// -------------------------------------------------------------------------
// The Recycle Bin
// -------------------------------------------------------------------------

/// Into the Recycle Bin: the home's, or - on another drive - that drive's.
pub fn trash(io: std.Io, path: []const u8) !void {
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_trash = homeTrash(&home_buffer) orelse return error.NoTrash;
    trashInto(io, path, home_trash) catch |err| switch (err) {
        error.CrossDevice => {
            var top_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const top = mountTop(path, &top_buffer) orelse return err;
            var trash_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const drive_trash = std.fmt.bufPrint(&trash_buffer, "{s}/.Trash-{d}", .{ if (std.mem.eql(u8, top, "/")) "" else top, linux.getuid() }) catch return err;
            return trashInto(io, path, drive_trash);
        },
        else => return err,
    };
}

pub fn homeTrash(buffer: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |d| return std.fmt.bufPrint(buffer, "{s}/Trash", .{std.mem.span(d)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.local/share/Trash", .{std.mem.span(home)}) catch null;
}

/// The info written first, claiming the name; then the file moved in -
/// and, that failing, the info taken back.
fn trashInto(io: std.Io, path: []const u8, trash_dir: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const files_dir = try std.fmt.bufPrint(&buffer, "{s}/files", .{trash_dir});
    try std.Io.Dir.cwd().createDirPath(io, files_dir);
    var info_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const info_dir = try std.fmt.bufPrint(&info_buffer, "{s}/info", .{trash_dir});
    try std.Io.Dir.cwd().createDirPath(io, info_dir);

    const base = std.fs.path.basename(path);
    var name_buffer: [512]u8 = undefined;
    var info_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var n: usize = 1;
    const info_file, const name = while (n < 10_000) : (n += 1) {
        const name = if (n == 1) base else blk: {
            const stem, const ext = splitExtension(base, false);
            break :blk std.fmt.bufPrint(&name_buffer, "{s}.{d}{s}", .{ stem, n, ext }) catch return error.NameTooLong;
        };
        const info_path = try std.fmt.bufPrint(&info_path_buffer, "{s}/{s}.trashinfo", .{ info_dir, name });
        const file = std.Io.Dir.cwd().createFile(io, info_path, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        break .{ file, name };
    } else return error.NoFreeName;

    var text_buffer: [std.fs.max_path_bytes * 3 + 128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text_buffer);
    w.writeAll("[Trash Info]\nPath=") catch {};
    percentEncode(&w, path) catch {};
    var date_buffer: [32]u8 = undefined;
    w.print("\nDeletionDate={s}\n", .{nowIso(&date_buffer)}) catch {};
    var file_writer = info_file.writer(io, &.{});
    file_writer.interface.writeAll(w.buffered()) catch {};
    info_file.close(io);

    const info_path = std.fmt.bufPrint(&info_path_buffer, "{s}/{s}.trashinfo", .{ info_dir, name }) catch unreachable;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const to = try std.fmt.bufPrint(&to_buffer, "{s}/{s}", .{ files_dir, name });
    std.Io.Dir.renameAbsolute(path, to, io) catch |err| {
        std.Io.Dir.cwd().deleteFile(io, info_path) catch {};
        return err;
    };
}

/// A path as the trash spec has it: every byte but the unreserved ones and
/// the slashes as `%XX`.
fn percentEncode(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            try w.writeByte(c);
        } else try w.print("%{X:0>2}", .{c});
    }
}

/// Now, local time, as `2026-10-09T20:40:00`.
fn nowIso(buffer: []u8) []const u8 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const seconds: i64 = ts.sec;
    var tm: Tm = undefined;
    if (localtime_r(&seconds, &tm) == null) return "";
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.year + 1900)), @as(u32, @intCast(tm.mon + 1)), @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.hour)),        @as(u32, @intCast(tm.min)),     @as(u32, @intCast(tm.sec)),
    }) catch "";
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
extern fn localtime_r(t: *const i64, out: *Tm) ?*Tm;

/// The top of the drive `path` is on: the last folder up from it on the
/// same device.
fn mountTop(path: []const u8, buffer: []u8) ?[]const u8 {
    const dev = deviceOf(path) orelse return null;
    var top: []const u8 = path;
    var current: []const u8 = path;
    while (std.fs.path.dirname(current)) |parent| {
        const d = deviceOf(parent) orelse break;
        if (d != dev) break;
        top = parent;
        current = parent;
        if (std.mem.eql(u8, parent, "/")) break;
    }
    return std.fmt.bufPrint(buffer, "{s}", .{top}) catch null;
}

fn deviceOf(path: []const u8) ?u64 {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, @ptrCast(&z), linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &sx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return (@as(u64, sx.dev_major) << 32) | sx.dev_minor;
}

// -------------------------------------------------------------------------
// Gone for good, copied, moved
// -------------------------------------------------------------------------

/// Deleted, and all inside it - a link itself, not what it points at.
pub fn deletePermanently(io: std.Io, path: []const u8) !void {
    const dir = std.fs.path.dirname(path) orelse return error.BadPath;
    var parent = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer parent.close(io);
    try parent.deleteTree(io, std.fs.path.basename(path));
}

/// `source` copied into the folder `dest_dir`, under a name free there -
/// "- Copy" when it is the folder it is in. The name it got.
pub fn copyInto(io: std.Io, source: []const u8, dest_dir: []const u8, buffer: []u8) ![]const u8 {
    const same = std.mem.eql(u8, std.fs.path.dirname(source) orelse "/", dest_dir);
    const kind = (std.Io.Dir.cwd().statFile(io, source, .{ .follow_symlinks = false }) catch |err| return err).kind;
    const name = freeName(io, dest_dir, std.fs.path.basename(source), kind == .directory, same, buffer);
    // Never into itself: a folder pasted into a folder inside it.
    if (kind == .directory and isInside(dest_dir, source)) return error.IntoItself;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try copyTree(io, source, try join(&to_buffer, dest_dir, name), 0);
    return name;
}

/// `source` moved into the folder `dest_dir`: renamed there, or - across
/// drives - copied, then deleted. The name it got.
pub fn moveInto(io: std.Io, source: []const u8, dest_dir: []const u8, buffer: []u8) ![]const u8 {
    const from_dir = std.fs.path.dirname(source) orelse "/";
    if (std.mem.eql(u8, from_dir, dest_dir)) return std.fmt.bufPrint(buffer, "{s}", .{std.fs.path.basename(source)}) catch error.NameTooLong;
    if (isInside(dest_dir, source)) return error.IntoItself;
    const kind = (try std.Io.Dir.cwd().statFile(io, source, .{ .follow_symlinks = false })).kind;
    const name = freeName(io, dest_dir, std.fs.path.basename(source), kind == .directory, false, buffer);
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const to = try join(&to_buffer, dest_dir, name);
    std.Io.Dir.renameAbsolute(source, to, io) catch |err| switch (err) {
        error.CrossDevice => {
            try copyTree(io, source, to, 0);
            try deletePermanently(io, source);
        },
        else => return err,
    };
    return name;
}

/// Whether `path` is `folder` or inside it.
fn isInside(path: []const u8, folder: []const u8) bool {
    if (!std.mem.startsWith(u8, path, folder)) return false;
    return path.len == folder.len or path[folder.len] == '/';
}

fn copyTree(io: std.Io, source: []const u8, dest: []const u8, depth: u8) !void {
    if (depth > 64) return error.TooDeep;
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, source, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .sym_link => {
            var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const n = try cwd.readLink(io, source, &target_buffer);
            try cwd.symLink(io, target_buffer[0..n], dest, .{});
        },
        .directory => {
            try cwd.createDir(io, dest, stat.permissions);
            var dir = try cwd.openDir(io, source, .{ .iterate = true });
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                var from_buffer: [std.fs.max_path_bytes]u8 = undefined;
                var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
                try copyTree(io, try join(&from_buffer, source, entry.name), try join(&to_buffer, dest, entry.name), depth + 1);
            }
        },
        else => try std.Io.Dir.copyFileAbsolute(source, dest, io, .{}),
    }
}

test "free names are made as Windows makes them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("New folder", try newFolder(io, dir, &buffer));
    try std.testing.expectEqualStrings("New folder (2)", try newFolder(io, dir, &buffer));
    try tmp.dir.writeFile(io, .{ .sub_path = "report.pdf", .data = "x" });
    try std.testing.expectEqualStrings("report - Copy.pdf", freeName(io, dir, "report.pdf", false, true, &buffer));
    try tmp.dir.writeFile(io, .{ .sub_path = "report - Copy.pdf", .data = "x" });
    try std.testing.expectEqualStrings("report - Copy (2).pdf", freeName(io, dir, "report.pdf", false, true, &buffer));
    try std.testing.expectEqualStrings("report (2).pdf", freeName(io, dir, "report.pdf", false, false, &buffer));
}

test "a folder is copied whole, and moved into another" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/inner/f.txt", .data = "hello" });
    try tmp.dir.createDirPath(io, "b");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var a_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var b_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const a = try join(&a_buffer, root, "a");
    const b = try join(&b_buffer, root, "b");
    var name_buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("a", try copyInto(io, a, b, &name_buffer));
    var read_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try tmp.dir.readFile(io, "b/a/inner/f.txt", &read_buffer));
    // Into itself, never.
    var inner_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectError(error.IntoItself, copyInto(io, a, try join(&inner_buffer, a, "inner"), &name_buffer));
    try std.testing.expectEqualStrings("a (2)", try moveInto(io, a, b, &name_buffer));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "a", .{}));
}

test "the trash keeps where a file was" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "my file.txt", .data = "x" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var file_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var trash_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try join(&file_buffer, root, "my file.txt");
    const trash_dir = try join(&trash_buffer, root, "Trash");
    try trashInto(io, file, trash_dir);
    try tmp.dir.access(io, "Trash/files/my file.txt", .{});
    var info_buffer: [1024]u8 = undefined;
    const info = try tmp.dir.readFile(io, "Trash/info/my file.txt.trashinfo", &info_buffer);
    try std.testing.expect(std.mem.indexOf(u8, info, "my%20file.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, info, "DeletionDate=") != null);
    // A second of the same name is numbered.
    try tmp.dir.writeFile(io, .{ .sub_path = "my file.txt", .data = "y" });
    try trashInto(io, file, trash_dir);
    try tmp.dir.access(io, "Trash/files/my file.2.txt", .{});
}
