// SPDX-License-Identifier: BSD-2-Clause

//! What the preview pane shows of a file, made ready on a thread of its own
//! so the window never waits on a file - as Windows' preview handlers each
//! know one kind:
//!
//! | The file | The preview |
//! | --- | --- |
//! | a picture | itself, made to fit |
//! | text, code | its lines - code in a monospaced face |
//! | a PDF | its pages, one under another, made as they come into sight (Poppler's `pdftoppm`) |
//! | a video | a frame of it, to play in the pane (FFmpeg) |
//! | music | its cover, its title and artist, to play in the pane (FFmpeg) |
//! | a compressed folder | what is in it (libarchive) |
//! | a font | its letters at a few sizes, as Windows' font viewer shows them |
//! | anything else | what the system's thumbnailers make of it: an office document's first page, a book's cover |
//!
//! What it learns on the way - a picture's size, a song's artist, a PDF's
//! number of pages - is what the details pane lists.
//!
//! **One file at a time**: the pane asks for a file each time it is drawn,
//! and a file asked for while another is being made is made next; the one
//! before is thrown away, made or not.

const std = @import("std");
const raster = @import("fluxion_ui_raster");
const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");

const ImageFile = @import("ImageFile.zig");
const Archive = @import("Archive.zig");
const Thumbs = @import("Thumbs.zig");
const Icons = @import("Icons.zig");

const Preview = @This();

const log = std.log.scoped(.preview);

/// The most of a text file read: past it, "…".
const most_text = 256 << 10;
/// The most pages of a PDF made at once, ahead of where it is read.
pub const pages_ahead = 2;

pub const Kind = enum {
    /// Nothing asked for.
    nothing,
    /// Asked for, not made yet.
    loading,
    picture,
    text,
    pdf,
    video,
    audio,
    archive,
    font,
    /// What a thumbnailer made: an office document's page, a book's cover.
    document,
    folder,
    /// A file this has no preview for.
    none,
};

/// A line of what was learnt of the file: "Length", "00:03:12".
pub const Info = struct { name: []const u8, value: []const u8 };

pub const Media = struct {
    duration_ms: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    has_video: bool = false,
    has_audio: bool = false,
    title: []const u8 = "",
    artist: []const u8 = "",
    album: []const u8 = "",
};

/// What the thread made of a file.
pub const Made = struct {
    gen: u64,
    arena: std.heap.ArenaAllocator,
    kind: Kind = .none,
    /// The picture, the video's frame, the cover, the font's letters, the
    /// thumbnailer's page.
    picture: ?raster.Image = null,
    /// The picture's own size, and as made.
    source_size: [2]u32 = .{ 0, 0 },
    picture_size: [2]u32 = .{ 0, 0 },
    has_picture: bool = false,
    lines: []const []const u8 = &.{},
    /// The longest line's length, in bytes: how wide the text is, nearly.
    longest: usize = 0,
    truncated: bool = false,
    code: bool = false,
    pages: u32 = 0,
    /// A page's height for its width.
    page_aspect: f32 = 1.4142,
    media: Media = .{},
    entries: []const Archive.Entry = &.{},
    files: u32 = 0,
    folders: u32 = 0,
    unpacked: u64 = 0,
    info: []const Info = &.{},

    fn deinit(self: *Made, gpa: std.mem.Allocator) void {
        if (self.picture) |*p| p.deinit(gpa);
        self.arena.deinit();
    }
};

/// A page of a PDF, made.
const PageMade = struct { gen: u64, number: u32, picture: ?raster.Image };

/// A page of the PDF shown, as the pane has it.
pub const Page = struct {
    number: u32,
    slot: ?u32 = null,
    size: [2]u32 = .{ 0, 0 },
    failed: bool = false,
};

const Want = struct {
    gen: u64,
    path: []u8,
    mime: []u8,
    box: u32,
    handlers: bool,
};

const PageAsk = struct { gen: u64, number: u32, path: []u8, box: u32 };

gpa: std.mem.Allocator,
io: std.Io,
wake: std.c.fd_t,
gen: u64 = 0,
/// What is asked for now: the file, when it last changed, the room.
path_buffer: [std.fs.max_path_bytes]u8 = undefined,
path_len: usize = 0,
mtime: i128 = 0,
box: u32 = 0,
handlers: bool = true,
/// When the file was asked for: a moment of nothing before "Loading".
asked_ms: i64 = 0,
/// What is shown: made, and the window's slot its picture is in.
shown: ?Made = null,
picture_slot: ?u32 = null,
/// The PDF's pages made so far, and the window's slots that are spare.
pages: std.ArrayList(Page) = .empty,
spare: std.ArrayList(u32) = .empty,
shared: Shared = .{},

const Shared = struct {
    mutex: std.Io.Mutex = .init,
    want: ?Want = null,
    page_asks: std.ArrayList(PageAsk) = .empty,
    made: ?Made = null,
    pages_made: std.ArrayList(PageMade) = .empty,
    running: bool = false,
    /// The newest asked for: anything older the thread makes is thrown away.
    latest: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, wake: std.c.fd_t) Preview {
    return .{ .gpa = gpa, .io = io, .wake = wake };
}

