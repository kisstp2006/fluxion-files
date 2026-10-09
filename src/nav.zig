// SPDX-License-Identifier: BSD-2-Clause

//! The navigation pane down the left, a tree as Windows' is:
//!
//! - **Windows 10's**: Quick access, opening to the person's folders and
//!   the ones pinned, each with its pin, and the Recycle Bin; This PC,
//!   opening to the same folders and the drives; Network. The chevrons
//!   show while the pointer is on the pane, as Windows 10 fades them in.
//! - **Windows 11's**: Home; the person's folders and the pinned ones,
//!   each with its pin, and the Recycle Bin; This PC, opening to the
//!   drives; Network.
//!
//! Any folder opens to the folders in it, read when it is opened. The place
//! shown is lit, as Windows lights it.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const chrome = @import("chrome.zig");
const icons = @import("icons.zig");

/// A folder opened in the tree, and the folders in it, read when it was.
pub const Opened = struct {
    path: []u8,
    children: [][]u8,

    pub fn free(self: Opened, gpa: std.mem.Allocator) void {
        for (self.children) |c| gpa.free(c);
        gpa.free(self.children);
        gpa.free(self.path);
    }
};

/// Whether `path` is opened in the tree, and where in the list.
fn openedAt(self: *Files, path: []const u8) ?usize {
    for (self.nav_opened.items, 0..) |o, i| if (std.mem.eql(u8, o.path, path)) return i;
    return null;
}

/// Open `path` in the tree - its folders read, by name as Windows sorts
/// them - or close it.
fn toggle(self: *Files, path: []const u8) void {
    if (openedAt(self, path)) |i| {
        self.nav_opened.orderedRemove(i).free(self.gpa);
        return;
    }
    const read = readFolders(self, path) orelse return;
    self.nav_opened.append(self.gpa, read) catch read.free(self.gpa);
}

/// The folders in `path`, by name as Windows sorts them.
pub fn readFolders(self: *Files, path: []const u8) ?Opened {
    var children: std.ArrayList([]u8) = .empty;
    if (std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true })) |opened_dir| {
        var dir = opened_dir;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (it.next(self.io) catch null) |entry| {
            if (entry.name[0] == '.' and !self.show_hidden) continue;
            const is_dir = entry.kind == .directory or (entry.kind == .sym_link and isDir(self, path, entry.name));
            if (!is_dir) continue;
            children.append(self.gpa, self.gpa.dupe(u8, entry.name) catch continue) catch {};
        }
    } else |_| {}
    std.sort.block([]u8, children.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return Folder.naturalOrder(a, b) == .lt;
        }
    }.lessThan);
    const owned = children.toOwnedSlice(self.gpa) catch return null;
    const copy = self.gpa.dupe(u8, path) catch {
        for (owned) |c| self.gpa.free(c);
        self.gpa.free(owned);
        return null;
    };
    return .{ .path = copy, .children = owned };
}

fn isDir(self: *Files, dir: []const u8, name: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ dir, name }) catch return false;
    const stat = std.Io.Dir.cwd().statFile(self.io, full, .{}) catch return false;
    return stat.kind == .directory;
}

/// Forget the tree: the folders it shows read again as they are opened.
pub fn forget(self: *Files) void {
    for (self.nav_opened.items) |o| o.free(self.gpa);
    self.nav_opened.clearRetainingCapacity();
}

/// Where a click in the pane goes, the frame it is clicked.
const Going = struct {
    to: ?Tab.Location = null,
    buffer: [std.fs.max_path_bytes]u8 = undefined,

    fn folder(self: *Going, path: []const u8) void {
        self.to = .{ .folder = std.fmt.bufPrint(&self.buffer, "{s}", .{path}) catch path };
    }
};

