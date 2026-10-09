// SPDX-License-Identifier: BSD-2-Clause

//! One tab - or, in Windows 10's look, the window itself: where it is,
//! where it was (back and forward), the folder as read, how it is shown
//! (the view, the sort) and what of it is chosen.

const std = @import("std");

const Folder = @import("Folder.zig");
const Mime = @import("Mime.zig");

const Tab = @This();

pub const Location = union(enum) {
    /// Windows 11's Home, Windows 10's Quick access.
    home,
    /// This PC: the user's folders and the drives.
    this_pc,
    folder: []const u8,

    pub fn eql(a: Location, b: Location) bool {
        return switch (a) {
            .home => b == .home,
            .this_pc => b == .this_pc,
            .folder => |p| b == .folder and std.mem.eql(u8, p, b.folder),
        };
    }

    fn dupe(self: Location, gpa: std.mem.Allocator) !Location {
        return switch (self) {
            .folder => |p| .{ .folder = try gpa.dupe(u8, p) },
            else => self,
        };
    }

    fn free(self: Location, gpa: std.mem.Allocator) void {
        switch (self) {
            .folder => |p| gpa.free(p),
            else => {},
        }
    }
};

/// Windows' eight views, in Ctrl+Shift+1…8's order.
pub const View = enum { extra_large, large, medium, small, list, details, tiles, content };

gpa: std.mem.Allocator,
location: Location = .home,
back_stack: std.ArrayList(Location) = .empty,
forward_stack: std.ArrayList(Location) = .empty,
folder: ?Folder = null,
view: View = .details,
sort_by: Folder.Column = .name,
ascending: bool = true,
/// The entries shown - the folder's, hidden ones left out unless asked for -
/// as indices into the folder's, in order.
shown: std.ArrayList(u32) = .empty,
/// Chosen, by place in `shown`.
selected: std.ArrayList(bool) = .empty,
/// The item the keyboard is on, and where a Shift range is from.
focus: ?usize = null,
anchor: ?usize = null,
/// The focus moved by the keyboard: scrolled to where it can be seen.
reveal: bool = false,
/// What has been typed to find an item by its name, and when.
typed: [64]u8 = undefined,
typed_len: usize = 0,
typed_ms: i64 = 0,

pub fn deinit(self: *Tab) void {
    if (self.folder) |*f| f.deinit();
    self.location.free(self.gpa);
    for (self.back_stack.items) |l| l.free(self.gpa);
    for (self.forward_stack.items) |l| l.free(self.gpa);
    self.back_stack.deinit(self.gpa);
    self.forward_stack.deinit(self.gpa);
    self.shown.deinit(self.gpa);
    self.selected.deinit(self.gpa);
}

/// Go to `to`, the place left kept for Back - unless it is where it is.
pub fn go(self: *Tab, to: Location) void {
    if (self.location.eql(to)) return;
    const copy = to.dupe(self.gpa) catch return;
    self.back_stack.append(self.gpa, self.location) catch {
        self.location.free(self.gpa);
    };
    for (self.forward_stack.items) |l| l.free(self.gpa);
    self.forward_stack.clearRetainingCapacity();
    self.location = copy;
    self.dropFolder();
}

pub fn canGoBack(self: *const Tab) bool {
    return self.back_stack.items.len > 0;
}

pub fn canGoForward(self: *const Tab) bool {
    return self.forward_stack.items.len > 0;
}

pub fn goBack(self: *Tab) void {
    const to = self.back_stack.pop() orelse return;
    self.forward_stack.append(self.gpa, self.location) catch self.location.free(self.gpa);
    self.location = to;
    self.dropFolder();
}

pub fn goForward(self: *Tab) void {
    const to = self.forward_stack.pop() orelse return;
    self.back_stack.append(self.gpa, self.location) catch self.location.free(self.gpa);
    self.location = to;
    self.dropFolder();
}

/// The folder it is in, if it is in one.
pub fn path(self: *const Tab) ?[]const u8 {
    return switch (self.location) {
        .folder => |p| p,
        else => null,
    };
}

/// The folder holding the one shown: none above the root.
pub fn parentPath(self: *const Tab) ?[]const u8 {
    const p = self.path() orelse return null;
    if (std.mem.eql(u8, p, "/")) return null;
    return std.fs.path.dirname(p) orelse "/";
}

fn dropFolder(self: *Tab) void {
    if (self.folder) |*f| f.deinit();
    self.folder = null;
    self.shown.clearRetainingCapacity();
    self.selected.clearRetainingCapacity();
    self.focus = null;
    self.anchor = null;
}

/// The folder read - again, for F5 or a change on disk - keeping what was
/// chosen by name.
pub fn read(self: *Tab, io: std.Io, mime: *Mime, show_hidden: bool) void {
    const p = self.path() orelse return;
    // What was chosen, by name, to choose again.
    var keep: std.ArrayList([]const u8) = .empty;
    defer {
        for (keep.items) |n| self.gpa.free(n);
        keep.deinit(self.gpa);
    }
    var focus_name: ?[]u8 = null;
    defer if (focus_name) |n| self.gpa.free(n);
    if (self.folder) |f| {
        for (self.shown.items, 0..) |index, i| {
            const name = f.entries.items[index].name;
            if (i < self.selected.items.len and self.selected.items[i]) keep.append(self.gpa, self.gpa.dupe(u8, name) catch continue) catch {};
            if (self.focus == i) focus_name = self.gpa.dupe(u8, name) catch null;
        }
    }
    if (self.folder) |*f| f.deinit();
    self.folder = Folder.read(self.gpa, io, mime, p);
    self.folder.?.sort(self.sort_by, self.ascending, mime);
    self.refilter(show_hidden);
    for (self.shown.items, 0..) |index, i| {
        const name = self.folder.?.entries.items[index].name;
        for (keep.items) |k| if (std.mem.eql(u8, k, name)) {
            self.selected.items[i] = true;
        };
        if (focus_name) |n| if (std.mem.eql(u8, n, name)) {
            self.focus = i;
        };
    }
}