pub fn deinit(self: *Preview) void {
    self.shared.cancel.store(true, .release);
    while (true) {
        self.shared.mutex.lockUncancelable(self.io);
        const running = self.shared.running;
        self.shared.mutex.unlock(self.io);
        if (!running) break;
        std.Thread.yield() catch {};
    }
    if (self.shared.want) |w| freeWant(self.gpa, w);
    for (self.shared.page_asks.items) |a| self.gpa.free(a.path);
    self.shared.page_asks.deinit(self.gpa);
    if (self.shared.made) |*m| m.deinit(self.gpa);
    for (self.shared.pages_made.items) |*p| if (p.picture) |*image| image.deinit(self.gpa);
    self.shared.pages_made.deinit(self.gpa);
    if (self.shown) |*m| m.deinit(self.gpa);
    self.pages.deinit(self.gpa);
    self.spare.deinit(self.gpa);
}

fn freeWant(gpa: std.mem.Allocator, w: Want) void {
    gpa.free(w.path);
    gpa.free(w.mime);
}

/// The file the pane shows: `path`, of kind `mime`, last changed `mtime`,
/// in `box` pixels across - made, if it is not what was asked for last.
/// `handlers`: Folder Options' "Show preview handlers in preview pane".
pub fn show(self: *Preview, path: []const u8, mime: []const u8, mtime: i128, box: u32, handlers: bool) void {
    const same = std.mem.eql(u8, self.path_buffer[0..self.path_len], path) and self.mtime == mtime and self.handlers == handlers;
    // Wider by little: the same picture does. Much wider, made again.
    const near = self.box > 0 and box <= self.box + self.box / 4 and box + box / 4 >= self.box;
    if (same and near) return;
    self.path_len = @min(path.len, self.path_buffer.len);
    @memcpy(self.path_buffer[0..self.path_len], path[0..self.path_len]);
    self.mtime = mtime;
    self.box = box;
    self.handlers = handlers;
    self.gen += 1;
    // Another file: what was shown goes; the same one wider is kept until
    // the new one comes.
    if (!same) {
        self.drop();
        self.asked_ms = nowMs();
    }
    const want: Want = .{
        .gen = self.gen,
        .path = self.gpa.dupe(u8, path) catch return,
        .mime = self.gpa.dupe(u8, mime) catch return,
        .box = box,
        .handlers = handlers,
    };
    self.shared.latest.store(self.gen, .release);
    self.shared.mutex.lockUncancelable(self.io);
    defer self.shared.mutex.unlock(self.io);
    if (self.shared.want) |old| freeWant(self.gpa, old);
    self.shared.want = want;
    for (self.shared.page_asks.items) |a| self.gpa.free(a.path);
    self.shared.page_asks.clearRetainingCapacity();
    self.startThread();
}

/// Nothing to show: nothing chosen, or more than one thing.
pub fn clear(self: *Preview) void {
    if (self.path_len == 0) return;
    self.path_len = 0;
    self.gen += 1;
    self.shared.latest.store(self.gen, .release);
    self.drop();
}

/// The file asked for last.
pub fn shownPath(self: *const Preview) []const u8 {
    return self.path_buffer[0..self.path_len];
}

/// What is shown now, if it is made: the file asked for, or - made
/// again wider - as it was until it is.
pub fn current(self: *const Preview) ?*const Made {
    if (self.path_len == 0) return null;
    return if (self.shown) |*m| m else null;
}

fn drop(self: *Preview) void {
    if (self.shown) |*m| m.deinit(self.gpa);
    self.shown = null;
    for (self.pages.items) |p| if (p.slot) |slot| self.spare.append(self.gpa, slot) catch {};
    self.pages.clearRetainingCapacity();
}

/// Page `number` of the PDF shown, if made - asked for, the first time.
pub fn page(self: *Preview, number: u32) ?Page {
    const m = self.shown orelse return null;
    if (m.kind != .pdf or number == 0 or number > m.pages) return null;
    for (self.pages.items) |p| if (p.number == number) return p;
    self.pages.append(self.gpa, .{ .number = number }) catch return null;
    const copy = self.gpa.dupe(u8, self.shownPath()) catch return null;
    self.shared.mutex.lockUncancelable(self.io);
    defer self.shared.mutex.unlock(self.io);
    self.shared.page_asks.append(self.gpa, .{ .gen = m.gen, .number = number, .path = copy, .box = self.box }) catch {
        self.gpa.free(copy);
        return null;
    };
    self.startThread();
    return null;
}

fn startThread(self: *Preview) void {
    if (self.shared.running) return;
    const thread = std.Thread.spawn(.{}, work, .{self}) catch return;
    thread.detach();
    self.shared.running = true;
}

