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

/// `names` in `dir` hidden - written into the folder's `.hidden`, as GTK's
/// and KDE's file managers read it - or shown again. Windows' "Hide
/// selected items", and Properties' Hidden.
pub fn setHidden(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, names: []const []const u8, hidden: bool) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = try join(&path_buffer, dir, ".hidden");
    const was = std.Io.Dir.cwd().readFileAlloc(io, file, gpa, .limited(1 << 20)) catch try gpa.dupe(u8, "");
    defer gpa.free(was);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var lines = std.mem.tokenizeScalar(u8, was, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const named = for (names) |n| {
            if (std.mem.eql(u8, n, line)) break true;
        } else false;
        // Each once; shown again, gone from the list.
        if (named) continue;
        try out.appendSlice(gpa, line);
        try out.append(gpa, '\n');
    }
    if (hidden) for (names) |n| {
        try out.appendSlice(gpa, n);
        try out.append(gpa, '\n');
    };
    // Nothing hidden: no list.
    if (out.items.len == 0) {
        std.Io.Dir.cwd().deleteFile(io, file) catch {};
        return;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = out.items });
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
    var bin_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var stored_buffer: [512]u8 = undefined;
    _ = try trashKeeping(io, path, &bin_buffer, &stored_buffer);
}

/// Where a thing put in the Recycle Bin went: which bin, its name there -
/// what Undo takes it back out by.
pub const Kept = struct { bin: []const u8, stored: []const u8 };

pub fn trashKeeping(io: std.Io, path: []const u8, bin_buffer: []u8, stored_buffer: []u8) !Kept {
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_trash = homeTrash(&home_buffer) orelse return error.NoTrash;
    const stored = trashInto(io, path, home_trash, stored_buffer) catch |err| switch (err) {
        error.CrossDevice => {
            var top_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const top = mountTop(path, &top_buffer) orelse return err;
            const drive_trash = std.fmt.bufPrint(bin_buffer, "{s}/.Trash-{d}", .{ if (std.mem.eql(u8, top, "/")) "" else top, linux.getuid() }) catch return err;
            return .{ .bin = drive_trash, .stored = try trashInto(io, path, drive_trash, stored_buffer) };
        },
        else => return err,
    };
    return .{ .bin = std.fmt.bufPrint(bin_buffer, "{s}", .{home_trash}) catch return error.NameTooLong, .stored = stored };
}

