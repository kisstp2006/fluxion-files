// SPDX-License-Identifier: BSD-2-Clause

//! The places the navigation pane lists, as the rest of the desktop knows
//! them:
//!
//! - **the user's folders** - Desktop, Downloads, Documents, Pictures,
//!   Music, Videos - from `user-dirs.dirs`, as xdg-user-dirs writes it;
//! - **the pinned folders** (Quick access): GTK's bookmarks,
//!   `~/.config/gtk-3.0/bookmarks`, so GTK's file chooser shows them too;
//! - **the drives** This PC lists: the root and what is mounted for the
//!   person - under `/run/media`, `/media`, `/mnt` - and a home on a
//!   partition of its own, with how full each is.

const std = @import("std");

const Places = @This();

pub const Special = enum { desktop, downloads, documents, pictures, music, videos, templates, public };

pub const Folder = struct {
    name: []const u8,
    path: []const u8,
    special: ?Special = null,
};

pub const Drive = struct {
    /// "Fedora", or the mount point's last part.
    label: []const u8,
    mount: []const u8,
    device: []const u8,
    size: u64 = 0,
    free: u64 = 0,
    removable: bool = false,
};

arena: std.heap.ArenaAllocator,
home: []const u8 = "",
user: std.ArrayList(Folder) = .empty,
pinned: std.ArrayList(Folder) = .empty,
drives: std.ArrayList(Drive) = .empty,

pub fn load(gpa: std.mem.Allocator, io: std.Io) Places {
    var self: Places = .{ .arena = .init(gpa) };
    const a = self.arena.allocator();
    self.home = if (std.c.getenv("HOME")) |h| a.dupe(u8, std.mem.span(h)) catch "/" else "/";
    self.readUserDirs(io);
    self.readBookmarks(io);
    self.readDrives(io);
    return self;
}

pub fn deinit(self: *Places) void {
    self.arena.deinit();
}

fn configHome(self: *Places, buffer: []u8) []const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |d| return std.fmt.bufPrint(buffer, "{s}", .{std.mem.span(d)}) catch "";
    return std.fmt.bufPrint(buffer, "{s}/.config", .{self.home}) catch "";
}

/// `XDG_DESKTOP_DIR="$HOME/Desktop"`, a line each; the usual names where
/// the file says nothing.
fn readUserDirs(self: *Places, io: std.Io) void {
    const a = self.arena.allocator();
    var buffer: [512]u8 = undefined;
    const file = std.fmt.allocPrint(a, "{s}/user-dirs.dirs", .{self.configHome(&buffer)}) catch return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(64 << 10)) catch "";
    const wanted = [_]struct { key: []const u8, special: Special, name: []const u8, fallback: []const u8 }{
        .{ .key = "XDG_DESKTOP_DIR", .special = .desktop, .name = "Desktop", .fallback = "Desktop" },
        .{ .key = "XDG_DOWNLOAD_DIR", .special = .downloads, .name = "Downloads", .fallback = "Downloads" },
        .{ .key = "XDG_DOCUMENTS_DIR", .special = .documents, .name = "Documents", .fallback = "Documents" },
        .{ .key = "XDG_PICTURES_DIR", .special = .pictures, .name = "Pictures", .fallback = "Pictures" },
        .{ .key = "XDG_MUSIC_DIR", .special = .music, .name = "Music", .fallback = "Music" },
        .{ .key = "XDG_VIDEOS_DIR", .special = .videos, .name = "Videos", .fallback = "Videos" },
    };
    for (wanted) |w| {
        const path = userDir(a, text, w.key, self.home) orelse std.fmt.allocPrint(a, "{s}/{s}", .{ self.home, w.fallback }) catch continue;
        // One the file points at the home itself is no folder of its own.
        if (std.mem.eql(u8, path, self.home)) continue;
        self.user.append(a, .{ .name = w.name, .path = path, .special = w.special }) catch {};
    }
}