/// What the thread made, into the pane and the window's slots. Whether
/// anything new is there to draw.
pub fn take(self: *Preview, icons: *Icons) bool {
    self.shared.mutex.lockUncancelable(self.io);
    var made = self.shared.made;
    self.shared.made = null;
    const pages_made = self.shared.pages_made.toOwnedSlice(self.gpa) catch &.{};
    self.shared.mutex.unlock(self.io);
    defer self.gpa.free(pages_made);
    var any = false;
    if (made) |*m| {
        if (m.gen == self.gen) {
            if (self.shown) |*old| old.deinit(self.gpa);
            for (self.pages.items) |p| if (p.slot) |slot| self.spare.append(self.gpa, slot) catch {};
            self.pages.clearRetainingCapacity();
            // The picture into the window's slot; the pane keeps its size.
            if (m.picture) |image| {
                m.picture = null;
                self.picture_slot = icons.put(self.picture_slot, image);
            }
            self.shown = m.*;
            any = true;
        } else m.deinit(self.gpa);
    }
    for (pages_made) |pm| {
        const for_shown = if (self.shown) |s| s.gen == pm.gen else false;
        const p = for (self.pages.items) |*p| {
            if (p.number == pm.number) break p;
        } else null;
        if (!for_shown or p == null) {
            if (pm.picture) |image| {
                var gone = image;
                gone.deinit(self.gpa);
            }
            continue;
        }
        const picture = pm.picture orelse {
            p.?.failed = true;
            any = true;
            continue;
        };
        p.?.size = .{ picture.width, picture.height };
        p.?.slot = icons.put(self.spare.pop(), picture);
        any = true;
    }
    return any;
}

/// The picture shown, in the window's slot, and its size as made.
pub fn shownPicture(self: *const Preview) ?struct { slot: u32, size: [2]u32 } {
    const m = self.current() orelse return null;
    if (!m.has_picture) return null;
    const slot = self.picture_slot orelse return null;
    return .{ .slot = slot, .size = m.picture_size };
}

// -------------------------------------------------------------------------
// The thread
// -------------------------------------------------------------------------

fn work(self: *Preview) void {
    while (true) {
        self.shared.mutex.lockUncancelable(self.io);
        const cancel = self.shared.cancel.load(.acquire);
        const want = if (cancel) null else self.shared.want;
        self.shared.want = null;
        const ask: ?PageAsk = if (cancel or want != null or self.shared.page_asks.items.len == 0) null else self.shared.page_asks.orderedRemove(0);
        if (want == null and ask == null) self.shared.running = false;
        self.shared.mutex.unlock(self.io);
        if (want) |w| {
            defer freeWant(self.gpa, w);
            var made = self.make(w);
            self.shared.mutex.lockUncancelable(self.io);
            if (self.shared.made) |*old| old.deinit(self.gpa);
            self.shared.made = made;
            self.shared.mutex.unlock(self.io);
            _ = &made;
            _ = std.c.write(self.wake, "p", 1);
            continue;
        }
        if (ask) |a| {
            defer self.gpa.free(a.path);
            // Asked for a file no longer shown: not made.
            if (a.gen != self.shared.latest.load(.acquire)) continue;
            const image = renderPage(self.gpa, self.io, a.path, a.number, a.box);
            self.shared.mutex.lockUncancelable(self.io);
            self.shared.pages_made.append(self.gpa, .{ .gen = a.gen, .number = a.number, .picture = image }) catch if (image) |p| {
                var gone = p;
                gone.deinit(self.gpa);
            };
            self.shared.mutex.unlock(self.io);
            _ = std.c.write(self.wake, "p", 1);
            continue;
        }
        return;
    }
}

fn make(self: *Preview, w: Want) Made {
    var made: Made = .{ .gen = w.gen, .arena = .init(self.gpa) };
    const name = std.fs.path.basename(w.path);
    const stat = std.Io.Dir.cwd().statFile(self.io, w.path, .{}) catch {
        made.kind = .none;
        return made;
    };
    if (stat.kind == .directory) {
        made.kind = .folder;
        return made;
    }
    const mime = w.mime;
    const starts = std.mem.startsWith;
    if (starts(u8, mime, "image/") or ImageFile.named(name)) {
        if (self.makePicture(&made, w)) return made;
    } else if (std.mem.eql(u8, mime, "application/pdf")) {
        if (self.makePdf(&made, w)) return made;
    } else if (starts(u8, mime, "video/")) {
        if (self.makeMedia(&made, w, true)) return made;
    } else if (starts(u8, mime, "audio/")) {
        if (self.makeMedia(&made, w, false)) return made;
    } else if (Archive.named(name)) {
        if (self.makeArchive(&made, w)) return made;
    } else if (isFont(mime, name)) {
        if (self.makeFont(&made, w)) return made;
    }
    if (isText(mime, name) or (stat.size > 0 and stat.size < most_text and sniffText(self.io, w.path))) {
        if (self.makeText(&made, w, mime, name)) return made;
    }
    // The system's thumbnailers: what a picture this cannot read is, an
    // office document's first page, a book's cover.
    if (w.handlers) if (thumbnail(self.gpa, self.io, w.path, mime, w.box)) |image| {
        made.kind = if (starts(u8, mime, "image/")) .picture else .document;
        self.setPicture(&made, image, w.box);
        return made;
    };
    made.kind = .none;
    return made;
}

