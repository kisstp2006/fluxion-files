// SPDX-License-Identifier: BSD-2-Clause

//! Pictures of files made small: a photo for the preview and the details
//! pane, read once and kept in one texture slot of the window's, its shape
//! kept - each new pixel the average of the ones it covers.

const std = @import("std");
const raster = @import("fluxion_ui_raster");

const ImageFile = @import("ImageFile.zig");
const Icons = @import("Icons.zig");

const Thumbs = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// The picture shown now: of which file, at what size, in which slot.
path_buffer: [std.fs.max_path_bytes]u8 = undefined,
path_len: usize = 0,
box: [2]u32 = .{ 0, 0 },
slot: ?u32 = null,
/// Its size as made, and the file's own.
size: [2]u32 = .{ 0, 0 },
source_size: [2]u32 = .{ 0, 0 },
failed: bool = false,

/// The picture of `path`, at most `w` by `h`, as a texture of `icons` -
/// read again only when the file or the room changes. Null for a file that
/// is no picture this can read.
pub fn picture(self: *Thumbs, icons: *Icons, path: []const u8, w: u32, h: u32) ?u32 {
    if (std.mem.eql(u8, self.path_buffer[0..self.path_len], path) and self.box[0] == w and self.box[1] == h) {
        return if (self.failed) null else self.slot;
    }
    self.path_len = @min(path.len, self.path_buffer.len);
    @memcpy(self.path_buffer[0..self.path_len], path[0..self.path_len]);
    self.box = .{ w, h };
    self.failed = true;
    if (!ImageFile.named(path)) return null;
    var source = ImageFile.read(self.gpa, self.io, path) catch return null;
    defer source.deinit(self.gpa);
    self.source_size = .{ source.width, source.height };
    const small = fit(self.gpa, source, w, h) catch return null;
    self.size = .{ small.width, small.height };
    self.slot = icons.put(self.slot, small) orelse return null;
    self.failed = false;
    return self.slot;
}

