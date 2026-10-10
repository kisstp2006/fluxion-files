// SPDX-License-Identifier: BSD-2-Clause

//! What Home - Windows 10's Quick access - shows of what was done lately:
//!
//! - **recent files**: the desktop's shared list,
//!   `$XDG_DATA_HOME/recently-used.xbel` - GTK's, Qt's and most apps' -
//!   which Files writes to as it opens a file, so the start menu's
//!   Recommended has it too;
//! - **frequent folders**: the folders gone to most, and lately - Files'
//!   own count, in `$XDG_STATE_HOME/fluxion/files-frequent`;
//! - **favorites**, Windows 11's: files starred with "Add to Favorites",
//!   in `$XDG_STATE_HOME/fluxion/files-favorites`.
//!
//! A file taken off Recent is kept off it in `fluxion/recent-hidden`, the
//! list the start menu keeps too - what is taken off one is off both, and
//! no app's own list is written over. Folder Options' Clear takes every
//! recent file off, and forgets the folders.

const std = @import("std");

const History = @This();

const log = std.log.scoped(.history);

pub const File = struct {
    path: []const u8,
    name: []const u8,
    mime: []const u8,
    /// When it was last opened, in seconds since the epoch.
    when: i64,
};

pub const Frequent = struct {
    path: []const u8,
    count: u32,
    /// When it was last gone to, in seconds since the epoch.
    last: i64,

    /// Gone to often and lately: each visit worth less as it ages, half
    /// as much a week on.
    fn score(self: Frequent, now: i64) f64 {
        const weeks = @as(f64, @floatFromInt(@max(0, now - self.last))) / (7 * 86400);
        return @as(f64, @floatFromInt(self.count)) / std.math.pow(f64, 2, weeks);
    }
};

/// The most recent files listed, and frequent folders.
pub const most_recent = 20;
pub const most_frequent = 10;

gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
recent: []File = &.{},
frequent: std.ArrayList(Frequent) = .empty,
favorites: std.ArrayList([]const u8) = .empty,
hidden: std.ArrayList([]const u8) = .empty,
/// What was searched for lately, the newest first: Windows 10's Recent
/// searches.
searches: std.ArrayList([]const u8) = .empty,
/// The Gallery's collection: the folders its photos come from. None
/// written, the person's Pictures.
collection: std.ArrayList([]const u8) = .empty,
/// When the lists were read last: read again a few seconds later.
read_ms: i64 = 0,

pub fn init(gpa: std.mem.Allocator) History {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

pub fn deinit(self: *History) void {
    self.arena.deinit();
}

/// The lists read again, if a few seconds have gone: Home asks each time
/// it is drawn.
pub fn refresh(self: *History, io: std.Io) void {
    const now = monotonicMs();
    if (self.read_ms != 0 and now - self.read_ms < 3000) return;
    self.read_ms = now;
    _ = self.arena.reset(.retain_capacity);
    self.recent = &.{};
    self.frequent = .empty;
    self.favorites = .empty;
    self.hidden = .empty;
    self.searches = .empty;
    self.collection = .empty;
    const a = self.arena.allocator();
    readLines(io, a, "fluxion/recent-hidden", &self.hidden);
    readLines(io, a, "fluxion/files-favorites", &self.favorites);
    readLines(io, a, "fluxion/files-searches", &self.searches);
    readLines(io, a, "fluxion/files-gallery", &self.collection);
    self.readFrequent(io);
    self.readRecent(io);
}

/// Read again at the next drawing.
pub fn stale(self: *History) void {
    self.read_ms = 0;
}

fn readLines(io: std.Io, a: std.mem.Allocator, name: []const u8, out: *std.ArrayList([]const u8)) void {
    var buffer: [512]u8 = undefined;
    const file = statePath(&buffer, name) orelse return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch return;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| out.append(a, line) catch return;
}

fn readFrequent(self: *History, io: std.Io) void {
    const a = self.arena.allocator();
    var buffer: [512]u8 = undefined;
    const file = statePath(&buffer, "fluxion/files-frequent") orelse return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch return;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, '\t');
        const count = std.fmt.parseInt(u32, parts.next() orelse continue, 10) catch continue;
        const last = std.fmt.parseInt(i64, parts.next() orelse continue, 10) catch continue;
        const path = parts.rest();
        if (path.len == 0) continue;
        self.frequent.append(a, .{ .path = path, .count = count, .last = last }) catch return;
    }
}