fn setPicture(self: *Preview, made: *Made, source: raster.Image, box: u32) void {
    var image = source;
    made.source_size = .{ image.width, image.height };
    if (image.width > box or image.height > box * 2) {
        const small = Thumbs.fit(self.gpa, image, box, box * 2) catch {
            image.deinit(self.gpa);
            return;
        };
        image.deinit(self.gpa);
        image = small;
    }
    made.picture_size = .{ image.width, image.height };
    made.has_picture = true;
    made.picture = image;
}

fn info(made: *Made, name: []const u8, comptime format: []const u8, args: anytype) void {
    const a = made.arena.allocator();
    const value = std.fmt.allocPrint(a, format, args) catch return;
    if (value.len == 0) return;
    var list: std.ArrayList(Info) = .fromOwnedSlice(@constCast(made.info));
    list.append(a, .{ .name = name, .value = value }) catch return;
    made.info = list.items;
}

fn makePicture(self: *Preview, made: *Made, w: Want) bool {
    const stat = std.Io.Dir.cwd().statFile(self.io, w.path, .{}) catch return false;
    if (stat.size > 96 << 20) return false;
    const image = ImageFile.read(self.gpa, self.io, w.path) catch return false;
    made.kind = .picture;
    self.setPicture(made, image, w.box);
    info(made, "Dimensions", "{d} x {d}", .{ made.source_size[0], made.source_size[1] });
    return true;
}

fn makeText(self: *Preview, made: *Made, w: Want, mime: []const u8, name: []const u8) bool {
    const a = made.arena.allocator();
    const buffer = a.alloc(u8, most_text) catch return false;
    const read = std.Io.Dir.cwd().readFile(self.io, w.path, buffer) catch return false;
    // Not text after all: a nought in it.
    if (std.mem.indexOfScalar(u8, read[0..@min(read.len, 8192)], 0) != null) return false;
    var end = read.len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(read[0..end])) end -= 1;
    if (end == 0 and read.len > 0) return false;
    const text = std.mem.trimStart(u8, read[0..end], "\xEF\xBB\xBF");
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var longest: usize = 0;
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        lines.append(a, line) catch break;
        longest = @max(longest, line.len);
    }
    // The last line break makes no line of its own.
    if (lines.items.len > 1 and lines.items[lines.items.len - 1].len == 0) lines.items.len -= 1;
    made.kind = .text;
    made.lines = lines.items;
    made.longest = longest;
    made.truncated = read.len == most_text;
    made.code = isCode(mime, name);
    info(made, "Lines", "{d}{s}", .{ lines.items.len, if (made.truncated) "+" else "" });
    return true;
}

fn makeArchive(self: *Preview, made: *Made, w: Want) bool {
    _ = self;
    const a = made.arena.allocator();
    var entries: std.ArrayList(Archive.Entry) = .empty;
    Archive.list(a, w.path, &entries) catch return false;
    // Folders first, then by name.
    std.mem.sort(Archive.Entry, entries.items, {}, struct {
        fn lessThan(_: void, x: Archive.Entry, y: Archive.Entry) bool {
            if ((x.kind == .folder) != (y.kind == .folder)) return x.kind == .folder;
            return std.ascii.lessThanIgnoreCase(x.path, y.path);
        }
    }.lessThan);
    for (entries.items) |e| {
        if (e.kind == .folder) made.folders += 1 else made.files += 1;
        made.unpacked += e.size;
    }
    made.kind = .archive;
    made.entries = entries.items;
    var size_buffer: [32]u8 = undefined;
    info(made, "Contains", "{d} files, {d} folders", .{ made.files, made.folders });
    info(made, "Uncompressed size", "{s}", .{@import("Folder.zig").sizeText(made.unpacked, &size_buffer)});
    return true;
}

// -- PDF --

fn makePdf(self: *Preview, made: *Made, w: Want) bool {
    const a = made.arena.allocator();
    const result = std.process.run(a, self.io, .{ .argv = &.{ "pdfinfo", w.path }, .stdout_limit = .limited(64 << 10) }) catch return false;
    if (result.term != .exited or result.term.exited != 0) return false;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    var page_w: f32 = 0;
    var page_h: f32 = 0;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        if (std.mem.eql(u8, name, "Pages")) made.pages = std.fmt.parseInt(u32, value, 10) catch 0;
        if (std.mem.eql(u8, name, "Title") and value.len > 0) info(made, "Title", "{s}", .{value});
        if (std.mem.eql(u8, name, "Author") and value.len > 0) info(made, "Authors", "{s}", .{value});
        if (std.mem.eql(u8, name, "Page size")) {
            // "612 x 792 pts (letter)"
            var parts = std.mem.tokenizeAny(u8, value, " x");
            page_w = std.fmt.parseFloat(f32, parts.next() orelse "0") catch 0;
            page_h = std.fmt.parseFloat(f32, parts.next() orelse "0") catch 0;
        }
    }
    if (made.pages == 0) return false;
    if (page_w > 0 and page_h > 0) made.page_aspect = page_h / page_w;
    info(made, "Pages", "{d}", .{made.pages});
    made.kind = .pdf;
    return true;
}

