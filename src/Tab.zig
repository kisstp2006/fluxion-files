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
    /// The Recycle Bin.
    trash,
    folder: []const u8,
    /// What a search in a folder found.
    search: Search,

    pub const Search = struct { folder: []const u8, query: []const u8 };

    pub fn eql(a: Location, b: Location) bool {
        return switch (a) {
            .home => b == .home,
            .this_pc => b == .this_pc,
            .trash => b == .trash,
            .folder => |p| b == .folder and std.mem.eql(u8, p, b.folder),
            .search => |q| b == .search and std.mem.eql(u8, q.folder, b.search.folder) and std.mem.eql(u8, q.query, b.search.query),
        };
    }

    pub fn dupe(self: Location, gpa: std.mem.Allocator) !Location {
        return switch (self) {
            .folder => |p| .{ .folder = try gpa.dupe(u8, p) },
            .search => |q| .{ .search = .{ .folder = try gpa.dupe(u8, q.folder), .query = try gpa.dupe(u8, q.query) } },
            else => self,
        };
    }

    pub fn free(self: Location, gpa: std.mem.Allocator) void {
        switch (self) {
            .folder => |p| gpa.free(p),
            .search => |q| {
                gpa.free(q.folder);
                gpa.free(q.query);
            },
            else => {},
        }
    }
};

/// A group of what is shown, under its heading: "Today", "A - H".
pub const Group = struct {
    label: [48]u8 = undefined,
    label_len: usize = 0,
    /// Its items: `count` of them in `shown`, from `first`.
    first: usize,
    count: usize = 0,
    folded: bool = false,

    pub fn name(self: *const Group) []const u8 {
        return self.label[0..self.label_len];
    }
};

/// Details' columns as they come: Name, Date modified, Type, Size.
pub const default_columns: u16 = 0b1111;

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
/// Grouped by a column, Windows' way - or not.
group_by: ?Folder.Column = null,
/// The columns Details shows, a bit each by `Folder.Column`; and how wide
/// each is dragged to - nought for its own width.
columns: u16 = default_columns,
widths: [Folder.column_count]u16 = @splat(0),
groups: std.ArrayList(Group) = .empty,
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
    self.groups.deinit(self.gpa);
}

