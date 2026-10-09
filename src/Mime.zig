// SPDX-License-Identifier: BSD-2-Clause

//! What kind a file is, as the system's own table says: shared-mime-info's
//! `globs2` - by its name - read once from each data directory, with the
//! icon to show for each kind (`generic-icons`, and the kind's own icon
//! name) and the words the Type column says (the kind's `<comment>`).
//!
//! A name with no kind its table knows is guessed from what is in the file
//! - text, or not - as Windows says "File" of what it does not know, with
//! its extension in capitals ("XYZ File").

const std = @import("std");

const Mime = @This();

const log = std.log.scoped(.mime);

arena: std.heap.ArenaAllocator,
io: std.Io,
/// `*.ext` patterns, by the extension in lower case - the commonest kind.
extensions: std.StringHashMapUnmanaged(Glob) = .empty,
/// Whole names ("Makefile") and the rest ("*.so.[0-9]*", "README*").
others: std.ArrayList(Pattern) = .empty,
/// The icon a kind falls back to: "image-x-generic" for "image/png".
generic: std.StringHashMapUnmanaged([]const u8) = .empty,
/// One name for another: "application/acrobat" is "application/pdf".
aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
/// The words for a kind, read when first asked: "PDF document".
comments: std.StringHashMapUnmanaged([]const u8) = .empty,
data_dirs: std.ArrayList([]const u8) = .empty,

const Glob = struct { mime: []const u8, weight: u16, case_sensitive: bool = false };
const Pattern = struct { glob: []const u8, mime: []const u8, weight: u16, case_sensitive: bool };

pub const directory = "inode/directory";
pub const symlink = "inode/symlink";
pub const text = "text/plain";
pub const unknown = "application/octet-stream";
pub const executable = "application/x-executable";

pub fn load(gpa: std.mem.Allocator, io: std.Io) Mime {
    var self: Mime = .{ .arena = .init(gpa), .io = io };
    const a = self.arena.allocator();
    // The user's own first, then the system's, as XDG_DATA_DIRS orders them.
    if (std.c.getenv("XDG_DATA_HOME")) |d| {
        self.data_dirs.append(a, a.dupe(u8, std.mem.span(d)) catch "") catch {};
    } else if (std.c.getenv("HOME")) |home| {
        self.data_dirs.append(a, std.fmt.allocPrint(a, "{s}/.local/share", .{std.mem.span(home)}) catch "") catch {};
    }
    const dirs = if (std.c.getenv("XDG_DATA_DIRS")) |d| std.mem.span(d) else "/usr/local/share:/usr/share";
    var it = std.mem.tokenizeScalar(u8, dirs, ':');
    while (it.next()) |dir| self.data_dirs.append(a, a.dupe(u8, dir) catch continue) catch {};
    for (self.data_dirs.items) |dir| self.readDir(dir);
    return self;
}

pub fn deinit(self: *Mime) void {
    self.arena.deinit();
}