/// Page `number` of the PDF at `path`, `box` pixels across.
fn renderPage(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, number: u32, box: u32) ?raster.Image {
    var page_buffer: [16]u8 = undefined;
    const page_text = std.fmt.bufPrint(&page_buffer, "{d}", .{number}) catch return null;
    var width_buffer: [16]u8 = undefined;
    const width_text = std.fmt.bufPrint(&width_buffer, "{d}", .{box}) catch return null;
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "pdftoppm", "-f", page_text, "-l", page_text, "-scale-to-x", width_text, "-scale-to-y", "-1", "-png", "-aa", "yes", "-aaVector", "yes", file_path },
        .stdout_limit = .limited(64 << 20),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.stdout.len == 0) return null;
    return ImageFile.decode(gpa, result.stdout) catch null;
}

// -- Video and music --

fn makeMedia(self: *Preview, made: *Made, w: Want, video: bool) bool {
    const a = made.arena.allocator();
    const result = std.process.run(a, self.io, .{
        .argv = &.{ "ffprobe", "-v", "error", "-print_format", "json", "-show_format", "-show_streams", w.path },
        .stdout_limit = .limited(1 << 20),
    }) catch return false;
    if (result.term != .exited or result.term.exited != 0) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, a, result.stdout, .{}) catch return false;
    const root = parsed.value;
    var media: Media = .{};
    var fps: f32 = 0;
    var video_codec: []const u8 = "";
    var audio_codec: []const u8 = "";
    var sample_rate: []const u8 = "";
    var channels: i64 = 0;
    if (field(root, "streams")) |streams| if (streams == .array) for (streams.array.items) |s| {
        const codec_type = string(field(s, "codec_type")) orelse continue;
        if (std.mem.eql(u8, codec_type, "video")) {
            // A song's cover is a picture "stream" of one frame.
            const disposition = field(s, "disposition");
            const attached = if (disposition) |d| (integer(field(d, "attached_pic")) orelse 0) == 1 else false;
            if (attached) continue;
            media.has_video = true;
            media.width = @intCast(@max(0, integer(field(s, "width")) orelse 0));
            media.height = @intCast(@max(0, integer(field(s, "height")) orelse 0));
            video_codec = string(field(s, "codec_long_name")) orelse string(field(s, "codec_name")) orelse "";
            if (string(field(s, "avg_frame_rate"))) |rate| fps = ratio(rate);
        } else if (std.mem.eql(u8, codec_type, "audio")) {
            media.has_audio = true;
            audio_codec = string(field(s, "codec_long_name")) orelse string(field(s, "codec_name")) orelse "";
            sample_rate = string(field(s, "sample_rate")) orelse "";
            channels = integer(field(s, "channels")) orelse 0;
        }
    };
    var bit_rate: u64 = 0;
    if (field(root, "format")) |format| {
        if (string(field(format, "duration"))) |d| media.duration_ms = @intFromFloat(@max(0, (std.fmt.parseFloat(f64, d) catch 0) * 1000));
        if (string(field(format, "bit_rate"))) |b| bit_rate = std.fmt.parseInt(u64, b, 10) catch 0;
        if (field(format, "tags")) |tags| {
            media.title = tag(tags, "title") orelse "";
            media.artist = tag(tags, "artist") orelse tag(tags, "album_artist") orelse "";
            media.album = tag(tags, "album") orelse "";
            if (media.title.len > 0) info(made, "Title", "{s}", .{media.title});
            if (media.artist.len > 0) info(made, "Contributing artists", "{s}", .{media.artist});
            if (media.album.len > 0) info(made, "Album", "{s}", .{media.album});
            if (tag(tags, "date")) |d| info(made, "Year", "{s}", .{d[0..@min(d.len, 4)]});
            if (tag(tags, "genre")) |g| info(made, "Genre", "{s}", .{g});
            if (tag(tags, "track")) |t| info(made, "#", "{s}", .{t});
        }
    }
    if (!media.has_video and !media.has_audio) return false;
    var length_buffer: [32]u8 = undefined;
    info(made, "Length", "{s}", .{clockText(media.duration_ms, &length_buffer, true)});
    if (media.has_video) {
        info(made, "Frame width", "{d}", .{media.width});
        info(made, "Frame height", "{d}", .{media.height});
        if (fps > 0) info(made, "Frame rate", "{d:.2} frames/second", .{fps});
        if (video_codec.len > 0) info(made, "Video", "{s}", .{video_codec});
    }
    if (media.has_audio) {
        if (audio_codec.len > 0) info(made, "Audio", "{s}", .{audio_codec});
        if (sample_rate.len > 0) info(made, "Sample rate", "{d} kHz", .{(std.fmt.parseFloat(f32, sample_rate) catch 0) / 1000});
        if (channels > 0) info(made, "Channels", "{s}", .{if (channels == 1) "1 (mono)" else if (channels == 2) "2 (stereo)" else "more than 2"});
    }
    if (bit_rate > 0) info(made, "Bit rate", "{d}kbps", .{bit_rate / 1000});
    made.media = media;
    made.kind = if (video and media.has_video) .video else .audio;
    // A frame a little way in, as Windows shows one - or the cover.
    const frame = if (made.kind == .video) videoFrame(self.gpa, self.io, w.path, media.duration_ms, w.box) else cover(self.gpa, self.io, w.path, w.box);
    if (frame) |image| self.setPicture(made, image, w.box);
    return true;
}