fn readRecent(self: *History, io: std.Io) void {
    const a = self.arena.allocator();
    var path_buffer: [512]u8 = undefined;
    const file = dataPath(&path_buffer, "recently-used.xbel") orelse return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(8 << 20)) catch return;
    var found: std.ArrayList(File) = .empty;
    parse(a, text, &found);
    std.mem.sort(File, found.items, {}, struct {
        fn newer(_: void, x: File, y: File) bool {
            return x.when > y.when;
        }
    }.newer);
    var kept: std.ArrayList(File) = .empty;
    for (found.items) |f| {
        if (kept.items.len == most_recent) break;
        if (self.isHidden(f.path)) continue;
        const seen = for (kept.items) |k| {
            if (std.mem.eql(u8, k.path, f.path)) break true;
        } else false;
        if (seen) continue;
        var z_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&z_buffer, "{s}", .{f.path}) catch continue;
        if (std.c.access(z.ptr, std.c.F_OK) != 0) continue;
        kept.append(a, f) catch break;
    }
    self.recent = kept.items;
}

fn isHidden(self: *const History, path: []const u8) bool {
    for (self.hidden.items) |h| if (std.mem.eql(u8, h, path)) return true;
    return false;
}

/// The frequent folders, best first - but not the ones Home shows anyway.
pub fn topFolders(self: *const History, out: []Frequent, skip: *const fn (context: *const anyopaque, path: []const u8) bool, context: *const anyopaque) []Frequent {
    const now = realNow();
    var list: [256]Frequent = undefined;
    var n: usize = 0;
    for (self.frequent.items) |f| {
        if (n == list.len) break;
        if (skip(context, f.path)) continue;
        var z_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const z = std.fmt.bufPrintZ(&z_buffer, "{s}", .{f.path}) catch continue;
        if (std.c.access(z.ptr, std.c.F_OK) != 0) continue;
        list[n] = f;
        n += 1;
    }
    const Context = struct {
        now: i64,
        fn better(c: @This(), x: Frequent, y: Frequent) bool {
            return x.score(c.now) > y.score(c.now);
        }
    };
    std.mem.sort(Frequent, list[0..n], Context{ .now = now }, Context.better);
    const k = @min(n, out.len);
    @memcpy(out[0..k], list[0..k]);
    return out[0..k];
}

pub fn isFavorite(self: *const History, path: []const u8) bool {
    for (self.favorites.items) |f| if (std.mem.eql(u8, f, path)) return true;
    return false;
}

// -------------------------------------------------------------------------
// Written down
// -------------------------------------------------------------------------

/// The folder `path` gone to: counted.
pub fn visited(self: *History, io: std.Io, path: []const u8) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var buffer: [512]u8 = undefined;
    const file = statePath(&buffer, "fluxion/files-frequent") orelse return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(1 << 20)) catch "";
    var out: std.ArrayList(u8) = .empty;
    const now = realNow();
    var found = false;
    var count: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.splitScalar(u8, line, '\t');
        const c = std.fmt.parseInt(u32, parts.next() orelse continue, 10) catch continue;
        const last = parts.next() orelse continue;
        const p = parts.rest();
        if (std.mem.eql(u8, p, path)) {
            found = true;
            out.print(a, "{d}\t{d}\t{s}\n", .{ c + 1, now, p }) catch return;
        } else {
            // The list kept short: what was gone to once, long ago, goes.
            if (count >= 400) continue;
            out.print(a, "{d}\t{s}\t{s}\n", .{ c, last, p }) catch return;
        }
        count += 1;
    }
    if (!found) out.print(a, "1\t{d}\t{s}\n", .{ now, path }) catch return;
    write(io, file, out.items);
    self.stale();
}

