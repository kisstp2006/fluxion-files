// SPDX-License-Identifier: BSD-2-Clause

//! Search, as the box in the address row asks for it: every file and
//! folder under the folder shown that the query takes - walked on a thread
//! of its own, the findings handed to the window as they come, so the list
//! fills while it searches and the window never waits.
//!
//! **The query is Windows'**: words that are in the name, case aside, and
//! Advanced Query Syntax for the rest - what the ribbon's Search Tools and
//! Windows 11's "Search options" write into the box:
//!
//! | Typed | Takes |
//! | --- | --- |
//! | `kind:picture`, `kind:=document` | pictures, documents, music, videos, folders, programs, compressed folders |
//! | `datemodified:this week` | changed today, yesterday, this or last week, month or year |
//! | `size:large` | Windows' sizes: empty, tiny, small, medium, large, huge, gigantic |
//! | `ext:.pdf`, `type:pdf` | named so |
//! | `content:"invoice"` | with those words in it |
//!
//! Folder Options decides the rest: whether what is in the files is
//! searched too, whether compressed folders are looked into, and whether
//! hidden and system folders are.
//!
//! The same walk finds Windows 11's Gallery its photos: pictures and
//! videos under the folders of its collection, each picture's size read
//! from its first bytes for the photos' rows.

const std = @import("std");

const Mime = @import("Mime.zig");
const Archive = @import("Archive.zig");

const Search = @This();

const log = std.log.scoped(.search);

/// How many findings before it stops: enough for any list a person reads.
const most = 5000;

pub const Kind = enum { any, folder, document, picture, video, music, archive, program, media };
pub const When = enum { any, today, yesterday, this_week, last_week, this_month, last_month, this_year, last_year };
pub const Size = enum { any, empty, tiny, small, medium, large, huge, gigantic };

/// What is searched for, read from what was typed.
pub const Query = struct {
    /// The words: all of them in the name - or, with `contents`, in the
    /// name or what is in the file.
    words: [8][]const u8 = undefined,
    word_count: usize = 0,
    kind: Kind = .any,
    when: When = .any,
    size: Size = .any,
    extension: []const u8 = "",
    /// Words that must be in what is in the file: `content:`.
    content: []const u8 = "",
    contents: bool = false,
    archives: bool = false,
    system: bool = false,
    /// Each picture's size read, for the Gallery's rows.
    measure: bool = false,

    pub fn wordList(self: *const Query) []const []const u8 {
        return self.words[0..self.word_count];
    }

    /// Read from what was typed into the search box.
    pub fn parse(text: []const u8) Query {
        var q: Query = .{};
        var i: usize = 0;
        while (i < text.len) {
            while (i < text.len and text[i] == ' ') i += 1;
            if (i >= text.len) break;
            const from = i;
            var quoted = false;
            while (i < text.len and (quoted or text[i] != ' ')) : (i += 1) {
                if (text[i] == '"') quoted = !quoted;
            }
            const word = text[from..i];
            if (std.mem.indexOfScalar(u8, word, ':')) |colon| {
                const name = word[0..colon];
                var value = std.mem.trimStart(u8, word[colon + 1 ..], "=");
                value = std.mem.trim(u8, value, "\"");
                if (std.ascii.eqlIgnoreCase(name, "datemodified") or std.ascii.eqlIgnoreCase(name, "date") or std.ascii.eqlIgnoreCase(name, "modified")) {
                    // "this week", "last month": two words, the second next.
                    var whole = value;
                    if (std.ascii.eqlIgnoreCase(value, "this") or std.ascii.eqlIgnoreCase(value, "last")) {
                        var j = i;
                        while (j < text.len and text[j] == ' ') j += 1;
                        var end = j;
                        while (end < text.len and text[end] != ' ') end += 1;
                        whole = std.mem.trim(u8, text[from + colon + 1 .. end], " \"=");
                        i = end;
                    }
                    q.when = whenOf(whole);
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(name, "kind")) {
                    q.kind = kindOf(value);
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(name, "size")) {
                    q.size = std.meta.stringToEnum(Size, value) orelse .any;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(name, "ext") or std.ascii.eqlIgnoreCase(name, "type") or std.ascii.eqlIgnoreCase(name, "fileextension")) {
                    q.extension = std.mem.trimStart(u8, value, ".*");
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(name, "content")) {
                    q.content = value;
                    continue;
                }
            }
            if (q.word_count < q.words.len) {
                q.words[q.word_count] = std.mem.trim(u8, word, "\"");
                q.word_count += 1;
            }
        }
        return q;
    }

    fn whenOf(text: []const u8) When {
        const pairs = [_]struct { []const u8, When }{
            .{ "today", .today },
            .{ "yesterday", .yesterday },
            .{ "this week", .this_week },
            .{ "last week", .last_week },
            .{ "this month", .this_month },
            .{ "last month", .last_month },
            .{ "this year", .this_year },
            .{ "last year", .last_year },
        };
        for (pairs) |p| if (std.ascii.eqlIgnoreCase(text, p[0])) return p[1];
        return .any;
    }

    fn kindOf(text: []const u8) Kind {
        const pairs = [_]struct { []const u8, Kind }{
            .{ "folder", .folder },   .{ "document", .document }, .{ "picture", .picture },
            .{ "video", .video },     .{ "movie", .video },       .{ "music", .music },
            .{ "program", .program }, .{ "archive", .archive },   .{ "compressed", .archive },
        };
        for (pairs) |p| if (std.ascii.eqlIgnoreCase(text, p[0])) return p[1];
        return .any;
    }
};