fn readFile(self: *Mime, dir: []const u8, name: []const u8) ?[]const u8 {
    const a = self.arena.allocator();
    const file = std.fmt.allocPrint(a, "{s}/mime/{s}", .{ dir, name }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(self.io, file, a, .limited(16 << 20)) catch null;
}

fn readDir(self: *Mime, dir: []const u8) void {
    const a = self.arena.allocator();
    if (self.readFile(dir, "globs2")) |globs| self.parseGlobs(globs);
    if (self.readFile(dir, "generic-icons")) |icons| {
        var lines = std.mem.tokenizeScalar(u8, icons, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const got = self.generic.getOrPut(a, line[0..colon]) catch continue;
            if (!got.found_existing) got.value_ptr.* = line[colon + 1 ..];
        }
    }
    if (self.readFile(dir, "aliases")) |aliases| {
        var lines = std.mem.tokenizeScalar(u8, aliases, '\n');
        while (lines.next()) |line| {
            const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
            const got = self.aliases.getOrPut(a, line[0..space]) catch continue;
            if (!got.found_existing) got.value_ptr.* = line[space + 1 ..];
        }
    }
}

/// `weight:type:glob[:flags]`, a line each.
pub fn parseGlobs(self: *Mime, globs: []const u8) void {
    const a = self.arena.allocator();
    var lines = std.mem.tokenizeScalar(u8, globs, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var parts = std.mem.splitScalar(u8, line, ':');
        const weight = std.fmt.parseInt(u16, parts.next() orelse continue, 10) catch continue;
        const mime = parts.next() orelse continue;
        const glob = parts.next() orelse continue;
        const flags = parts.next() orelse "";
        const cs = std.mem.indexOf(u8, flags, "cs") != null;
        // `*.ext` with nothing special in the extension: by the extension.
        if (std.mem.startsWith(u8, glob, "*.") and std.mem.indexOfAny(u8, glob[2..], "*?[") == null) {
            const ext = if (cs) glob[2..] else lower(a, glob[2..]) orelse continue;
            const got = self.extensions.getOrPut(a, ext) catch continue;
            // The first seen - the user's own, then the heaviest - stays.
            if (!got.found_existing or got.value_ptr.weight < weight) got.value_ptr.* = .{ .mime = mime, .weight = weight, .case_sensitive = cs };
            continue;
        }
        self.others.append(a, .{ .glob = glob, .mime = mime, .weight = weight, .case_sensitive = cs }) catch {};
    }
}

fn lower(a: std.mem.Allocator, s: []const u8) ?[]const u8 {
    const out = a.alloc(u8, s.len) catch return null;
    for (s, out) |c, *o| o.* = std.ascii.toLower(c);
    return out;
}

/// The kind a file named `name` is, by its name alone; null for one the
/// table does not know.
pub fn byName(self: *const Mime, name: []const u8) ?[]const u8 {
    // Whole names and patterns first where they weigh more: "Makefile",
    // "*.so.1".
    var best: ?Pattern = null;
    for (self.others.items) |p| {
        if (!globMatch(p.glob, name, p.case_sensitive)) continue;
        if (best == null or p.weight > best.?.weight or (p.weight == best.?.weight and p.glob.len > best.?.glob.len)) best = p;
    }
    // Then the longest extension first: "a.tar.gz" is a tar.gz before a gz.
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, name, i, '.')) |dot| : (i = dot + 1) {
        if (dot + 1 >= name.len) break;
        const ext = name[dot + 1 ..];
        var lower_buffer: [64]u8 = undefined;
        if (ext.len > lower_buffer.len) continue;
        for (ext, lower_buffer[0..ext.len]) |c, *o| o.* = std.ascii.toLower(c);
        // As written first - a case-sensitive one is kept so - then in
        // lower case, which a case-sensitive one is not to match.
        const found = self.extensions.get(ext) orelse blk: {
            const folded = self.extensions.get(lower_buffer[0..ext.len]) orelse continue;
            if (folded.case_sensitive) continue;
            break :blk folded;
        };
        if (best) |b| if (b.weight > found.weight) return b.mime;
        return found.mime;
    }
    return if (best) |b| b.mime else null;
}

/// A glob's `*`, `?` and `[...]`, as fnmatch has them.
pub fn globMatch(glob: []const u8, name: []const u8, case_sensitive: bool) bool {
    var g: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (g < glob.len and glob[g] == '*') {
            star = g;
            mark = n;
            g += 1;
            continue;
        }
        if (g < glob.len and glob[g] == '[') {
            if (std.mem.indexOfScalarPos(u8, glob, g + 1, ']')) |end| {
                const set = glob[g + 1 .. end];
                if (inSet(set, name[n], case_sensitive)) {
                    g = end + 1;
                    n += 1;
                    continue;
                }
            }
        } else if (g < glob.len and (glob[g] == '?' or same(glob[g], name[n], case_sensitive))) {
            g += 1;
            n += 1;
            continue;
        }
        const s = star orelse return false;
        g = s + 1;
        mark += 1;
        n = mark;
    }
    while (g < glob.len and glob[g] == '*') g += 1;
    return g == glob.len;
}