/// Put in its place what this tab was, from `to` - for the search box,
/// which changes what is searched for without leaving another step back.
pub fn replace(self: *Tab, to: Location) void {
    const copy = to.dupe(self.gpa) catch return;
    self.location.free(self.gpa);
    self.location = copy;
    self.dropFolder();
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

/// The folder an entry is in: the tab's, or the entry's own - a search's
/// finding.
pub fn dirOf(self: *const Tab, e: *const Folder.Entry) ?[]const u8 {
    if (self.location == .trash) return null;
    return e.dir orelse self.path();
}

/// Whether it lists entries: a folder, a search's findings, the Recycle
/// Bin.
pub fn lists(self: *const Tab) bool {
    return switch (self.location) {
        .folder, .search, .trash => true,
        else => false,
    };
}

/// Whether the folder shown is inside a compressed folder: read, not
/// written.
pub fn inArchive(self: *const Tab) bool {
    const f = self.folder orelse return false;
    return f.archive != null;
}

/// Whether things can be made, pasted, renamed and deleted here.
pub fn writable(self: *const Tab) bool {
    return self.path() != null and !self.inArchive();
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
    if (self.location == .trash) return self.readTrash(io, mime, show_hidden);
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

/// The Recycle Bin read: the home's.
fn readTrash(self: *Tab, io: std.Io, mime: *Mime, show_hidden: bool) void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trash = @import("Ops.zig").homeTrash(&buffer) orelse return;
    if (self.folder) |*f| f.deinit();
    self.folder = Folder.readTrash(self.gpa, io, mime, trash);
    self.folder.?.sort(self.sort_by, self.ascending, mime);
    self.refilter(show_hidden);
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

/// Which entries are shown: all, or all but the hidden ones - in their
/// groups, where they are grouped.
pub fn refilter(self: *Tab, show_hidden: bool) void {
    self.shown.clearRetainingCapacity();
    self.selected.clearRetainingCapacity();
    // The groups folded stay folded, the folder read again.
    var folded: [16]Group = undefined;
    var folded_len: usize = 0;
    for (self.groups.items) |g| if (g.folded and folded_len < folded.len) {
        folded[folded_len] = g;
        folded_len += 1;
    };
    self.groups.clearRetainingCapacity();
    self.focus = null;
    self.anchor = null;
    const f = self.folder orelse return;
    for (f.entries.items, 0..) |e, i| {
        if (e.hidden and !show_hidden) continue;
        self.shown.append(self.gpa, @intCast(i)) catch break;
        self.selected.append(self.gpa, false) catch break;
    }
    const by = self.group_by orelse return;
    // In their groups' order, each keeping the sort's order inside it.
    const now = nowSeconds();
    const Context = struct {
        entries: []const Folder.Entry,
        by: Folder.Column,
        now: i64,
        fn lessThan(c: @This(), a: u32, b: u32) bool {
            return groupOf(&c.entries[a], c.by, c.now).rank < groupOf(&c.entries[b], c.by, c.now).rank;
        }
    };
    std.sort.block(u32, self.shown.items, Context{ .entries = f.entries.items, .by = by, .now = now }, Context.lessThan);
    var last: ?u16 = null;
    for (self.shown.items, 0..) |index, i| {
        const g = groupOf(&f.entries.items[index], by, now);
        if (last == null or last.? != g.rank) {
            var group: Group = .{ .first = i };
            group.label_len = @min(g.label.len, group.label.len);
            @memcpy(group.label[0..group.label_len], g.label[0..group.label_len]);
            for (folded[0..folded_len]) |was| {
                if (std.mem.eql(u8, was.name(), group.name())) group.folded = true;
            }
            self.groups.append(self.gpa, group) catch break;
            last = g.rank;
        }
        self.groups.items[self.groups.items.len - 1].count += 1;
    }
}

/// Group by `by`, or not.
pub fn groupBy(self: *Tab, by: ?Folder.Column, show_hidden: bool) void {
    self.group_by = by;
    self.refilter(show_hidden);
}

const GroupKey = struct { rank: u16, label: []const u8 };

/// The group an entry goes in, as Windows groups: dates by how long ago,
/// sizes by how big, names by their first letter, types by their name.
fn groupOf(e: *const Folder.Entry, by: Folder.Column, now: i64) GroupKey {
    switch (by) {
        .name => {
            const c = if (e.name.len > 0) std.ascii.toUpper(e.name[0]) else ' ';
            if (std.ascii.isDigit(c)) return .{ .rank = 0, .label = "0 - 9" };
            if (c >= 'A' and c <= 'H') return .{ .rank = 1, .label = "A - H" };
            if (c >= 'I' and c <= 'P') return .{ .rank = 2, .label = "I - P" };
            if (c >= 'Q' and c <= 'Z') return .{ .rank = 3, .label = "Q - Z" };
            return .{ .rank = 4, .label = "Other" };
        },
        .modified, .created, .accessed => {
            const stamp = switch (by) {
                .created => e.created,
                .accessed => e.accessed,
                else => e.mtime,
            };
            if (stamp == 0) return .{ .rank = 8, .label = "Unspecified" };
            const t: i64 = @intCast(@divFloor(stamp, std.time.ns_per_s));
            const day = 24 * 60 * 60;
            const today = now - @mod(now - localOffset(now), day);
            if (t >= today) return .{ .rank = 0, .label = "Today" };
            if (t >= today - day) return .{ .rank = 1, .label = "Yesterday" };
            if (t >= today - 6 * day) return .{ .rank = 2, .label = "Earlier this week" };
            if (t >= today - 13 * day) return .{ .rank = 3, .label = "Last week" };
            if (t >= today - 30 * day) return .{ .rank = 4, .label = "Earlier this month" };
            if (t >= today - 60 * day) return .{ .rank = 5, .label = "Last month" };
            if (t >= today - 365 * day) return .{ .rank = 6, .label = "Earlier this year" };
            return .{ .rank = 7, .label = "A long time ago" };
        },
        .size => {
            if (e.isFolder()) return .{ .rank = 7, .label = "Unspecified" };
            const s = e.size;
            if (s == 0) return .{ .rank = 0, .label = "Empty (0 KB)" };
            if (s < 16 << 10) return .{ .rank = 1, .label = "Tiny (0 - 16 KB)" };
            if (s < 1 << 20) return .{ .rank = 2, .label = "Small (16 KB - 1 MB)" };
            if (s < 128 << 20) return .{ .rank = 3, .label = "Medium (1 - 128 MB)" };
            if (s < 1 << 30) return .{ .rank = 4, .label = "Large (128 MB - 1 GB)" };
            if (s < 4 << 30) return .{ .rank = 5, .label = "Huge (1 - 4 GB)" };
            return .{ .rank = 6, .label = "Gigantic (> 4 GB)" };
        },
        .attributes => {
            if (e.mode != 0 and e.mode & 0o222 == 0) return .{ .rank = 0, .label = "Read-only" };
            if (e.hidden) return .{ .rank = 1, .label = "Hidden" };
            return .{ .rank = 2, .label = "Normal" };
        },
        .owner => {
            const mine = e.uid == std.os.linux.getuid();
            return if (mine) .{ .rank = 0, .label = "You" } else .{ .rank = 1, .label = "Others" };
        },
        // By kind: folders, then the media, then the rest.
        .type => {
            if (e.isFolder()) return .{ .rank = 0, .label = "File folder" };
            const m = e.mime;
            if (std.mem.startsWith(u8, m, "image/")) return .{ .rank = 1, .label = "Pictures" };
            if (std.mem.startsWith(u8, m, "video/")) return .{ .rank = 2, .label = "Videos" };
            if (std.mem.startsWith(u8, m, "audio/")) return .{ .rank = 3, .label = "Music" };
            if (std.mem.startsWith(u8, m, "text/")) return .{ .rank = 4, .label = "Text documents" };
            if (std.mem.indexOf(u8, m, "document") != null or std.mem.eql(u8, m, "application/pdf")) return .{ .rank = 5, .label = "Documents" };
            if (std.mem.indexOf(u8, m, "zip") != null or std.mem.indexOf(u8, m, "tar") != null or std.mem.indexOf(u8, m, "compressed") != null) return .{ .rank = 6, .label = "Compressed" };
            return .{ .rank = 7, .label = "Other" };
        },
    }
}

fn nowSeconds() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

/// The local time's offset from UTC now, in seconds: when today began.
fn localOffset(now: i64) i64 {
    var tm: Tm = undefined;
    if (localtime_r(&now, &tm) == null) return 0;
    return tm.gmtoff;
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