pub fn homeTrash(buffer: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |d| return std.fmt.bufPrint(buffer, "{s}/Trash", .{std.mem.span(d)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.local/share/Trash", .{std.mem.span(home)}) catch null;
}

/// The info written first, claiming the name; then the file moved in -
/// and, that failing, the info taken back.
fn trashInto(io: std.Io, path: []const u8, trash_dir: []const u8, stored_buffer: []u8) ![]const u8 {
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
    return std.fmt.bufPrint(stored_buffer, "{s}", .{name}) catch error.NameTooLong;
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

pub fn deviceOf(path: []const u8) ?u64 {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, @ptrCast(&z), linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &sx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return (@as(u64, sx.dev_major) << 32) | sx.dev_minor;
}

/// `stored` in the Recycle Bin back as `name` in `dir` - under a name
/// free there - and its `.trashinfo` gone.
pub fn restore(io: std.Io, bin: []const u8, stored: []const u8, dir: []const u8, name: []const u8) !void {
    var from_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const from = try std.fmt.bufPrint(&from_buffer, "{s}/files/{s}", .{ bin, stored });
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const kind = (try std.Io.Dir.cwd().statFile(io, from, .{ .follow_symlinks = false })).kind;
    var name_buffer: [512]u8 = undefined;
    const free = freeName(io, dir, name, kind == .directory, false, &name_buffer);
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const to = try join(&to_buffer, dir, free);
    std.Io.Dir.renameAbsolute(from, to, io) catch |err| switch (err) {
        error.CrossDevice => {
            try copyTree(io, from, to, 0);
            try deletePermanently(io, from);
        },
        else => return err,
    };
    var info_buffer: [std.fs.max_path_bytes]u8 = undefined;
    std.Io.Dir.cwd().deleteFile(io, try std.fmt.bufPrint(&info_buffer, "{s}/info/{s}.trashinfo", .{ bin, stored })) catch {};
}

/// `stored` in the Recycle Bin gone for good, and its record with it.
pub fn purge(io: std.Io, bin: []const u8, stored: []const u8) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    try deletePermanently(io, try std.fmt.bufPrint(&buffer, "{s}/files/{s}", .{ bin, stored }));
    std.Io.Dir.cwd().deleteFile(io, try std.fmt.bufPrint(&buffer, "{s}/info/{s}.trashinfo", .{ bin, stored })) catch {};
}

/// A shortcut to `target` in `dir`, as Windows makes one - "report -
/// Shortcut.pdf" - here a symbolic link. The name it got.
pub fn shortcut(io: std.Io, target: []const u8, dir: []const u8, buffer: []u8) ![]const u8 {
    const kind = (try std.Io.Dir.cwd().statFile(io, target, .{})).kind;
    const stem, const ext = splitExtension(std.fs.path.basename(target), kind == .directory);
    var wanted_buffer: [512]u8 = undefined;
    const wanted = try std.fmt.bufPrint(&wanted_buffer, "{s} - Shortcut{s}", .{ stem, ext });
    const name = freeName(io, dir, wanted, kind == .directory, false, buffer);
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.Io.Dir.cwd().symLink(io, target, try join(&link_buffer, dir, name), .{ .is_directory = kind == .directory });
    return name;
}

/// Everything in the Recycle Bin gone for good, and its records with it.
pub fn emptyTrash(io: std.Io, bin: []const u8) !void {
    for ([_][]const u8{ "files", "info" }) |part| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ bin, part });
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| dir.deleteTree(io, entry.name) catch {};
    }
}

// -------------------------------------------------------------------------
// What a file is
// -------------------------------------------------------------------------

fn statxOf(path: []const u8, follow: bool, mask: linux.STATX) ?linux.Statx {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= z.len) return null;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    var sx: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, @ptrCast(&z), if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW, mask, &sx);
    if (linux.errno(rc) != .SUCCESS) return null;
    return sx;
}

/// When the file was made, where the filesystem keeps it: nanoseconds.
pub fn created(io: std.Io, path: []const u8) ?i128 {
    _ = io;
    const sx = statxOf(path, true, .{ .BTIME = true }) orelse return null;
    if (!sx.mask.BTIME) return null;
    return @as(i128, sx.btime.sec) * std.time.ns_per_s + sx.btime.nsec;
}

/// What a file is, for its properties: its mode, its owner and group, its
/// times, and how much of the disk it takes.
pub const Info = struct {
    mode: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    size: u64 = 0,
    on_disk: u64 = 0,
    accessed: i128 = 0,
    modified: i128 = 0,
    created: ?i128 = null,
};

pub fn info(path: []const u8) ?Info {
    const sx = statxOf(path, true, .{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .SIZE = true, .BLOCKS = true, .ATIME = true, .MTIME = true, .BTIME = true }) orelse return null;
    return .{
        .mode = sx.mode,
        .uid = sx.uid,
        .gid = sx.gid,
        .size = sx.size,
        .on_disk = sx.blocks * 512,
        .accessed = @as(i128, sx.atime.sec) * std.time.ns_per_s + sx.atime.nsec,
        .modified = @as(i128, sx.mtime.sec) * std.time.ns_per_s + sx.mtime.nsec,
        .created = if (sx.mask.BTIME) @as(i128, sx.btime.sec) * std.time.ns_per_s + sx.btime.nsec else null,
    };
}

/// What a folder holds, all the way down: its files, its folders, their
/// bytes and the disk they take - counted to a limit, a home's worth.
pub const Usage = struct { files: u64 = 0, folders: u64 = 0, bytes: u64 = 0, on_disk: u64 = 0, partial: bool = false };