/// A finding: where it is, and - a picture, measured - its size.
pub const Found = struct { path: []u8, size: [2]u16 = .{ 0, 0 } };

gpa: std.mem.Allocator,
io: std.Io,
/// The window's pipe: a byte written wakes it to take what was found.
wake: std.c.fd_t,
mime: ?*const Mime = null,
job: ?*Job = null,

const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    wake: std.c.fd_t,
    mime: ?*const Mime,
    arena: std.heap.ArenaAllocator,
    roots: []const []const u8,
    query: Query,
    mutex: std.Io.Mutex = .init,
    found: std.ArrayList(Found) = .empty,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,
    count: usize = 0,
    since_wake: usize = 0,
    today: i64 = 0,

    fn run(job: *Job) void {
        defer {
            job.done.store(true, .release);
            _ = std.c.write(job.wake, "s", 1);
        }
        const now = realNow();
        job.today = now - @mod(now + localOffset(now), 86400);
        var stack: std.ArrayList([]u8) = .empty;
        defer {
            for (stack.items) |p| job.gpa.free(p);
            stack.deinit(job.gpa);
        }
        for (job.roots) |root| stack.append(job.gpa, job.gpa.dupe(u8, root) catch return) catch return;
        while (stack.pop()) |dir_path| {
            defer job.gpa.free(dir_path);
            if (job.cancel.load(.acquire)) return;
            var dir = std.Io.Dir.cwd().openDir(job.io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(job.io);
            var it = dir.iterate();
            while (it.next(job.io) catch null) |entry| {
                if (job.cancel.load(.acquire)) return;
                // Hidden and system folders only with Folder Options' say.
                if (entry.name[0] == '.' and !job.query.system) continue;
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ if (std.mem.eql(u8, dir_path, "/")) "" else dir_path, entry.name }) catch continue;
                const folder = entry.kind == .directory;
                if (job.takes(dir, entry.name, full, folder)) |size| {
                    if (!job.add(full, size)) return;
                }
                if (folder) {
                    if (!job.query.system and isSystem(full)) continue;
                    stack.append(job.gpa, job.gpa.dupe(u8, full) catch continue) catch {};
                } else if (job.query.archives and Archive.named(entry.name)) {
                    if (!job.searchArchive(full)) return;
                }
            }
        }
    }

    /// A finding into the list - false once there are enough.
    fn add(job: *Job, full: []const u8, size: [2]u16) bool {
        const copy = job.gpa.dupe(u8, full) catch return true;
        job.mutex.lockUncancelable(job.io);
        job.found.append(job.gpa, .{ .path = copy, .size = size }) catch job.gpa.free(copy);
        job.mutex.unlock(job.io);
        job.count += 1;
        job.since_wake += 1;
        if (job.count >= most) return false;
        // Told in batches: a byte a few dozen findings.
        if (job.since_wake >= 32) {
            job.since_wake = 0;
            _ = std.c.write(job.wake, "s", 1);
        }
        return true;
    }

    /// Whether the query takes this entry - its picture's size, if so.
    fn takes(job: *Job, dir: std.Io.Dir, name: []const u8, full: []const u8, folder: bool) ?[2]u16 {
        const q = &job.query;
        const mime = if (folder) Mime.directory else if (job.mime) |m| m.byName(name) orelse Mime.unknown else Mime.unknown;
        if (!kindTakes(q.kind, mime, name, folder)) return null;
        if (q.extension.len > 0) {
            const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
            if (!std.ascii.eqlIgnoreCase(name[dot + 1 ..], q.extension)) return null;
        }
        // Every word in the name - or, with contents searched, in the file.
        var in_name = true;
        for (q.wordList()) |w| {
            if (!containsIgnoreCase(name, w)) in_name = false;
        }
        if (!in_name and !(q.contents and !folder and contains(job.io, full, q.wordList()))) return null;
        if (q.content.len > 0 and (folder or !contains(job.io, full, &.{q.content}))) return null;
        if (q.when != .any or q.size != .any) {
            const stat = dir.statFile(job.io, name, .{}) catch return null;
            if (q.size != .any and (folder or !sizeTakes(q.size, stat.size))) return null;
            if (q.when != .any and !job.whenTakes(@intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)))) return null;
        }
        if (q.measure and std.mem.startsWith(u8, mime, "image/")) return pictureSize(job.io, full) orelse .{ 0, 0 };
        return .{ 0, 0 };
    }

    fn whenTakes(job: *const Job, t: i64) bool {
        const day = 86400;
        const today = job.today;
        return switch (job.query.when) {
            .any => true,
            .today => t >= today,
            .yesterday => t >= today - day and t < today,
            .this_week => t >= today - 6 * day,
            .last_week => t >= today - 13 * day and t < today - 6 * day,
            .this_month => t >= today - 30 * day,
            .last_month => t >= today - 60 * day and t < today - 30 * day,
            .this_year => t >= today - 365 * day,
            .last_year => t >= today - 730 * day and t < today - 365 * day,
        };
    }

    /// Inside a compressed folder: what in it the query takes, by name -
    /// each found as "photos.zip/2024/june.jpg", which Files opens.
    fn searchArchive(job: *Job, archive: []const u8) bool {
        if (job.query.word_count == 0) return true;
        var arena: std.heap.ArenaAllocator = .init(job.gpa);
        defer arena.deinit();
        var entries: std.ArrayList(Archive.Entry) = .empty;
        Archive.list(arena.allocator(), archive, &entries) catch return true;
        for (entries.items) |e| {
            const name = std.fs.path.basename(e.path);
            const mime = if (e.kind == .folder) Mime.directory else if (job.mime) |m| m.byName(name) orelse Mime.unknown else Mime.unknown;
            if (!kindTakes(job.query.kind, mime, name, e.kind == .folder)) continue;
            var all = true;
            for (job.query.wordList()) |w| if (!containsIgnoreCase(name, w)) {
                all = false;
            };
            if (!all) continue;
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ archive, e.path }) catch continue;
            if (!job.add(full, .{ 0, 0 })) return false;
        }
        return true;
    }

    fn finish(job: *Job) void {
        job.cancel.store(true, .release);
        job.thread.join();
        for (job.found.items) |f| job.gpa.free(f.path);
        job.found.deinit(job.gpa);
        job.arena.deinit();
        job.gpa.destroy(job);
    }
};