/// A frame of the video at `path`, a tenth of the way in - but no more than
/// a few seconds - `box` pixels across.
fn videoFrame(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, duration_ms: u64, box: u32) ?raster.Image {
    var at_buffer: [32]u8 = undefined;
    const at = std.fmt.bufPrint(&at_buffer, "{d:.3}", .{@as(f64, @floatFromInt(@min(duration_ms / 10, 3000))) / 1000}) catch return null;
    var scale_buffer: [32]u8 = undefined;
    const scale = std.fmt.bufPrint(&scale_buffer, "scale='min({d},iw)':-2", .{box}) catch return null;
    return ffmpegPicture(gpa, io, &.{ "ffmpeg", "-v", "error", "-ss", at, "-i", file_path, "-frames:v", "1", "-vf", scale, "-f", "image2pipe", "-vcodec", "png", "-" });
}

/// The cover a song carries, if it has one.
fn cover(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, box: u32) ?raster.Image {
    var scale_buffer: [32]u8 = undefined;
    const scale = std.fmt.bufPrint(&scale_buffer, "scale='min({d},iw)':-2", .{box}) catch return null;
    return ffmpegPicture(gpa, io, &.{ "ffmpeg", "-v", "error", "-i", file_path, "-an", "-map", "0:v:0", "-frames:v", "1", "-vf", scale, "-f", "image2pipe", "-vcodec", "png", "-" });
}

fn ffmpegPicture(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8) ?raster.Image {
    const result = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(64 << 20) }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.stdout.len == 0) return null;
    return ImageFile.decode(gpa, result.stdout) catch null;
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(name);
}

fn string(v: ?std.json.Value) ?[]const u8 {
    const value = v orelse return null;
    return if (value == .string) value.string else null;
}

fn integer(v: ?std.json.Value) ?i64 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// A tag, whatever case its name is in: Vorbis's "TITLE", ID3's "title".
fn tag(tags: std.json.Value, name: []const u8) ?[]const u8 {
    if (tags != .object) return null;
    var it = tags.object.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, name)) if (e.value_ptr.* == .string and e.value_ptr.string.len > 0) return e.value_ptr.string;
    }
    return null;
}

/// "30000/1001" as 29.97.
fn ratio(text: []const u8) f32 {
    const slash = std.mem.indexOfScalar(u8, text, '/') orelse return std.fmt.parseFloat(f32, text) catch 0;
    const n = std.fmt.parseFloat(f32, text[0..slash]) catch return 0;
    const d = std.fmt.parseFloat(f32, text[slash + 1 ..]) catch return 0;
    return if (d > 0) n / d else 0;
}

