// SPDX-License-Identifier: BSD-2-Clause

//! Drag and drop, through the seat's data device: files dragged out of the
//! window - to another folder in it, another window of it, the desktop, any
//! app - and dragged into it from anywhere.
//!
//! **What is dragged is a list of URIs**, `text/uri-list`, as every file
//! manager and toolkit drags files - and the paths as text beside it, for a
//! terminal or an editor. A drag out of the window and back into it is the
//! same drag: the window is a drop target like any other, and what it
//! dragged itself it already knows.
//!
//! **Where a drop goes is the content's to say**, as the drag moves: the
//! pointer is put where the drag is, the window drawn again - every hover
//! highlight then shows the folder under it - and the drawing answers with
//! `Window.answerDrop`. That answer goes to the dragging app as the action
//! it may take (copy or move) and whether a drop here is wanted at all.
//!
//! A drop is read on the window's loop, never waited for: the app that
//! sends it may be this one.

const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const raster = @import("fluxion_ui_raster");

const Window = @import("Window.zig");
const ShmBuffer = @import("ShmBuffer.zig");

const Dnd = @This();

const log = std.log.scoped(.dnd);

pub const Action = enum { none, copy, move };

/// What a drop here would do: the action, and where - a folder's path.
pub const Answer = struct {
    action: Action = .none,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    pub fn path(self: *const Answer) []const u8 {
        return self.path_buffer[0..self.path_len];
    }
};

/// A drag coming over the window: its offer, and what it carries.
const In = struct {
    offer: *wl.DataOffer,
    serial: u32,
    /// What the offer said it has, and the dragging app allows.
    uris: bool,
    source_actions: wl.DataDeviceManager.DndAction,
    /// What was last told the dragging app.
    told: Action = .none,
    told_set: bool = false,
    dropped: bool = false,
};

/// A drop being read: the pipe's end, what came so far, and where it goes.
const Reading = struct {
    offer: *wl.DataOffer,
    fd: std.c.fd_t,
    bytes: std.ArrayList(u8) = .empty,
    answer: Answer,
};

/// A drag this window started: what it offers, and the picture under the
/// pointer.
const Out = struct {
    source: *wl.DataSource,
    uri_list: []u8,
    text: []u8,
    icon: ?*wl.Surface = null,
    icon_buffer: ?*ShmBuffer = null,
};

/// Offers made known by the data device, and what each said it has, until
/// one is a drag's or the clipboard's.
const Pending = struct {
    offer: *wl.DataOffer,
    uris: bool = false,
    actions: wl.DataDeviceManager.DndAction = .{},
};

pending: std.ArrayList(*Pending) = .empty,
in: ?In = null,
reading: ?Reading = null,
out: ?Out = null,
/// What the drawing that just finished answered, and whether it was asked.
answer: Answer = .{},

pub fn deinit(self: *Dnd, window: *Window) void {
    for (self.pending.items) |p| {
        p.offer.destroy();
        window.gpa.destroy(p);
    }
    self.pending.deinit(window.gpa);
    if (self.in) |in| if (!in.dropped) in.offer.destroy();
    if (self.reading) |*r| self.endReading(window, r, false);
    self.endOut(window);
}

// -------------------------------------------------------------------------
// Into the window
// -------------------------------------------------------------------------

pub fn deviceListener(device: *wl.DataDevice, event: wl.DataDevice.Event, window: *Window) void {
    _ = device;
    const self = &window.dnd;
    switch (event) {
        .data_offer => |made| {
            const p = window.gpa.create(Pending) catch {
                made.id.destroy();
                return;
            };
            p.* = .{ .offer = made.id };
            self.pending.append(window.gpa, p) catch {
                window.gpa.destroy(p);
                made.id.destroy();
                return;
            };
            made.id.setListener(*Pending, offerListener, p);
        },
        .enter => |enter| {
            // A drag over another of this program's surfaces than the window
            // is nothing here.
            const offer = enter.id orelse return;
            const p = self.take(window, offer) orelse return;
            defer window.gpa.destroy(p);
            if (self.in) |old| if (!old.dropped) old.offer.destroy();
            self.in = .{ .offer = offer, .serial = enter.serial, .uris = p.uris, .source_actions = p.actions };
            window.dragAt(@floatCast(enter.x.toDouble()), @floatCast(enter.y.toDouble()));
        },
        .motion => |motion| {
            if (self.in == null) return;
            window.dragAt(@floatCast(motion.x.toDouble()), @floatCast(motion.y.toDouble()));
        },
        .leave => {
            if (self.in) |in| if (!in.dropped) in.offer.destroy();
            self.in = null;
            window.dragLeft();
        },
        .drop => self.drop(window),
        // The clipboard's offer: this window pastes only its own.
        .selection => |selection| if (selection.id) |offer| {
            if (self.take(window, offer)) |p| window.gpa.destroy(p);
            offer.destroy();
        },
    }
}