fn same(a: u8, b: u8, case_sensitive: bool) bool {
    return if (case_sensitive) a == b else std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn inSet(set: []const u8, c: u8, case_sensitive: bool) bool {
    var i: usize = 0;
    while (i < set.len) : (i += 1) {
        if (i + 2 < set.len and set[i + 1] == '-') {
            const lo = set[i];
            const hi = set[i + 2];
            const x = if (case_sensitive) c else std.ascii.toLower(c);
            if (x >= lo and x <= hi) return true;
            i += 2;
            continue;
        }
        if (same(set[i], c, case_sensitive)) return true;
    }
    return false;
}

/// The kind of a file the table does not know by name: what is in its
/// first bytes says text or not.
pub fn byContent(head: []const u8, exec: bool) []const u8 {
    if (std.mem.startsWith(u8, head, "\x7fELF")) return executable;
    if (std.mem.startsWith(u8, head, "#!")) return "application/x-shellscript";
    if (std.mem.startsWith(u8, head, "%PDF-")) return "application/pdf";
    if (std.mem.startsWith(u8, head, "\x89PNG")) return "image/png";
    if (std.mem.startsWith(u8, head, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, head, "PK\x03\x04")) return "application/zip";
    if (std.mem.indexOfScalar(u8, head, 0) != null) return if (exec) executable else unknown;
    return text;
}

/// The kind under another name it is known by.
pub fn unalias(self: *const Mime, mime: []const u8) []const u8 {
    return self.aliases.get(mime) orelse mime;
}

/// The icon names to look for, best first: the kind's own ("image-png"),
/// then its generic one ("image-x-generic"), then by its media.
pub fn iconNames(self: *const Mime, mime: []const u8, buffer: *[3][128]u8) [3][]const u8 {
    var out: [3][]const u8 = .{ "", "", "" };
    const own = std.fmt.bufPrint(&buffer[0], "{s}", .{mime}) catch "";
    for (buffer[0][0..own.len]) |*c| {
        if (c.* == '/') c.* = '-';
    }
    out[0] = own;
    out[1] = self.generic.get(mime) orelse "";
    const slash = std.mem.indexOfScalar(u8, mime, '/') orelse mime.len;
    const media = mime[0..slash];
    out[2] = std.fmt.bufPrint(&buffer[2], "{s}", .{if (std.mem.eql(u8, media, "image"))
        "image-x-generic"
    else if (std.mem.eql(u8, media, "audio"))
        "audio-x-generic"
    else if (std.mem.eql(u8, media, "video"))
        "video-x-generic"
    else if (std.mem.eql(u8, media, "text"))
        "text-x-generic"
    else if (std.mem.eql(u8, mime, executable))
        "application-x-executable"
    else
        "text-x-generic"}) catch "";
    return out;
}

/// What the Type column says of a kind: the table's words for it, or -
/// for one it has none for - Windows' "XYZ File" by the extension.
pub fn describe(self: *Mime, mime: []const u8, name: []const u8, buffer: []u8) []const u8 {
    if (std.mem.eql(u8, mime, directory)) return "File folder";
    if (self.comments.get(mime)) |words| return words;
    if (!std.mem.eql(u8, mime, unknown)) if (self.readComment(mime)) |words| {
        self.comments.put(self.arena.allocator(), mime, words) catch {};
        return words;
    };
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "File";
    if (dot == 0 or dot + 1 >= name.len) return "File";
    const ext = name[dot + 1 ..];
    if (ext.len + 5 > buffer.len) return "File";
    for (ext, buffer[0..ext.len]) |c, *o| o.* = std.ascii.toUpper(c);
    @memcpy(buffer[ext.len .. ext.len + 5], " File");
    return buffer[0 .. ext.len + 5];
}

/// The `<comment>` with no language in `mime/<kind>.xml`.
fn readComment(self: *Mime, mime: []const u8) ?[]const u8 {
    const a = self.arena.allocator();
    for (self.data_dirs.items) |dir| {
        const file = std.fmt.allocPrint(a, "{s}/mime/{s}.xml", .{ dir, mime }) catch continue;
        var buffer: [8192]u8 = undefined;
        const xml = std.Io.Dir.cwd().readFile(self.io, file, &buffer) catch continue;
        const open = "<comment>";
        const at = std.mem.indexOf(u8, xml, open) orelse continue;
        const end = std.mem.indexOfPos(u8, xml, at, "</comment>") orelse continue;
        return a.dupe(u8, xml[at + open.len .. end]) catch null;
    }
    return null;
}

test "globs are matched as fnmatch does" {
    try std.testing.expect(globMatch("*.so.[0-9]*", "libfoo.so.1", true));
    try std.testing.expect(globMatch("README*", "readme.md", false));
    try std.testing.expect(!globMatch("README*", "readme.md", true));
    try std.testing.expect(globMatch("Makefile", "Makefile", true));
    try std.testing.expect(!globMatch("*.c", "a.cc", true));
}

test "the longest extension wins, then the weight" {
    var mime: Mime = .{ .arena = .init(std.testing.allocator), .io = std.testing.io };
    defer mime.deinit();
    mime.parseGlobs("50:application/gzip:*.gz\n50:application/x-compressed-tar:*.tar.gz\n50:text/x-makefile:makefile\n50:text/x-c:*.c:cs\n");
    try std.testing.expectEqualStrings("application/x-compressed-tar", mime.byName("a.tar.gz").?);
    try std.testing.expectEqualStrings("application/gzip", mime.byName("a.gz").?);
    try std.testing.expectEqualStrings("application/gzip", mime.byName("A.GZ").?);
    try std.testing.expectEqualStrings("text/x-makefile", mime.byName("makefile").?);
    try std.testing.expect(mime.byName("noext") == null);
}

test "unknown kinds are described by their extension" {
    var mime: Mime = .{ .arena = .init(std.testing.allocator), .io = std.testing.io };
    defer mime.deinit();
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("XYZ File", mime.describe(unknown, "a.xyz", &buffer));
    try std.testing.expectEqualStrings("File", mime.describe(unknown, "noext", &buffer));
    try std.testing.expectEqualStrings("File folder", mime.describe(directory, "Docs", &buffer));
}