/// A file opened from Files: on the shared recent list, as GTK's apps put
/// it there - its time of use moved on, if it is there already.
pub fn opened(self: *History, io: std.Io, path: []const u8, mime: []const u8) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var path_buffer: [512]u8 = undefined;
    const file = dataPath(&path_buffer, "recently-used.xbel") orelse return;
    const text = std.Io.Dir.cwd().readFileAlloc(io, file, a, .limited(8 << 20)) catch
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<xbel version=\"1.0\"\n      xmlns:bookmark=\"http://www.freedesktop.org/standards/desktop-bookmarks\"\n      xmlns:mime=\"http://www.freedesktop.org/standards/shared-mime-info\"\n>\n</xbel>\n";
    var stamp_buffer: [40]u8 = undefined;
    const stamp = isoNow(&stamp_buffer);
    var href: std.ArrayList(u8) = .empty;
    href.appendSlice(a, "file://") catch return;
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            href.append(a, c) catch return;
        } else href.print(a, "%{X:0>2}", .{c}) catch return;
    }
    var out: std.ArrayList(u8) = .empty;
    const wanted = std.fmt.allocPrint(a, "href=\"{s}\"", .{href.items}) catch return;
    if (std.mem.indexOf(u8, text, wanted)) |at| {
        // There: its tag's times moved on, the rest as it was.
        const start = std.mem.lastIndexOfScalar(u8, text[0..at], '<') orelse return;
        const end = std.mem.indexOfScalarPos(u8, text, at, '>') orelse return;
        out.appendSlice(a, text[0..start]) catch return;
        out.print(a, "<bookmark {s} added=\"{s}\" modified=\"{s}\" visited=\"{s}\"", .{ wanted, attribute(text[start..end], "added") orelse stamp, stamp, stamp }) catch return;
        out.appendSlice(a, text[end..]) catch return;
    } else {
        const close = std.mem.lastIndexOf(u8, text, "</xbel>") orelse return;
        out.appendSlice(a, text[0..close]) catch return;
        out.print(a,
            \\  <bookmark {s} added="{s}" modified="{s}" visited="{s}">
            \\    <info>
            \\      <metadata owner="http://freedesktop.org">
            \\        <mime:mime-type type="{s}"/>
            \\        <bookmark:applications>
            \\          <bookmark:application name="Files" exec="&apos;fluxion-files %u&apos;" modified="{s}" count="1"/>
            \\        </bookmark:applications>
            \\      </metadata>
            \\    </info>
            \\  </bookmark>
            \\
        , .{ wanted, stamp, stamp, stamp, mime, stamp }) catch return;
        out.appendSlice(a, text[close..]) catch return;
    }
    write(io, file, out.items);
    self.stale();
}

/// Taken off Recent - here and on the start menu - and kept off.
pub fn hide(self: *History, io: std.Io, paths: []const []const u8) void {
    self.refresh(io);
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    for (self.hidden.items) |h| out.print(a, "{s}\n", .{h}) catch return;
    for (paths) |p| if (!self.isHidden(p)) out.print(a, "{s}\n", .{p}) catch return;
    var buffer: [512]u8 = undefined;
    write(io, statePath(&buffer, "fluxion/recent-hidden") orelse return, out.items);
    self.stale();
}

/// Starred, or not: Windows 11's Add to Favorites and Remove from
/// Favorites.
pub fn setFavorite(self: *History, io: std.Io, path: []const u8, on: bool) void {
    self.refresh(io);
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    for (self.favorites.items) |f| if (!std.mem.eql(u8, f, path)) out.print(a, "{s}\n", .{f}) catch return;
    if (on) out.print(a, "{s}\n", .{path}) catch return;
    var buffer: [512]u8 = undefined;
    write(io, statePath(&buffer, "fluxion/files-favorites") orelse return, out.items);
    self.stale();
}