fn offerListener(_: *wl.DataOffer, event: wl.DataOffer.Event, p: *Pending) void {
    switch (event) {
        .offer => |o| if (std.mem.eql(u8, std.mem.span(o.mime_type), "text/uri-list")) {
            p.uris = true;
        },
        .source_actions => |a| p.actions = a.source_actions,
        .action => {},
    }
}

/// The pending offer `offer` is, taken off the list.
fn take(self: *Dnd, window: *Window, offer: *wl.DataOffer) ?*Pending {
    _ = window;
    for (self.pending.items, 0..) |p, i| if (p.offer == offer) {
        _ = self.pending.swapRemove(i);
        return p;
    };
    return null;
}

/// Whether the drag over the window carries files.
pub fn carriesFiles(self: *const Dnd) bool {
    const in = self.in orelse return false;
    return in.uris;
}

/// Tell the dragging app what the last drawing answered, if it changed.
pub fn tell(self: *Dnd) void {
    const in = &(self.in orelse return);
    if (in.dropped) return;
    var action = self.answer.action;
    // Only what the dragging app allows.
    if (action == .move and !in.source_actions.move) action = if (in.source_actions.copy) .copy else .none;
    if (action == .copy and !in.source_actions.copy) action = if (in.source_actions.move) .move else .none;
    if (!in.uris) action = .none;
    self.answer.action = action;
    if (in.told_set and in.told == action) return;
    in.told = action;
    in.told_set = true;
    in.offer.accept(in.serial, if (action != .none) "text/uri-list" else null);
    const chosen: wl.DataDeviceManager.DndAction = switch (action) {
        .none => .{},
        .copy => .{ .copy = true },
        .move => .{ .move = true },
    };
    in.offer.setActions(chosen, chosen);
}

fn drop(self: *Dnd, window: *Window) void {
    const in = &(self.in orelse return);
    in.dropped = true;
    const answer = self.answer;
    if (answer.action == .none or !in.uris or self.reading != null) {
        in.offer.destroy();
        self.in = null;
        window.dragLeft();
        return;
    }
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }) != 0) {
        in.offer.destroy();
        self.in = null;
        return;
    }
    in.offer.receive("text/uri-list", fds[1]);
    _ = std.c.close(fds[1]);
    self.reading = .{ .offer = in.offer, .fd = fds[0], .answer = answer };
    self.in = null;
    window.addWatch(.{ .fd = fds[0], .context = window, .ready = readable });
    window.dragLeft();
}

/// More of a drop has come: read; all of it, handed to the content.
fn readable(context: *anyopaque) void {
    const window: *Window = @ptrCast(@alignCast(context));
    const self = &window.dnd;
    const r = &(self.reading orelse return);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(r.fd, &buffer, buffer.len);
        if (n > 0) {
            r.bytes.appendSlice(window.gpa, buffer[0..@intCast(n)]) catch {
                self.endReading(window, r, false);
                return;
            };
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .AGAIN) return;
        break;
    }
    self.endReading(window, r, true);
}

fn endReading(self: *Dnd, window: *Window, r: *Reading, done: bool) void {
    window.removeWatch(r.fd);
    _ = std.c.close(r.fd);
    if (done) {
        var paths: std.ArrayList([]const u8) = .empty;
        defer {
            for (paths.items) |p| window.gpa.free(p);
            paths.deinit(window.gpa);
        }
        var lines = std.mem.tokenizeAny(u8, r.bytes.items, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue;
            const path = pathOfUri(window.gpa, line) orelse continue;
            paths.append(window.gpa, path) catch window.gpa.free(path);
        }
        if (paths.items.len > 0) window.dropped(paths.items, r.answer);
        r.offer.finish();
    }
    r.offer.destroy();
    r.bytes.deinit(window.gpa);
    self.reading = null;
}

/// The path a `file://` URI names, its `%XX` undone; null for any other.
pub fn pathOfUri(gpa: std.mem.Allocator, uri: []const u8) ?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // file://host/path: the host is this one.
    if (rest.len > 0 and rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }
    var out = gpa.alloc(u8, rest.len) catch return null;
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 3 <= rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |byte| {
                out[n] = byte;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        out[n] = rest[i];
        n += 1;
    }
    return gpa.realloc(out, n) catch out[0..n];
}

// -------------------------------------------------------------------------
// Out of the window
// -------------------------------------------------------------------------