/// The path `key` names in `user-dirs.dirs`, `$HOME` put in.
pub fn userDir(a: std.mem.Allocator, text: []const u8, key: []const u8, home: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, key) or line.len <= key.len or line[key.len] != '=') continue;
        const value = std.mem.trim(u8, line[key.len + 1 ..], "\"");
        if (std.mem.startsWith(u8, value, "$HOME")) return std.fmt.allocPrint(a, "{s}{s}", .{ home, value[5..] }) catch null;
        return a.dupe(u8, value) catch null;
    }
    return null;
}

/// GTK's bookmarks: `file:///path optional name`, a line each.
fn readBookmarks(self: *Places, io: std.Io) void {
    const a = self.arena.allocator();
    var buffer: [512]u8 = undefined;
    const file = std.fmt.allocPrint(a, "{s}/gtk-3.0/bookmarks", .{self.configHome(&buffer)}) catch return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(64 << 10)) catch return;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const uri_end = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const uri = line[0..uri_end];
        if (!std.mem.startsWith(u8, uri, "file://")) continue;
        const path = unescape(a, uri["file://".len..]) orelse continue;
        const name = if (uri_end < line.len) std.mem.trim(u8, line[uri_end + 1 ..], " ") else std.fs.path.basename(path);
        self.pinned.append(a, .{ .name = name, .path = path }) catch {};
    }
}

/// `%20` and the rest, as a URI has them.
pub fn unescape(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var out = a.alloc(u8, text.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '%' and i + 2 < text.len) {
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

/// What `/proc/self/mountinfo` says is mounted that a person keeps files
/// on: the root, and what is under `/run/media`, `/media`, `/mnt` and
/// `/home`.
fn readDrives(self: *Places, io: std.Io) void {
    const a = self.arena.allocator();
    _ = io;
    // procfs says nought of a file's size: read until it ends.
    const text = readAll(a, "/proc/self/mountinfo") orelse return;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // id parent major:minor root mount options ... - type source superoptions
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        _ = fields.next();
        _ = fields.next();
        _ = fields.next();
        const root = fields.next() orelse continue;
        const mount = unescapeOctal(a, fields.next() orelse continue) orelse continue;
        const dash = std.mem.indexOf(u8, line, " - ") orelse continue;
        var tail = std.mem.tokenizeScalar(u8, line[dash + 3 ..], ' ');
        const fstype = tail.next() orelse continue;
        const source = tail.next() orelse continue;
        if (!std.mem.startsWith(u8, source, "/dev/")) continue;
        const wanted = std.mem.eql(u8, mount, "/") or std.mem.eql(u8, mount, "/home") or
            std.mem.startsWith(u8, mount, "/run/media/") or std.mem.startsWith(u8, mount, "/media/") or std.mem.startsWith(u8, mount, "/mnt/");
        if (!wanted) continue;
        // A subvolume of a drive already listed - btrfs' /home on Fedora -
        // is the same drive.
        if (!std.mem.eql(u8, root, "/") and fstype.len > 0) {
            var seen = false;
            for (self.drives.items) |d| if (std.mem.eql(u8, d.device, source)) {
                seen = true;
            };
            if (seen) continue;
        }
        var drive: Drive = .{
            .label = if (std.mem.eql(u8, mount, "/")) "Local Disk" else std.fs.path.basename(mount),
            .mount = mount,
            .device = a.dupe(u8, source) catch continue,
            .removable = std.mem.startsWith(u8, mount, "/run/media/") or std.mem.startsWith(u8, mount, "/media/"),
        };
        if (labelOf(a, source)) |label| drive.label = label;
        var vfs: Statvfs = undefined;
        var mount_z: [512]u8 = undefined;
        if (mount.len < mount_z.len) {
            @memcpy(mount_z[0..mount.len], mount);
            mount_z[mount.len] = 0;
            if (statvfs(@ptrCast(&mount_z), &vfs) == 0) {
                drive.size = vfs.blocks * vfs.frsize;
                drive.free = vfs.bavail * vfs.frsize;
            }
        }
        self.drives.append(a, drive) catch {};
    }
}

/// libc's `struct statvfs`, as glibc lays it out on 64-bit Linux.
const Statvfs = extern struct {
    bsize: c_ulong,
    frsize: c_ulong,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    favail: u64,
    fsid: c_ulong,
    flag: c_ulong,
    namemax: c_ulong,
    spare: [6]c_int,
};
extern fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

/// The filesystem's label, from `/dev/disk/by-label`: the link there that
/// points at `device`.
fn labelOf(a: std.mem.Allocator, device: []const u8) ?[]const u8 {
    const dir = std.c.opendir("/dev/disk/by-label") orelse return null;
    defer _ = std.c.closedir(dir);
    const dev_name = std.fs.path.basename(device);
    while (std.c.readdir(dir)) |entry| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
        if (name[0] == '.') continue;
        var link_buffer: [512]u8 = undefined;
        const link = std.fmt.bufPrintZ(&link_buffer, "/dev/disk/by-label/{s}", .{name}) catch continue;
        var target_buffer: [256]u8 = undefined;
        const n = std.c.readlink(link.ptr, &target_buffer, target_buffer.len);
        if (n <= 0) continue;
        if (!std.mem.eql(u8, std.fs.path.basename(target_buffer[0..@intCast(n)]), dev_name)) continue;
        return unescapeHex(a, name);
    }
    return null;
}