fn kindTakes(kind: Kind, mime: []const u8, name: []const u8, folder: bool) bool {
    const starts = std.mem.startsWith;
    const has = std.mem.indexOf;
    return switch (kind) {
        .any => true,
        .folder => folder,
        .picture => starts(u8, mime, "image/"),
        .video => starts(u8, mime, "video/"),
        .music => starts(u8, mime, "audio/"),
        .media => starts(u8, mime, "image/") or starts(u8, mime, "video/"),
        .archive => !folder and Archive.named(name),
        .program => std.mem.eql(u8, mime, "application/x-executable") or std.mem.eql(u8, mime, "application/x-desktop") or std.mem.eql(u8, mime, "application/x-shellscript") or std.mem.eql(u8, mime, "application/vnd.appimage"),
        .document => !folder and (starts(u8, mime, "text/") or std.mem.eql(u8, mime, "application/pdf") or has(u8, mime, "document") != null or has(u8, mime, "msword") != null or has(u8, mime, "spreadsheet") != null or has(u8, mime, "presentation") != null),
    };
}

/// Windows' sizes: Empty (0 KB), Tiny (0 - 16 KB), Small (16 KB - 1 MB),
/// Medium (1 - 128 MB), Large (128 MB - 1 GB), Huge (1 - 4 GB), Gigantic
/// (> 4 GB).
fn sizeTakes(size: Size, bytes: u64) bool {
    return switch (size) {
        .any => true,
        .empty => bytes == 0,
        .tiny => bytes > 0 and bytes < 16 << 10,
        .small => bytes >= 16 << 10 and bytes < 1 << 20,
        .medium => bytes >= 1 << 20 and bytes < 128 << 20,
        .large => bytes >= 128 << 20 and bytes < 1 << 30,
        .huge => bytes >= 1 << 30 and bytes < 4 << 30,
        .gigantic => bytes >= 4 << 30,
    };
}