/// Start dragging `paths` out from the press with `serial`, `picture` - if
/// any - under the pointer.
pub fn start(self: *Dnd, window: *Window, paths: []const []const u8, picture: ?raster.Image, serial: u32) void {
    const manager = window.data_manager orelse return;
    const device = window.data_device orelse return;
    if (paths.len == 0) return;
    self.endOut(window);
    var uri_list: std.ArrayList(u8) = .empty;
    var text: std.ArrayList(u8) = .empty;
    for (paths, 0..) |p, i| {
        appendUri(window.gpa, &uri_list, p) catch {};
        uri_list.appendSlice(window.gpa, "\r\n") catch {};
        if (i > 0) text.append(window.gpa, '\n') catch {};
        text.appendSlice(window.gpa, p) catch {};
    }
    const source = manager.createDataSource() catch return;
    source.offer("text/uri-list");
    source.offer("text/plain;charset=utf-8");
    source.offer("UTF8_STRING");
    source.setActions(.{ .copy = true, .move = true });
    source.setListener(*Window, sourceListener, window);
    self.out = .{
        .source = source,
        .uri_list = uri_list.toOwnedSlice(window.gpa) catch &.{},
        .text = text.toOwnedSlice(window.gpa) catch &.{},
    };
    // The picture under the pointer, its middle there.
    var icon: ?*wl.Surface = null;
    if (picture) |pic| if (window.compositor) |compositor| if (window.shm) |shm| {
        if (compositor.createSurface()) |surface| {
            if (ShmBuffer.create(window.gpa, shm, pic.width, pic.height)) |buffer| {
                @memcpy(buffer.pixels[0..pic.pixels.len], pic.pixels);
                self.out.?.icon_buffer = buffer;
                icon = surface;
            } else |_| surface.destroy();
        } else |_| {}
    };
    self.out.?.icon = icon;
    device.startDrag(source, window.surface, icon, serial);
    if (icon) |surface| {
        const buffer = self.out.?.icon_buffer.?;
        surface.attach(buffer.wl_buffer, -@as(i32, @intCast(buffer.width / 2)), -@as(i32, @intCast(buffer.height / 2)));
        surface.damageBuffer(0, 0, @intCast(buffer.width), @intCast(buffer.height));
        surface.commit();
    }
}

/// Whether this window is dragging something out.
pub fn dragging(self: *const Dnd) bool {
    return self.out != null;
}

fn sourceListener(source: *wl.DataSource, event: wl.DataSource.Event, window: *Window) void {
    const self = &window.dnd;
    const out = self.out orelse {
        if (event == .cancelled or event == .dnd_finished) source.destroy();
        return;
    };
    if (out.source != source) return;
    switch (event) {
        .send => |send| {
            defer _ = std.c.close(send.fd);
            const wanted = std.mem.span(send.mime_type);
            const data = if (std.mem.eql(u8, wanted, "text/uri-list")) out.uri_list else out.text;
            var written: usize = 0;
            while (written < data.len) {
                const n = std.c.write(send.fd, data[written..].ptr, data.len - written);
                if (n <= 0) break;
                written += @intCast(n);
            }
        },
        // Dropped and done with, or given up: what moved, moved - the
        // folder hears of it from the files themselves.
        .dnd_finished, .cancelled => {
            self.endOut(window);
            window.redraw();
        },
        else => {},
    }
}

fn endOut(self: *Dnd, window: *Window) void {
    const out = self.out orelse return;
    out.source.destroy();
    if (out.icon) |surface| surface.destroy();
    if (out.icon_buffer) |buffer| buffer.destroy(window.gpa);
    window.gpa.free(out.uri_list);
    window.gpa.free(out.text);
    self.out = null;
}

/// `file://` and `path`, every byte but the safe ones as `%XX`.
fn appendUri(gpa: std.mem.Allocator, out: *std.ArrayList(u8), path: []const u8) !void {
    try out.appendSlice(gpa, "file://");
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(gpa, c);
        } else try out.print(gpa, "%{X:0>2}", .{c});
    }
}

test "a dropped URI is the path it names" {
    const gpa = std.testing.allocator;
    const a = pathOfUri(gpa, "file:///home/p/My%20Files/caf%C3%A9.txt").?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("/home/p/My Files/café.txt", a);
    const b = pathOfUri(gpa, "file://localhost/tmp/x").?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("/tmp/x", b);
    try std.testing.expect(pathOfUri(gpa, "https://example.org/a") == null);
}

test "a path dragged out is a URI with its unsafe bytes escaped" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendUri(gpa, &out, "/home/p/My Files/a#b.txt");
    try std.testing.expectEqualStrings("file:///home/p/My%20Files/a%23b.txt", out.items);
}