/// Many pictures at once, for the large icon views and Tiles, as Windows
/// shows a photo as itself: each made on a thread of its own - from the
/// system's thumbnail cache where an app made one before (the freedesktop
/// spec's `~/.cache/thumbnails`), from the file otherwise - and kept in a
/// few of the window's texture slots, the longest unseen given up first.
pub const Gallery = struct {
    /// How many are kept: more than two screens of Large icons.
    const most = 160;
    /// A file bigger than this is not read for its picture.
    const largest_file = 48 << 20;

    gpa: std.mem.Allocator,
    io: std.Io,
    /// The window's pipe: a byte written wakes it to take what was made.
    wake: std.c.fd_t,
    /// Where the system's thumbnails are: `$XDG_CACHE_HOME/thumbnails`.
    cache_buffer: [std.fs.max_path_bytes]u8 = undefined,
    cache_len: usize = 0,
    kept: std.ArrayList(Kept) = .empty,
    spare: std.ArrayList(u32) = .empty,
    clock: u64 = 0,
    shared: Shared = .{},

    const State = enum { asked, made, none };
    const Kept = struct { key: u64, slot: ?u32 = null, size: [2]u32 = .{ 0, 0 }, state: State = .asked, seen: u64 };
    const Ask = struct { key: u64, path: []u8, box: u32 };
    const Made = struct { key: u64, picture: ?raster.Image };

    /// What the thread and the window both touch, under the lock.
    const Shared = struct {
        mutex: std.Io.Mutex = .init,
        asked: std.ArrayList(Ask) = .empty,
        made: std.ArrayList(Made) = .empty,
        running: bool = false,
        cancel: std.atomic.Value(bool) = .init(false),
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, wake: std.c.fd_t) Gallery {
        var self: Gallery = .{ .gpa = gpa, .io = io, .wake = wake };
        const cache = if (std.c.getenv("XDG_CACHE_HOME")) |d|
            std.fmt.bufPrint(&self.cache_buffer, "{s}/thumbnails", .{std.mem.span(d)}) catch ""
        else if (std.c.getenv("HOME")) |h|
            std.fmt.bufPrint(&self.cache_buffer, "{s}/.cache/thumbnails", .{std.mem.span(h)}) catch ""
        else
            "";
        self.cache_len = cache.len;
        return self;
    }

    pub fn deinit(self: *Gallery) void {
        self.shared.cancel.store(true, .release);
        while (true) {
            self.shared.mutex.lockUncancelable(self.io);
            const running = self.shared.running;
            self.shared.mutex.unlock(self.io);
            if (!running) break;
            std.Thread.yield() catch {};
        }
        for (self.shared.asked.items) |a| self.gpa.free(a.path);
        self.shared.asked.deinit(self.gpa);
        for (self.shared.made.items) |*m| if (m.picture) |*image| image.deinit(self.gpa);
        self.shared.made.deinit(self.gpa);
        self.kept.deinit(self.gpa);
        self.spare.deinit(self.gpa);
    }

    fn keyOf(path: []const u8, box: u32) u64 {
        var h = std.hash.Wyhash.init(box);
        h.update(path);
        return h.final();
    }

    /// The picture of `path`, at most `box` across, if it is made: asked
    /// for, the first time, and null until it is.
    pub fn picture(self: *Gallery, path: []const u8, box: u32) ?struct { slot: u32, size: [2]u32 } {
        self.clock += 1;
        const key = keyOf(path, box);
        for (self.kept.items) |*k| if (k.key == key) {
            k.seen = self.clock;
            if (k.state != .made) return null;
            return .{ .slot = k.slot orelse return null, .size = k.size };
        };
        if (self.kept.items.len >= most) self.forgetOldest();
        self.kept.append(self.gpa, .{ .key = key, .seen = self.clock }) catch return null;
        const copy = self.gpa.dupe(u8, path) catch return null;
        self.shared.mutex.lockUncancelable(self.io);
        defer self.shared.mutex.unlock(self.io);
        self.shared.asked.append(self.gpa, .{ .key = key, .path = copy, .box = box }) catch {
            self.gpa.free(copy);
            return null;
        };
        if (!self.shared.running) {
            const thread = std.Thread.spawn(.{}, work, .{self}) catch return null;
            thread.detach();
            self.shared.running = true;
        }
        return null;
    }

    /// The one seen longest ago given up, its slot kept for the next.
    fn forgetOldest(self: *Gallery) void {
        var oldest: usize = 0;
        for (self.kept.items, 0..) |k, i| {
            if (k.state == .asked) continue;
            if (self.kept.items[oldest].state == .asked or k.seen < self.kept.items[oldest].seen) oldest = i;
        }
        const gone = self.kept.swapRemove(oldest);
        if (gone.slot) |slot| self.spare.append(self.gpa, slot) catch {};
    }

    /// What the thread made, into the window's slots. Whether anything was.
    pub fn take(self: *Gallery, icons: *Icons) bool {
        self.shared.mutex.lockUncancelable(self.io);
        const made = self.shared.made.toOwnedSlice(self.gpa) catch &.{};
        self.shared.mutex.unlock(self.io);
        defer self.gpa.free(made);
        for (made) |m| {
            const k = for (self.kept.items) |*k| {
                if (k.key == m.key) break k;
            } else {
                if (m.picture) |p| {
                    var gone = p;
                    gone.deinit(self.gpa);
                }
                continue;
            };
            const p = m.picture orelse {
                k.state = .none;
                continue;
            };
            k.size = .{ p.width, p.height };
            k.slot = icons.put(self.spare.pop(), p);
            k.state = if (k.slot != null) .made else .none;
        }
        return made.len > 0;
    }

    fn work(self: *Gallery) void {
        while (true) {
            self.shared.mutex.lockUncancelable(self.io);
            const next = if (self.shared.asked.items.len > 0 and !self.shared.cancel.load(.acquire)) self.shared.asked.orderedRemove(0) else null;
            if (next == null) self.shared.running = false;
            self.shared.mutex.unlock(self.io);
            const ask = next orelse return;
            defer self.gpa.free(ask.path);
            const made = self.make(ask.path, ask.box);
            self.shared.mutex.lockUncancelable(self.io);
            self.shared.made.append(self.gpa, .{ .key = ask.key, .picture = made }) catch if (made) |p| {
                var gone = p;
                gone.deinit(self.gpa);
            };
            self.shared.mutex.unlock(self.io);
            _ = std.c.write(self.wake, "t", 1);
        }
    }

    fn make(self: *Gallery, path: []const u8, box: u32) ?raster.Image {
        var source = self.cached(path, box) orelse source: {
            if (!ImageFile.named(path)) return null;
            const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return null;
            if (stat.size > largest_file) return null;
            break :source ImageFile.read(self.gpa, self.io, path) catch return null;
        };
        defer source.deinit(self.gpa);
        return fit(self.gpa, source, box, box) catch null;
    }

    /// The thumbnail an app left in the system's cache: named for the MD5
    /// of the file's URI, 256 pixels in large/, 128 in normal/.
    fn cached(self: *Gallery, path: []const u8, box: u32) ?raster.Image {
        if (self.cache_len == 0) return null;
        var uri_buffer: [std.fs.max_path_bytes * 3 + 8]u8 = undefined;
        const uri = fileUri(path, &uri_buffer) orelse return null;
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(uri, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        const sizes: []const []const u8 = if (box > 128) &.{ "large", "x-large", "normal" } else &.{ "normal", "large" };
        for (sizes) |size| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const file = std.fmt.bufPrint(&buffer, "{s}/{s}/{s}.png", .{ self.cache_buffer[0..self.cache_len], size, hex }) catch continue;
            return ImageFile.read(self.gpa, self.io, file) catch continue;
        }
        return null;
    }
};