pub fn usage(io: std.Io, path: []const u8) Usage {
    var out: Usage = .{};
    var stack: [64][]u8 = undefined;
    var depth: usize = 0;
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    stack[0] = a.dupe(u8, path) catch return out;
    depth = 1;
    var seen: usize = 0;
    while (depth > 0) {
        depth -= 1;
        const dir_path = stack[depth];
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            seen += 1;
            if (seen > 200_000) {
                out.partial = true;
                return out;
            }
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const full = join(&buffer, dir_path, entry.name) catch continue;
            const sx = statxOf(full, false, .{ .TYPE = true, .SIZE = true, .BLOCKS = true }) orelse continue;
            out.on_disk += sx.blocks * 512;
            if (entry.kind == .directory) {
                out.folders += 1;
                if (depth < stack.len) {
                    stack[depth] = a.dupe(u8, full) catch continue;
                    depth += 1;
                } else out.partial = true;
            } else {
                out.files += 1;
                out.bytes += sx.size;
            }
        }
    }
    return out;
}

/// Its mode bits, all twelve, set to `mode`.
pub fn setMode(path: []const u8, mode: u32) !void {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= z.len) return error.NameTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    if (std.c.chmod(@ptrCast(&z), @intCast(mode & 0o7777)) != 0) return error.AccessDenied;
}

const Passwd = extern struct { name: ?[*:0]const u8, passwd: ?[*:0]const u8, uid: u32, gid: u32, gecos: ?[*:0]const u8, dir: ?[*:0]const u8, shell: ?[*:0]const u8 };
const Group = extern struct { name: ?[*:0]const u8, passwd: ?[*:0]const u8, gid: u32, members: ?*anyopaque };
extern fn getpwuid(uid: u32) ?*Passwd;
extern fn getgrgid(gid: u32) ?*Group;

/// The name of user `uid`, or its number.
pub fn userName(uid: u32, buffer: []u8) []const u8 {
    if (getpwuid(uid)) |pw| if (pw.name) |n| return std.fmt.bufPrint(buffer, "{s}", .{std.mem.span(n)}) catch "";
    return std.fmt.bufPrint(buffer, "{d}", .{uid}) catch "";
}

pub fn groupName(gid: u32, buffer: []u8) []const u8 {
    if (getgrgid(gid)) |g| if (g.name) |n| return std.fmt.bufPrint(buffer, "{s}", .{std.mem.span(n)}) catch "";
    return std.fmt.bufPrint(buffer, "{d}", .{gid}) catch "";
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
pub fn isInside(path: []const u8, folder: []const u8) bool {
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

test "a shortcut is a link named as Windows names one" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "report.pdf", .data = "x" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const target = try join(&target_buffer, root, "report.pdf");
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("report - Shortcut.pdf", try shortcut(io, target, root, &buffer));
    try std.testing.expectEqualStrings("report - Shortcut (2).pdf", try shortcut(io, target, root, &buffer));
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(target, link_buffer[0..try tmp.dir.readLink(io, "report - Shortcut.pdf", &link_buffer)]);
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
    var stored_buffer: [512]u8 = undefined;
    _ = try trashInto(io, file, trash_dir, &stored_buffer);
    try tmp.dir.access(io, "Trash/files/my file.txt", .{});
    var info_buffer: [1024]u8 = undefined;
    const written = try tmp.dir.readFile(io, "Trash/info/my file.txt.trashinfo", &info_buffer);
    try std.testing.expect(std.mem.indexOf(u8, written, "my%20file.txt") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "DeletionDate=") != null);
    // A second of the same name is numbered.
    try tmp.dir.writeFile(io, .{ .sub_path = "my file.txt", .data = "y" });
    try std.testing.expectEqualStrings("my file.2.txt", try trashInto(io, file, trash_dir, &stored_buffer));
    try tmp.dir.access(io, "Trash/files/my file.2.txt", .{});
}