/// A whole file read with read(2) until it ends: procfs's.
fn readAll(a: std.mem.Allocator, path: [*:0]const u8) ?[]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buffer: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buffer, buffer.len);
        if (n <= 0) break;
        out.appendSlice(a, buffer[0..@intCast(n)]) catch return null;
    }
    return out.items;
}

/// `\040` and the like, as mountinfo writes a space.
fn unescapeOctal(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var out = a.alloc(u8, text.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        // A backslash and three octal digits.
        if (text[i] == '\\' and i + 4 <= text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 4], 8)) |byte| {
                out[n] = byte;
                n += 1;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = text[i];
        n += 1;
    }
    return out[0..n];
}

/// `\x20` and the like, as udev writes a label's space.
fn unescapeHex(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    var out = a.alloc(u8, text.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 3 < text.len and text[i + 1] == 'x') {
            if (std.fmt.parseInt(u8, text[i + 2 .. i + 4], 16)) |byte| {
                out[n] = byte;
                n += 1;
                i += 3;
                continue;
            } else |_| {}
        }
        out[n] = text[i];
        n += 1;
    }
    return out[0..n];
}

/// The user folder that `path` is, if it is one.
pub fn specialOf(self: *const Places, path: []const u8) ?Special {
    for (self.user.items) |f| if (std.mem.eql(u8, f.path, path)) return f.special;
    return null;
}

test "user-dirs.dirs is read as xdg-user-dirs writes it" {
    const a = std.testing.allocator;
    const text = "# comment\nXDG_DESKTOP_DIR=\"$HOME/Asztal\"\nXDG_MUSIC_DIR=\"/data/music\"\n";
    const desktop = userDir(a, text, "XDG_DESKTOP_DIR", "/home/k").?;
    defer a.free(desktop);
    try std.testing.expectEqualStrings("/home/k/Asztal", desktop);
    const music = userDir(a, text, "XDG_MUSIC_DIR", "/home/k").?;
    defer a.free(music);
    try std.testing.expectEqualStrings("/data/music", music);
    try std.testing.expect(userDir(a, text, "XDG_VIDEOS_DIR", "/home/k") == null);
}

test "escapes in mount points and bookmarks are undone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("/run/media/k/My Disk", unescapeOctal(a, "/run/media/k/My\\040Disk").?);
    try std.testing.expectEqualStrings("/home/k/My Files", unescape(a, "/home/k/My%20Files").?);
    try std.testing.expectEqualStrings("My Disk", unescapeHex(a, "My\\x20Disk").?);
}