/// Searched for: first on Recent searches, once.
pub fn searched(self: *History, io: std.Io, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '\n') != null) return;
    self.refresh(io);
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    out.print(a, "{s}\n", .{trimmed}) catch return;
    var kept: usize = 1;
    for (self.searches.items) |s| {
        if (kept == 10) break;
        if (std.mem.eql(u8, s, trimmed)) continue;
        out.print(a, "{s}\n", .{s}) catch return;
        kept += 1;
    }
    var buffer: [512]u8 = undefined;
    write(io, statePath(&buffer, "fluxion/files-searches") orelse return, out.items);
    self.stale();
}

/// Windows 10's "Clear search history".
pub fn clearSearches(self: *History, io: std.Io) void {
    var buffer: [512]u8 = undefined;
    write(io, statePath(&buffer, "fluxion/files-searches") orelse return, "");
    self.stale();
}

/// The Gallery's collection: the folders written, or the person's
/// Pictures.
pub fn galleryFolders(self: *History, io: std.Io, pictures: ?[]const u8, out: *[16][]const u8) []const []const u8 {
    self.refresh(io);
    var n: usize = 0;
    for (self.collection.items) |f| {
        if (n == out.len) break;
        out[n] = f;
        n += 1;
    }
    if (n == 0) if (pictures) |p| {
        out[0] = p;
        n = 1;
    };
    return out[0..n];
}

/// A folder into the collection, or out of it.
pub fn setGallery(self: *History, io: std.Io, folders: []const []const u8) void {
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    for (folders) |f| out.print(a, "{s}\n", .{f}) catch return;
    var buffer: [512]u8 = undefined;
    write(io, statePath(&buffer, "fluxion/files-gallery") orelse return, out.items);
    self.stale();
}

/// Folder Options' Clear: every recent file off the list, the folders
/// forgotten.
pub fn clear(self: *History, io: std.Io) void {
    self.read_ms = 0;
    self.refresh(io);
    var paths: [most_recent][]const u8 = undefined;
    for (self.recent, 0..) |f, i| paths[i] = f.path;
    // Copied out: `hide` reads the lists again.
    var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    for (paths[0..self.recent.len]) |*p| p.* = a.dupe(u8, p.*) catch "";
    self.hide(io, paths[0..self.recent.len]);
    var buffer: [512]u8 = undefined;
    write(io, statePath(&buffer, "fluxion/files-frequent") orelse return, "");
    self.stale();
}

fn write(io: std.Io, file: []const u8, data: []const u8) void {
    if (std.fs.path.dirname(file)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    // Whole or not at all: another app may be reading it.
    var tmp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buffer, "{s}.fluxion-files.tmp", .{file}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data }) catch |err| {
        log.warn("could not write {s}: {t}", .{ file, err });
        return;
    };
    std.Io.Dir.renameAbsolute(tmp, file, io) catch {};
}

// -------------------------------------------------------------------------
// The shared list's form
// -------------------------------------------------------------------------

/// The bookmarks in an XBEL file's text that are local files.
fn parse(a: std.mem.Allocator, text: []const u8, out: *std.ArrayList(File)) void {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, text, at, "<bookmark ")) |start| {
        const end = std.mem.indexOfPos(u8, text, start, "</bookmark>") orelse text.len;
        at = end;
        const tag_end = std.mem.indexOfScalarPos(u8, text, start, '>') orelse break;
        const tag = text[start..tag_end];
        const href = attribute(tag, "href") orelse continue;
        const prefix = "file://";
        if (!std.mem.startsWith(u8, href, prefix)) continue;
        const path = decode(a, href[prefix.len..]) catch continue;
        var when: i64 = 0;
        for ([_][]const u8{ "modified", "visited", "added" }) |name| {
            if (attribute(tag, name)) |stamp| when = @max(when, parseStamp(stamp) orelse 0);
        }
        const body = text[tag_end..end];
        const mime = if (std.mem.indexOf(u8, body, "mime-type type=\"")) |m| blk: {
            const from = m + "mime-type type=\"".len;
            const to = std.mem.indexOfScalarPos(u8, body, from, '"') orelse break :blk "";
            break :blk body[from..to];
        } else "";
        out.append(a, .{ .path = path, .name = std.fs.path.basename(path), .mime = mime, .when = when }) catch return;
    }
}