pub fn pane(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    u.open(.{
        .id = "nav",
        .width = .fixed(self.nav_width),
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .trbl(4, if (ten) 0 else 4, 4, if (ten) 0 else 4),
        .gap = 0,
        .background_color = chrome.contentColor(kit),
        .border = if (ten) .{} else .{ .color = p.divider, .width = .{ .right = 1 } },
        .clip = .{
            .vertical = true,
            .scroll_y = true,
            .no_drag_scroll = true,
            .scrollbar = .{ .width = if (ten) 8 else 6, .corner_radius = if (ten) 0 else 3, .thumb_color = p.text_tertiary, .hide_after_seconds = 1.5 },
        },
    });
    defer u.close();
    var going: Going = .{};
    const here = self.tab().location;
    // Windows 10 shows the chevrons only while the pointer is on the pane.
    const chevrons = !ten or u.isPointerOver("nav");

    if (ten) {
        switch (row(self, kit, "nav/home", 0, .{ .glyph = .star }, "Quick access", here == .home, if (chevrons) self.quick_open else null, false)) {
            .go => going.to = .home,
            .toggle => self.quick_open = !self.quick_open,
            .none => {},
        }
        if (self.quick_open) pinnedFolders(self, kit, &going, 1, chevrons);
        gap(kit);
        switch (row(self, kit, "nav/pc", 0, .{ .glyph = .desktop }, "This PC", here == .this_pc, if (chevrons) self.this_pc_open else null, false)) {
            .go => going.to = .this_pc,
            .toggle => self.this_pc_open = !self.this_pc_open,
            .none => {},
        }
        if (self.this_pc_open) {
            for (self.places.user.items, 0..) |f, i| folderRow(self, kit, &going, kit.print("nav/pc/user/{d}", .{i}), 1, f.path, f.name, icons.special(f.special), false, chevrons);
            drives(self, kit, &going, chevrons);
        }
        gap(kit);
        _ = row(self, kit, "nav/network", 0, .{ .glyph = .globe }, "Network", false, if (chevrons) false else null, false);
    } else {
        if (row(self, kit, "nav/home", 0, .{ .glyph = .home }, "Home", here == .home, null, false) == .go) going.to = .home;
        separator(kit);
        pinnedFolders(self, kit, &going, 0, chevrons);
        separator(kit);
        switch (row(self, kit, "nav/pc", 0, .{ .glyph = .desktop }, "This PC", here == .this_pc, self.this_pc_open, false)) {
            .go => going.to = .this_pc,
            .toggle => self.this_pc_open = !self.this_pc_open,
            .none => {},
        }
        if (self.this_pc_open) drives(self, kit, &going, chevrons);
        _ = row(self, kit, "nav/network", 0, .{ .glyph = .globe }, "Network", false, false, false);
    }
    if (going.to) |where| self.goTo(where);
}

/// The person's folders and the pinned ones, a pin at each; then the
/// Recycle Bin.
fn pinnedFolders(self: *Files, kit: *Kit, going: *Going, depth: u8, chevrons: bool) void {
    const here = self.tab().location;
    for (self.places.user.items, 0..) |f, i| folderRow(self, kit, going, kit.print("nav/user/{d}", .{i}), depth, f.path, f.name, icons.special(f.special), true, chevrons);
    for (self.places.pinned.items, 0..) |f, i| folderRow(self, kit, going, kit.print("nav/pin/{d}", .{i}), depth, f.path, f.name, "folder", true, chevrons);
    if (row(self, kit, "nav/trash", depth, .{ .themed = "user-trash" }, "Recycle Bin", here == .trash, null, false) == .go) going.to = .trash;
}

fn drives(self: *Files, kit: *Kit, going: *Going, chevrons: bool) void {
    for (self.places.drives.items, 0..) |d, i| {
        var name_buffer: [256]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s} ({s})", .{ d.label, d.mount }) catch d.label;
        folderRow(self, kit, going, kit.print("nav/drive/{d}", .{i}), 1, d.mount, name, if (d.removable) "drive-removable-media" else "drive-harddisk", false, chevrons);
    }
}