/// The system's own folders, left out unless Folder Options says.
fn isSystem(path: []const u8) bool {
    const system = [_][]const u8{ "/proc", "/sys", "/dev", "/run", "/usr", "/etc", "/var", "/boot", "/lib", "/lib64", "/bin", "/sbin" };
    for (system) |s| if (std.mem.eql(u8, path, s)) return true;
    return false;
}

/// Whether every one of `words` is in the file's first megabyte, case
/// aside - a file that is text.
fn contains(io: std.Io, path: []const u8, words: []const []const u8) bool {
    if (words.len == 0) return false;
    const buffer = std.heap.page_allocator.alloc(u8, 1 << 20) catch return false;
    defer std.heap.page_allocator.free(buffer);
    const text = std.Io.Dir.cwd().readFile(io, path, buffer) catch return false;
    if (std.mem.indexOfScalar(u8, text[0..@min(text.len, 4096)], 0) != null) return false;
    for (words) |w| if (!containsIgnoreCase(text, w)) return false;
    return true;
}

/// A picture's size from its first bytes: a PNG's, a JPEG's, a GIF's, a
/// WebP's.
pub fn pictureSize(io: std.Io, path: []const u8) ?[2]u16 {
    var buffer: [64 << 10]u8 = undefined;
    const head = std.Io.Dir.cwd().readFile(io, path, &buffer) catch return null;
    return sizeFrom(head);
}

pub fn sizeFrom(head: []const u8) ?[2]u16 {
    const clampSize = struct {
        fn f(w: u32, h: u32) [2]u16 {
            return .{ @intCast(@min(w, 65535)), @intCast(@min(h, 65535)) };
        }
    }.f;
    if (head.len >= 24 and std.mem.eql(u8, head[0..8], "\x89PNG\r\n\x1a\n")) {
        return clampSize(std.mem.readInt(u32, head[16..20], .big), std.mem.readInt(u32, head[20..24], .big));
    }
    if (head.len >= 10 and (std.mem.eql(u8, head[0..6], "GIF87a") or std.mem.eql(u8, head[0..6], "GIF89a"))) {
        return clampSize(std.mem.readInt(u16, head[6..8], .little), std.mem.readInt(u16, head[8..10], .little));
    }
    if (head.len >= 30 and std.mem.eql(u8, head[0..4], "RIFF") and std.mem.eql(u8, head[8..12], "WEBP")) {
        const chunk = head[12..16];
        if (std.mem.eql(u8, chunk, "VP8X")) return clampSize(1 + (@as(u32, head[24]) | @as(u32, head[25]) << 8 | @as(u32, head[26]) << 16), 1 + (@as(u32, head[27]) | @as(u32, head[28]) << 8 | @as(u32, head[29]) << 16));
        if (std.mem.eql(u8, chunk, "VP8 ")) return clampSize(std.mem.readInt(u16, head[26..28], .little) & 0x3FFF, std.mem.readInt(u16, head[28..30], .little) & 0x3FFF);
        if (std.mem.eql(u8, chunk, "VP8L")) {
            const b = std.mem.readInt(u32, head[21..25], .little);
            return clampSize((b & 0x3FFF) + 1, ((b >> 14) & 0x3FFF) + 1);
        }
    }
    if (head.len >= 4 and head[0] == 0xFF and head[1] == 0xD8) {
        // A JPEG: its frame's header, past the others.
        var i: usize = 2;
        while (i + 9 < head.len) {
            if (head[i] != 0xFF) return null;
            const marker = head[i + 1];
            if (marker == 0xFF) {
                i += 1;
                continue;
            }
            const len = std.mem.readInt(u16, head[i + 2 ..][0..2], .big);
            const frame = (marker >= 0xC0 and marker <= 0xCF) and marker != 0xC4 and marker != 0xC8 and marker != 0xCC;
            if (frame) return clampSize(std.mem.readInt(u16, head[i + 7 ..][0..2], .big), std.mem.readInt(u16, head[i + 5 ..][0..2], .big));
            i += 2 + len;
        }
    }
    return null;
}

pub fn deinit(self: *Search) void {
    self.stop();
}

pub const Options = struct { contents: bool = false, archives: bool = false, system: bool = false };

/// Search `folder` for what `typed` asks, whatever was being searched
/// before let go.
pub fn start(self: *Search, folder: []const u8, typed: []const u8, options: Options) void {
    self.startQuery(&.{folder}, typed, .{ .contents = options.contents, .archives = options.archives, .system = options.system });
}