/// "1:05" or "01:02:03" - Windows' Length, with hours, as "00:01:05".
pub fn clockText(ms: u64, buffer: []u8, hours: bool) []const u8 {
    const s = ms / 1000;
    if (hours) return std.fmt.bufPrint(buffer, "{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) catch "";
    if (s >= 3600) return std.fmt.bufPrint(buffer, "{d}:{d:0>2}:{d:0>2}", .{ s / 3600, s / 60 % 60, s % 60 }) catch "";
    return std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

// -- A font --

fn isFont(mime: []const u8, name: []const u8) bool {
    if (std.mem.startsWith(u8, mime, "font/")) return true;
    for ([_][]const u8{ ".ttf", ".otf" }) |e| {
        if (name.len > e.len and std.ascii.eqlIgnoreCase(name[name.len - e.len ..], e)) return true;
    }
    return std.mem.eql(u8, mime, "application/x-font-ttf") or std.mem.eql(u8, mime, "application/x-font-otf");
}

/// The font's letters, drawn in it at a few sizes - as Windows' font
/// viewer shows a font - `box` pixels across.
fn makeFont(self: *Preview, made: *Made, w: Want) bool {
    const gpa = self.gpa;
    const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, w.path, gpa, .limited(32 << 20)) catch return false;
    defer gpa.free(bytes);
    var fonts = widgets.Fonts.init(bytes, bytes) catch return false;
    var layout: ui.Ui = .init(gpa);
    defer layout.deinit();
    layout.setMeasurer(fonts.measurer());
    const width: u32 = @max(120, w.box);
    const height: u32 = @min(2000, width * 3);
    const ink: ui.Color = .black;
    layout.begin(.{ .size = .init(@floatFromInt(width), @floatFromInt(height)) });
    {
        layout.open(.{ .width = .grow, .height = .grow, .direction = .top_to_bottom, .padding = .all(10), .gap = 10, .background_color = .white });
        defer layout.close();
        const stem = std.fs.path.stem(w.path);
        layout.text(stem, .{ .font_size = 22, .color = ink, .wrap = .words });
        layout.text("abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 1234567890.:,; ' \" (!?) +-*/=", .{ .font_size = 14, .color = ink, .wrap = .words });
        layout.empty(.{ .width = .grow, .height = .fixed(1), .background_color = .rgb(0.78, 0.78, 0.78) });
        for ([_]u16{ 12, 18, 24, 36, 48, 60, 72 }) |size| {
            layout.open(.{ .width = .grow, .gap = 8, .align_y = .center, .clip = .both });
            defer layout.close();
            var number_buffer: [8]u8 = undefined;
            layout.text(std.fmt.bufPrint(&number_buffer, "{d}", .{size}) catch "", .{ .font_size = 10, .color = .rgb(0.43, 0.43, 0.43), .wrap = .none });
            layout.text("The quick brown fox jumps over the lazy dog. 1234567890", .{ .font_size = size, .color = ink, .wrap = .none });
        }
    }
    const commands = layout.end() catch return false;
    var painter = raster.Renderer.init(gpa, &fonts.text) catch return false;
    defer painter.deinit();
    const faces = fonts.faces();
    painter.setFaces(&faces) catch return false;
    const pixels = gpa.alloc(raster.Pixel, @as(usize, width) * height) catch return false;
    painter.draw(.init(pixels, width, height), commands, .white) catch {
        gpa.free(pixels);
        return false;
    };
    // As tall as what was drawn.
    const used = @min(height, lastInk(pixels, width, height) + 10);
    var image: raster.Image = .{ .pixels = pixels, .width = width, .height = height };
    if (used < height) {
        const cut = gpa.alloc(raster.Pixel, @as(usize, width) * used) catch {
            image.deinit(gpa);
            return false;
        };
        @memcpy(cut, pixels[0..cut.len]);
        image.deinit(gpa);
        image = .{ .pixels = cut, .width = width, .height = used };
    }
    made.kind = .font;
    made.source_size = .{ image.width, image.height };
    made.picture_size = made.source_size;
    made.has_picture = true;
    made.picture = image;
    return true;
}

/// The last row with anything but white on it.
fn lastInk(pixels: []const raster.Pixel, width: u32, height: u32) u32 {
    var y = height;
    while (y > 0) {
        y -= 1;
        for (pixels[y * width ..][0..width]) |p| if (p & 0xFFFFFF != 0xFFFFFF) return y + 1;
    }
    return 1;
}

// -- What kind of file --

/// Whether a file of this kind is text to read.
pub fn isText(mime: []const u8, name: []const u8) bool {
    if (std.mem.startsWith(u8, mime, "text/")) return true;
    const texts = [_][]const u8{ "application/json", "application/xml", "application/x-shellscript", "application/javascript", "application/x-yaml", "application/toml", "application/x-desktop", "application/x-zerosize", "application/sql", "application/x-perl", "application/x-ruby", "application/x-php", "image/svg+xml", "application/x-subrip" };
    for (texts) |t| if (std.mem.eql(u8, mime, t)) return true;
    return isCodeName(name);
}

fn isCode(mime: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, mime, "text/plain") or std.mem.eql(u8, mime, "text/markdown")) return isCodeName(name);
    if (std.mem.startsWith(u8, mime, "text/x-") or std.mem.startsWith(u8, mime, "application/")) return true;
    return isCodeName(name) or std.mem.eql(u8, mime, "text/css") or std.mem.eql(u8, mime, "text/html") or std.mem.eql(u8, mime, "image/svg+xml");
}

fn isCodeName(name: []const u8) bool {
    const code = [_][]const u8{ ".zig", ".c", ".h", ".cpp", ".hpp", ".cc", ".rs", ".go", ".py", ".js", ".ts", ".jsx", ".tsx", ".java", ".kt", ".cs", ".sh", ".bash", ".zsh", ".fish", ".lua", ".rb", ".php", ".pl", ".json", ".toml", ".yaml", ".yml", ".ini", ".conf", ".cfg", ".xml", ".html", ".css", ".scss", ".sql", ".zon", ".cmake", ".mk", ".glsl", ".hlsl", ".wgsl", ".swift", ".dart", ".vue", ".svelte", ".diff", ".patch" };
    for (code) |e| {
        if (name.len > e.len and std.ascii.eqlIgnoreCase(name[name.len - e.len ..], e)) return true;
    }
    const names = [_][]const u8{ "Makefile", "Dockerfile", "CMakeLists.txt", "build.zig.zon", "PKGBUILD", "meson.build" };
    for (names) |n| if (std.mem.eql(u8, name, n)) return true;
    return false;
}