/// A folder's row, and - opened - the folders in it under it, each a
/// row that opens in turn.
fn folderRow(self: *Files, kit: *Kit, going: *Going, id: []const u8, depth: u8, path: []const u8, name: []const u8, icon: []const u8, pinned: bool, chevrons: bool) void {
    const here = self.tab().location;
    const lit = here == .folder and std.mem.eql(u8, here.folder, path);
    const opened = openedAt(self, path);
    // The id is a print of the kit's: kept before the rows under it print.
    var id_buffer: [128]u8 = undefined;
    const own_id = std.fmt.bufPrint(&id_buffer, "{s}", .{id}) catch id;
    switch (row(self, kit, own_id, depth, .{ .themed = icon }, name, lit, if (chevrons) opened != null else null, pinned)) {
        .go => going.folder(path),
        .toggle => {
            toggle(self, path);
            self.window.redraw();
            return;
        },
        .none => {},
    }
    const at = opened orelse return;
    // Deep enough: the tree is not a list of the whole disk.
    if (depth >= 12) return;
    const children = self.nav_opened.items[at].children;
    for (children, 0..) |child, k| {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ if (std.mem.eql(u8, path, "/")) "" else path, child }) catch continue;
        folderRow(self, kit, going, kit.print("{s}/{d}", .{ own_id, k }), depth + 1, full, child, icons.special(self.places.specialOf(full)), false, chevrons);
        // A row opened or closed under it: the list walked is not the same.
        if (at >= self.nav_opened.items.len or self.nav_opened.items[at].children.ptr != children.ptr) return;
    }
}

fn separator(kit: *Kit) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .padding = .xy(8, 6) });
    u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = kit.theme.palette.divider });
    u.close();
}

/// Windows 10 parts the tree's roots with a little room.
fn gap(kit: *Kit) void {
    kit.ui.empty(.{ .width = .grow, .height = .fixed(10) });
}

const Icon = union(enum) { glyph: widgets.icons.Name, themed: []const u8 };
const Clicked = enum { none, go, toggle };

/// A row of the tree: its chevron where it opens (`open` not null), its
/// icon and name, and - pinned - the pin at its end. Lit where it is shown.
fn row(self: *Files, kit: *Kit, id: []const u8, depth: u8, icon: Icon, name: []const u8, lit: bool, open: ?bool, pinned: bool) Clicked {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(if (ten) 22 else if (self.compact) 24 else 28),
        .padding = .trbl(0, 8, 0, (if (ten) @as(u16, 2) else 4) + (if (ten) @as(u16, 16) else 14) * @as(u16, depth)),
        .gap = if (ten) 4 else 6,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (lit)
            (if (ten) win10Selection(kit) else p.subtle_secondary)
        else if (!ten and u.isElementPressed(id))
            p.subtle_tertiary
        else if (hovered)
            (if (ten) win10Hover(kit) else p.subtle_secondary)
        else
            .transparent,
    });
    defer u.close();
    const chevron_id = kit.print("{s}/chevron", .{id});
    u.open(.{ .id = chevron_id, .width = .fixed(16), .height = .fixed(16), .align_x = .center, .align_y = .center });
    if (open) |is_open| {
        const ink = if (u.isPointerOver(chevron_id)) (if (ten) widgets.argb(0xFF1C97EA) else p.text_primary) else p.text_secondary;
        kit.icon(if (is_open) .chevron_down else .chevron_right, if (ten) 10 else 12, ink, .regular);
    }
    const on_chevron = open != null and u.isPointerOver(chevron_id);
    u.close();
    switch (icon) {
        .glyph => |g| kit.icon(g, 16, switch (g) {
            .star => widgets.argb(0xFF2B88D8),
            .home => p.accent_text,
            else => p.text_primary,
        }, if (g == .star) .filled else .regular),
        .themed => |n| icons.themed(self, kit, n, 16),
    }
    {
        u.open(.{ .width = .grow, .clip = .both, .padding = .trbl(0, 0, 0, 2) });
        defer u.close();
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .none;
        u.text(name, style);
    }
    if (pinned) kit.icon(.pin, if (ten) 10 else 12, p.text_secondary, .regular);
    if (!u.justReleased()) return .none;
    return if (on_chevron) .toggle else .go;
}

/// Windows 10's: light blue for what is chosen and under the pointer.
pub fn win10Selection(kit: *Kit) ui.Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF777777) else widgets.argb(0xFFCCE8FF);
}

pub fn win10Hover(kit: *Kit) ui.Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF4D4D4D) else widgets.argb(0xFFE5F3FF);
}