/// `file://` and the path, as the thumbnail spec hashes it: every byte
/// but the unreserved ones and `/` written as %XX.
pub fn fileUri(path: []const u8, buffer: []u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    w.writeAll("file://") catch return null;
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            w.writeByte(c) catch return null;
        } else w.print("%{X:0>2}", .{c}) catch return null;
    }
    return w.buffered();
}

/// `source` made to fit `w` by `h`, its shape kept; never made larger.
pub fn fit(gpa: std.mem.Allocator, source: raster.Image, w: u32, h: u32) !raster.Image {
    if (source.width == 0 or source.height == 0) return error.EmptyPicture;
    const scale = @min(1.0, @min(@as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(source.width)), @as(f64, @floatFromInt(h)) / @as(f64, @floatFromInt(source.height))));
    const out_w: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(source.width)) * scale))));
    const out_h: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(source.height)) * scale))));
    const pixels = try gpa.alloc(raster.Pixel, @as(usize, out_w) * out_h);
    for (0..out_h) |y| for (0..out_w) |x| {
        const x0 = x * source.width / out_w;
        const x1 = @max(x0 + 1, (x + 1) * source.width / out_w);
        const y0 = y * source.height / out_h;
        const y1 = @max(y0 + 1, (y + 1) * source.height / out_h);
        var sum: [4]u64 = @splat(0);
        for (y0..y1) |sy| for (x0..x1) |sx| {
            const p = source.pixels[sy * source.width + sx];
            inline for (0..4) |c| sum[c] += (p >> (c * 8)) & 0xFF;
        };
        const n = (x1 - x0) * (y1 - y0);
        var out: u32 = 0;
        inline for (0..4) |c| out |= @as(u32, @intCast((sum[c] + n / 2) / n)) << (c * 8);
        pixels[y * out_w + x] = out;
    };
    return .{ .pixels = pixels, .width = out_w, .height = out_h };
}

test "a thumbnail is found by its file's URI" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("file:///home/a%20b/c%C3%A9.png", fileUri("/home/a b/c\xc3\xa9.png", &buffer).?);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash("file:///home/jens/photos/me.png", &digest, .{});
    // The spec's own example.
    try std.testing.expectEqualStrings("c6ee772d9e49320e97ec29a7eb5b1697", &std.fmt.bytesToHex(digest, .lower));
}

test "a picture is made to fit, its shape kept" {
    const gpa = std.testing.allocator;
    const pixels = try gpa.alloc(raster.Pixel, 400 * 200);
    defer gpa.free(pixels);
    @memset(pixels, 0xFF336699);
    var small = try fit(gpa, .{ .pixels = pixels, .width = 400, .height = 200 }, 100, 100);
    defer small.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 100), small.width);
    try std.testing.expectEqual(@as(u32, 50), small.height);
    try std.testing.expectEqual(@as(u32, 0xFF336699), small.pixels[0]);
}