/// Sorted again by `by` - the same column again turns the order round.
pub fn sortBy(self: *Tab, by: Folder.Column, mime: *Mime, show_hidden: bool) void {
    if (self.sort_by == by) self.ascending = !self.ascending else {
        self.sort_by = by;
        // Dates and sizes newest and largest first, as Windows starts them.
        self.ascending = by == .name or by == .type;
    }
    if (self.folder) |*f| f.sort(self.sort_by, self.ascending, mime);
    self.refilter(show_hidden);
}

/// Which entries are shown: all, or all but the hidden ones.
pub fn refilter(self: *Tab, show_hidden: bool) void {
    self.shown.clearRetainingCapacity();
    self.selected.clearRetainingCapacity();
    self.focus = null;
    self.anchor = null;
    const f = self.folder orelse return;
    for (f.entries.items, 0..) |e, i| {
        if (e.hidden and !show_hidden) continue;
        self.shown.append(self.gpa, @intCast(i)) catch break;
        self.selected.append(self.gpa, false) catch break;
    }
}

pub fn entry(self: *const Tab, i: usize) *Folder.Entry {
    return &self.folder.?.entries.items[self.shown.items[i]];
}

pub fn count(self: *const Tab) usize {
    return self.shown.items.len;
}

pub fn selectedCount(self: *const Tab) usize {
    var n: usize = 0;
    for (self.selected.items) |s| n += @intFromBool(s);
    return n;
}

/// The size of what is chosen - files only, as Windows adds them.
pub fn selectedSize(self: *const Tab) u64 {
    var total: u64 = 0;
    for (self.selected.items, 0..) |s, i| {
        if (!s) continue;
        const e = self.entry(i);
        if (!e.isFolder()) total += e.size;
    }
    return total;
}

/// A click on item `i`: it alone, Ctrl added to or taken from what is
/// chosen, Shift everything from the anchor to it.
pub fn click(self: *Tab, i: usize, ctrl: bool, shift: bool) void {
    if (i >= self.selected.items.len) return;
    if (shift) {
        const from = self.anchor orelse i;
        if (!ctrl) @memset(self.selected.items, false);
        const lo = @min(from, i);
        const hi = @max(from, i);
        for (self.selected.items[lo .. hi + 1]) |*s| s.* = true;
    } else if (ctrl) {
        self.selected.items[i] = !self.selected.items[i];
        self.anchor = i;
    } else {
        @memset(self.selected.items, false);
        self.selected.items[i] = true;
        self.anchor = i;
    }
    self.focus = i;
}

pub fn selectNone(self: *Tab) void {
    @memset(self.selected.items, false);
}

pub fn selectAll(self: *Tab) void {
    @memset(self.selected.items, true);
}

pub fn invertSelection(self: *Tab) void {
    for (self.selected.items) |*s| s.* = !s.*;
}

/// The keyboard moves the focus by `by` items - Shift choosing the range
/// from the anchor, Ctrl moving it alone.
pub fn moveFocus(self: *Tab, by: isize, ctrl: bool, shift: bool) void {
    const n = self.count();
    if (n == 0) return;
    const from: isize = if (self.focus) |f| @intCast(f) else if (by > 0) -1 else @intCast(n);
    const to: usize = @intCast(std.math.clamp(from + by, 0, @as(isize, @intCast(n - 1))));
    if (ctrl and !shift) {
        self.focus = to;
    } else self.click(to, false, shift);
    self.reveal = true;
}

/// Typed letters: the next item whose name starts with all that was typed
/// lately - or, the same letter again and again, the next with it.
pub fn typeAhead(self: *Tab, text: []const u8, now_ms: i64) void {
    if (now_ms - self.typed_ms > 1000) self.typed_len = 0;
    self.typed_ms = now_ms;
    const n = @min(text.len, self.typed.len - self.typed_len);
    @memcpy(self.typed[self.typed_len .. self.typed_len + n], text[0..n]);
    self.typed_len += n;
    const typed = self.typed[0..self.typed_len];
    const same_letter = typed.len > 1 and std.mem.allEqual(u8, typed, typed[0]);
    const want = if (same_letter) typed[0..1] else typed;
    const total = self.count();
    if (total == 0) return;
    const start = if (self.focus) |f| (if (same_letter or typed.len == 1) f + 1 else f) else 0;
    for (0..total) |k| {
        const i = (start + k) % total;
        if (std.ascii.startsWithIgnoreCase(self.entry(i).name, want)) {
            self.click(i, false, false);
            self.reveal = true;
            return;
        }
    }
}

/// The first chosen item, or the focused one.
pub fn current(self: *const Tab) ?usize {
    for (self.selected.items, 0..) |s, i| if (s) return i;
    return self.focus;
}