fn attribute(tag: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, tag, at, name)) |i| {
        at = i + name.len;
        if (i == 0 or tag[i - 1] != ' ' and tag[i - 1] != '\n' and tag[i - 1] != '\t') continue;
        if (at + 2 > tag.len or tag[at] != '=' or tag[at + 1] != '"') continue;
        const from = at + 2;
        const to = std.mem.indexOfScalarPos(u8, tag, from, '"') orelse return null;
        return tag[from..to];
    }
    return null;
}

fn decode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '%' and i + 2 < text.len) {
            if (std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16)) |byte| {
                try out.append(a, byte);
                i += 2;
                continue;
            } else |_| {}
        }
        if (c == '&') {
            const entities = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&apos;", '\'' }, .{ "&quot;", '"' }, .{ "&lt;", '<' }, .{ "&gt;", '>' } };
            const entity = for (entities) |e| {
                if (std.mem.startsWith(u8, text[i..], e[0])) break e;
            } else null;
            if (entity) |e| {
                try out.append(a, e[1]);
                i += e[0].len - 1;
                continue;
            }
        }
        try out.append(a, c);
    }
    return out.items;
}

/// "2026-10-08T09:12:44.512Z", UTC, in seconds since the epoch.
fn parseStamp(text: []const u8) ?i64 {
    if (text.len < 19) return null;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return null;
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * m + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

/// Now, as the list writes a time: "2026-10-10T12:00:00.000000Z".
fn isoNow(buffer: []u8) []const u8 {
    const now = realNow();
    const days = @divFloor(now, 86400);
    const secs = @mod(now, 86400);
    // The civil date from days: Howard Hinnant's, the other way.
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000000Z", .{
        @as(u64, @intCast(y)),                     @as(u64, @intCast(m)),                               @as(u64, @intCast(d)),
        @as(u64, @intCast(@divFloor(secs, 3600))), @as(u64, @intCast(@divFloor(@mod(secs, 3600), 60))), @as(u64, @intCast(@mod(secs, 60))),
    }) catch "";
}

fn dataPath(buffer: []u8, name: []const u8) ?[]const u8 {
    if (std.c.getenv("XDG_DATA_HOME")) |dir| return std.fmt.bufPrint(buffer, "{s}/{s}", .{ std.mem.span(dir), name }) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.local/share/{s}", .{ std.mem.span(home), name }) catch null;
}

fn statePath(buffer: []u8, name: []const u8) ?[]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |dir| return std.fmt.bufPrint(buffer, "{s}/{s}", .{ std.mem.span(dir), name }) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.local/state/{s}", .{ std.mem.span(home), name }) catch null;
}

fn realNow() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn monotonicMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "a time is written as the list writes it, and read back" {
    var buffer: [40]u8 = undefined;
    const now = isoNow(&buffer);
    try std.testing.expect(now.len == "2026-10-10T12:00:00.000000Z".len);
    const back = parseStamp(now).?;
    try std.testing.expect(@abs(back - realNow()) < 5);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var files: std.ArrayList(File) = .empty;
    parse(arena.allocator(), "<bookmark href=\"file:///home/k/a%20b.txt\" added=\"2026-10-08T09:12:44Z\" modified=\"2026-10-09T09:12:44Z\"><info><metadata><mime:mime-type type=\"text/plain\"/></metadata></info></bookmark>", &files);
    try std.testing.expectEqualStrings("/home/k/a b.txt", files.items[0].path);
    try std.testing.expectEqualStrings("text/plain", files.items[0].mime);
}