/// Whether the first bytes of a file of no known kind read as text.
fn sniffText(io: std.Io, file_path: []const u8) bool {
    var buffer: [1024]u8 = undefined;
    const head = std.Io.Dir.cwd().readFile(io, file_path, &buffer) catch return false;
    if (head.len == 0) return false;
    if (std.mem.indexOfScalar(u8, head, 0) != null) return false;
    var end = head.len;
    // A character cut at the end is still text.
    while (end > 0 and end + 4 > head.len and !std.unicode.utf8ValidateSlice(head[0..end])) end -= 1;
    return std.unicode.utf8ValidateSlice(head[0..end]);
}

// -- The system's thumbnailers --

/// What the system's thumbnailers - `/usr/share/thumbnailers` - make of
/// the file at `path`, `box` pixels across: the first one that says it
/// takes this kind and is installed.
fn thumbnail(gpa: std.mem.Allocator, io: std.Io, file_path: []const u8, mime: []const u8, box: u32) ?raster.Image {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const data_dirs = if (std.c.getenv("XDG_DATA_DIRS")) |d| std.mem.span(d) else "/usr/local/share:/usr/share";
    var dirs = std.mem.tokenizeScalar(u8, data_dirs, ':');
    while (dirs.next()) |data| {
        const dir_path = std.fmt.allocPrint(a, "{s}/thumbnailers", .{data}) catch continue;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |item| {
            if (!std.mem.endsWith(u8, item.name, ".thumbnailer")) continue;
            const text = dir.readFileAlloc(io, item.name, a, .limited(16 << 10)) catch continue;
            const exec = entryKey(text, "Exec") orelse continue;
            const types = entryKey(text, "MimeType") orelse continue;
            if (!listHas(types, mime)) continue;
            if (entryKey(text, "TryExec")) |try_exec| if (!onPath(a, try_exec)) continue;
            if (run(gpa, io, exec, file_path, box)) |image| return image;
        }
    }
    return null;
}

fn entryKey(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " "), name)) return std.mem.trim(u8, line[eq + 1 ..], " ");
    }
    return null;
}

fn listHas(list: []const u8, wanted: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, list, ';');
    while (it.next()) |item| if (std.mem.eql(u8, item, wanted)) return true;
    return false;
}

fn onPath(a: std.mem.Allocator, program: []const u8) bool {
    if (program.len > 0 and program[0] == '/') return std.c.access((a.dupeZ(u8, program) catch return false).ptr, std.c.X_OK) == 0;
    const path_env = if (std.c.getenv("PATH")) |p| std.mem.span(p) else "/usr/bin:/bin";
    var dirs = std.mem.tokenizeScalar(u8, path_env, ':');
    while (dirs.next()) |dir| {
        const full = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, program }, 0) catch continue;
        if (std.c.access(full.ptr, std.c.X_OK) == 0) return true;
    }
    return false;
}

var thumbnail_count: std.atomic.Value(u32) = .init(0);

/// A thumbnailer's `Exec` run: its `%u`, `%i`, `%o` and `%s` filled in, its
/// picture read from where it put it.
fn run(gpa: std.mem.Allocator, io: std.Io, exec: []const u8, file_path: []const u8, box: u32) ?raster.Image {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const runtime = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
    const out = std.fmt.allocPrint(a, "{s}/fluxion-files-preview-{d}-{d}.png", .{ runtime, std.os.linux.getpid(), thumbnail_count.fetchAdd(1, .monotonic) }) catch return null;
    defer std.Io.Dir.cwd().deleteFile(io, out) catch {};
    var uri_buffer: [std.fs.max_path_bytes * 3 + 8]u8 = undefined;
    const uri = Thumbs.fileUri(file_path, &uri_buffer) orelse return null;
    var argv: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, exec, ' ');
    while (words.next()) |word| {
        var arg: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < word.len) : (i += 1) {
            if (word[i] != '%' or i + 1 == word.len) {
                arg.append(a, word[i]) catch return null;
                continue;
            }
            i += 1;
            switch (word[i]) {
                'u' => arg.appendSlice(a, uri) catch return null,
                'i' => arg.appendSlice(a, file_path) catch return null,
                'o' => arg.appendSlice(a, out) catch return null,
                's' => arg.print(a, "{d}", .{@min(box, 1024)}) catch return null,
                '%' => arg.append(a, '%') catch return null,
                else => {},
            }
        }
        argv.append(a, arg.items) catch return null;
    }
    if (argv.items.len == 0) return null;
    const result = std.process.run(a, io, .{ .argv = argv.items, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch return null;
    if (result.term != .exited or result.term.exited != 0) return null;
    return ImageFile.read(gpa, io, out) catch null;
}

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

test "media lengths read as Windows writes them" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("00:03:12", clockText(192_000, &buffer, true));
    try std.testing.expectEqualStrings("3:12", clockText(192_400, &buffer, false));
    try std.testing.expectEqualStrings("1:01:01", clockText(3_661_000, &buffer, false));
    try std.testing.expectApproxEqAbs(@as(f32, 29.97), ratio("30000/1001"), 0.01);
    try std.testing.expect(isCode("text/plain", "build.zig"));
    try std.testing.expect(!isCode("text/plain", "notes.txt"));
    try std.testing.expect(isText("application/json", "a.json"));
}