/// Walk `roots` for what `text` asks, with `extra`'s filters and options
/// besides.
pub fn startQuery(self: *Search, roots: []const []const u8, text: []const u8, extra: Query) void {
    self.stop();
    const job = self.gpa.create(Job) catch return;
    job.* = .{ .gpa = self.gpa, .io = self.io, .wake = self.wake, .mime = self.mime, .arena = .init(self.gpa), .roots = &.{}, .query = .{} };
    const a = job.arena.allocator();
    const owned_roots = a.alloc([]const u8, roots.len) catch return self.drop(job);
    for (roots, 0..) |r, i| owned_roots[i] = a.dupe(u8, r) catch return self.drop(job);
    job.roots = owned_roots;
    // The query's words point into the text: a copy of it, owned.
    const owned_text = a.dupe(u8, text) catch return self.drop(job);
    var q = Query.parse(owned_text);
    if (extra.kind != .any) q.kind = extra.kind;
    if (extra.when != .any) q.when = extra.when;
    if (extra.size != .any) q.size = extra.size;
    q.contents = extra.contents;
    q.archives = extra.archives;
    q.system = extra.system;
    q.measure = extra.measure;
    job.query = q;
    job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch return self.drop(job);
    self.job = job;
}

fn drop(self: *Search, job: *Job) void {
    job.arena.deinit();
    self.gpa.destroy(job);
}

pub fn stop(self: *Search) void {
    if (self.job) |job| job.finish();
    self.job = null;
}

/// Whether it is still looking.
pub fn running(self: *const Search) bool {
    const job = self.job orelse return false;
    return !job.done.load(.acquire);
}

/// What was found since asked last, handed over: the caller frees each
/// path.
pub fn take(self: *Search, out: *std.ArrayList(Found)) void {
    const job = self.job orelse return;
    job.mutex.lockUncancelable(job.io);
    defer job.mutex.unlock(job.io);
    out.appendSlice(self.gpa, job.found.items) catch {
        for (job.found.items) |f| self.gpa.free(f.path);
    };
    job.found.clearRetainingCapacity();
}

/// Whether `text` has `query` in it, ASCII letters' case aside.
pub fn containsIgnoreCase(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > text.len) return false;
    var i: usize = 0;
    while (i + query.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + query.len], query)) return true;
    }
    return false;
}

fn realNow() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
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

fn localOffset(now: i64) i64 {
    var tm: Tm = undefined;
    if (localtime_r(&now, &tm) == null) return 0;
    return tm.gmtoff;
}

test "names are found whatever their case" {
    try std.testing.expect(containsIgnoreCase("Report-2026.PDF", "report"));
    try std.testing.expect(containsIgnoreCase("notes.txt", "TES"));
    try std.testing.expect(!containsIgnoreCase("a.txt", "b"));
}

test "Windows' query syntax is read" {
    const q = Query.parse("invoice kind:=document size:large datemodified:this week ext:.pdf");
    try std.testing.expectEqual(@as(usize, 1), q.word_count);
    try std.testing.expectEqualStrings("invoice", q.words[0]);
    try std.testing.expectEqual(Kind.document, q.kind);
    try std.testing.expectEqual(Size.large, q.size);
    try std.testing.expectEqual(When.this_week, q.when);
    try std.testing.expectEqualStrings("pdf", q.extension);
    const r = Query.parse("datemodified:today notes content:\"call anna\"");
    try std.testing.expectEqual(When.today, r.when);
    try std.testing.expectEqualStrings("notes", r.words[0]);
    try std.testing.expectEqualStrings("call anna", r.content);
}

test "a picture's size is read from its first bytes" {
    const png = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 4, 0, 0, 0, 3, 0 };
    try std.testing.expectEqual([2]u16{ 1024, 768 }, sizeFrom(&png).?);
    const gif = "GIF89a\x40\x01\xF0\x00";
    try std.testing.expectEqual([2]u16{ 320, 240 }, sizeFrom(gif).?);
}

test "a folder's tree is searched on a thread" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/deep/er");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/deep/er/Target.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/other.txt", .data = "x" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    var search: Search = .{ .gpa = std.testing.allocator, .io = io, .wake = fds[1] };
    defer search.deinit();
    search.start(root, "target", .{});
    while (search.running()) std.Thread.yield() catch {};
    var found: std.ArrayList(Found) = .empty;
    defer {
        for (found.items) |f| std.testing.allocator.free(f.path);
        found.deinit(std.testing.allocator);
    }
    search.take(&found);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expect(std.mem.endsWith(u8, found.items[0].path, "a/deep/er/Target.txt"));
}
