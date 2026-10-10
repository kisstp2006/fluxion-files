// SPDX-License-Identifier: BSD-2-Clause

//! The right-click menus and the questions asked over the window.
//!
//! **Windows 11's menu** for what is chosen has the commonest commands as a
//! row of glyphs along its top - Cut, Copy, Paste, Rename, Share, Delete -
//! then Open, Open with, Open in new tab, Pin to Quick access, Compress to
//! ZIP file, Copy as path, Properties, Open in Terminal, and "Show more
//! options" for the full one. **Windows 10's**, and Windows 11's "more", is
//! that full one: the classic menu - a light grey list of short rows, the
//! glyphs in a gutter - with Send to, Cut and Copy, Create shortcut, Delete,
//! Rename and Properties. A right click on the folder itself offers View,
//! Sort by and Group by, Refresh, Paste, Open in Terminal, New and
//! Properties; in the Recycle Bin, Restore and Empty Recycle Bin.
//!
//! A row with "›" opens its own menu beside it as the pointer comes to it.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;
const Glyph = widgets.icons.Name;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const Ops = @import("Ops.zig");
const actions = @import("actions.zig");
const apps_mod = @import("apps.zig");
const icons = @import("icons.zig");

const menu_id = "context";
const sub_id = "context/sub";

/// The menus a row opens beside it.
pub const Sub = enum { none, view, sort, group, new, send_to, open_with, show };

/// Drawing the menu beside, not the menu itself: a row under the pointer
/// there keeps it open.
var in_sub = false;

/// The menu a right click asked for: open it where the pointer was, for
/// what it was on.
pub fn openAt(self: *Files, at: [2]f32, on_item: bool) void {
    self.context_open = at;
    self.context_on_item = on_item;
    self.context_sub = .none;
    self.menu = .none;
}

pub fn context(self: *Files, kit: *Kit) void {
    const at = self.context_open orelse return;
    const u = kit.ui;
    // A press anywhere else closes it - the press is answered as well.
    if (self.window.down and !u.isPointerOver(menu_id) and !u.isPointerOver(sub_id) and !u.isPointerOver("context/row")) {
        self.context_open = null;
        self.context_sub = .none;
        return;
    }
    // Kept on the window: up or left of the pointer where it would run off.
    const w: f32 = @floatFromInt(self.window.width);
    const h: f32 = @floatFromInt(self.window.height);
    const box = self.window.boxOf(menu_id);
    const mw = if (box) |b| b.width else 280;
    const mh = if (box) |b| b.height else 300;
    const x = if (at[0] + mw > w - 4) @max(4, at[0] - mw) else at[0];
    const y = if (at[1] + mh > h - 4) @max(4, at[1] - mh) else at[1];
    begin(self, kit, menu_id, .{ .attach = .root, .offset = .{ .x = x, .y = y }, .z_index = 80 });
    defer end(kit);
    const t = self.tab();
    const full = self.ten() or self.context_more;
    if (t.location == .trash) {
        if (self.context_on_item) trashItemMenu(self, kit) else trashMenu(self, kit);
    } else if (self.context_on_item) {
        if (full) itemMenuFull(self, kit) else itemMenu(self, kit);
    } else if (full) folderMenuFull(self, kit) else folderMenu(self, kit);
}

fn done(self: *Files) void {
    self.context_open = null;
    self.context_more = false;
    self.context_sub = .none;
    // A row of a menu beside a dropdown's closes the dropdown too.
    self.menu = .none;
    self.window.redraw();
}

// -------------------------------------------------------------------------
// The menu's look: Windows 11's, or Windows 10's classic one
// -------------------------------------------------------------------------

fn classicFill(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF2B2B2B) else widgets.argb(0xFFF2F2F2);
}

fn classicEdge(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF454545) else widgets.argb(0xFFCCCCCC);
}

fn classicHover(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF414141) else widgets.argb(0xFF91C9F7).withAlpha(0.45);
}

pub fn begin(self: *Files, kit: *Kit, id: []const u8, floating: ui.layout.Floating) void {
    if (!self.ten()) return kit.menuBegin(id, floating);
    var float = floating;
    if (float.z_index == 0) float.z_index = 100;
    float.keep_on_screen = true;
    kit.ui.open(.{
        .id = id,
        .width = .fitBetween(220, 480),
        .direction = .top_to_bottom,
        .padding = .all(2),
        .background_color = classicFill(kit),
        .border = .{ .color = classicEdge(kit), .width = .all(1) },
        .shadow = kit.elevation(.tooltip),
        .floating = float,
    });
}

pub fn end(kit: *Kit) void {
    kit.menuEnd();
}

pub const Row = struct {
    icon: ?Glyph = null,
    /// The icon theme's picture: a folder's, a drive's.
    themed: ?[]const u8 = null,
    /// An app's own icon, by its texture.
    image: ?u32 = null,
    shortcut: ?[]const u8 = null,
    disabled: bool = false,
    /// What a double click does, in bold - as Windows marks Open.
    strong: bool = false,
    /// Windows 11's menus mark in a column of their own before the glyph:
    /// null for a menu without one; the dot for `chosen`, a tick for
    /// `ticked`.
    marked: ?bool = null,
    ticked: bool = false,
    /// Opens a menu beside it.
    sub: Sub = .none,
};

/// A row: its glyph, its words, its keys or "›". True on the frame it is
/// clicked; a row with a menu beside opens it as the pointer comes.
pub fn row(self: *Files, kit: *Kit, id: []const u8, content: []const u8, o: Row) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const live = !o.disabled;
    const hovered = live and u.isPointerOver(id);
    const lit = hovered or (o.sub != .none and self.context_sub == o.sub);
    if (hovered and !in_sub and self.context_sub != o.sub) {
        self.context_sub = o.sub;
        self.window.redraw();
    }
    const ink = if (live) p.text_primary else p.text_disabled;
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(if (ten) 22 else kit.theme.metrics.menu_item_height),
        .padding = if (ten) .trbl(0, 8, 0, 0) else .xy(11, 0),
        .gap = if (ten) 0 else 12,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else kit.theme.metrics.control_radius),
        .background_color = if (!lit) .transparent else if (ten) classicHover(kit) else if (live and u.isElementPressed(id)) p.subtle_tertiary else p.subtle_secondary,
    });
    defer u.close();
    // Windows 11's mark, in its own column.
    if (!ten) if (o.marked) |on| {
        u.open(.{ .width = .fixed(12), .height = .grow, .align_x = .center, .align_y = .center });
        if (on and o.ticked) kit.icon(.checkmark, 12, ink, .regular) else if (on) u.empty(.{ .width = .fixed(6), .height = .fixed(6), .corner_radius = .all(3), .background_color = ink });
        u.close();
    };
    const marked_here = (o.marked orelse false) and ten;
    // The gutter: a glyph, an app's icon, the chosen's dot - or room for one.
    u.open(.{ .width = .fixed(if (ten) 30 else 16), .height = .grow, .align_x = .center, .align_y = .center });
    if (marked_here and o.ticked) {
        kit.icon(.checkmark, 12, ink, .regular);
    } else if (marked_here) {
        u.empty(.{ .width = .fixed(6), .height = .fixed(6), .corner_radius = .all(3), .background_color = ink });
    } else if (o.themed) |n| {
        icons.themed(self, kit, n, 16);
    } else if (o.icon) |g| {
        kit.icon(g, 16, if (live) (if (ten) widgets.argb(0xFF1979CA) else ink) else p.text_disabled, .regular);
    } else if (o.image) |texture| {
        u.empty(.{ .width = .fixed(16), .height = .fixed(16), .image = .{ .texture = texture } });
    }
    u.close();
    {
        u.open(.{ .width = .grow, .padding = .trbl(0, 0, 0, if (ten) 4 else 0) });
        defer u.close();
        var style = kit.style(if (ten) .caption else .body, ink);
        style.wrap = .none;
        if (o.strong) style.font = widgets.Fonts.Slot.strong;
        u.text(content, style);
    }
    if (o.shortcut) |keys| {
        u.open(.{ .padding = .trbl(0, 0, 0, 24) });
        kit.label(keys, .caption, if (live) p.text_secondary else p.text_disabled);
        u.close();
    }
    if (o.sub != .none) {
        u.open(.{ .padding = .trbl(0, 0, 0, 16) });
        kit.icon(.chevron_right, if (ten) 8 else 12, ink, .regular);
        u.close();
    }
    return live and o.sub == .none and u.justReleased();
}

pub fn separator(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    if (!self.ten()) return kit.menuSeparator();
    // Windows 10's starts past the gutter.
    u.open(.{ .width = .grow, .padding = .trbl(3, 2, 3, 32) });
    defer u.close();
    u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = classicEdge(kit) });
}

/// A row with its menu beside it, the menu drawn while it is open.
pub fn subRow(self: *Files, kit: *Kit, id: []const u8, content: []const u8, glyph: ?Glyph, which: Sub, disabled: bool) void {
    subRowMarked(self, kit, id, content, glyph, which, disabled, null);
}

pub fn subRowMarked(self: *Files, kit: *Kit, id: []const u8, content: []const u8, glyph: ?Glyph, which: Sub, disabled: bool, marked: ?bool) void {
    _ = row(self, kit, id, content, .{ .icon = glyph, .sub = which, .disabled = disabled, .marked = if (marked != null) false else null });
    if (self.context_sub != which or disabled) return;
    begin(self, kit, sub_id, .{ .attach = .id, .to = id, .anchor = .after, .offset = .{ .x = if (self.ten()) 0 else 4, .y = if (self.ten()) -3 else -4 }, .z_index = 82 });
    defer end(kit);
    in_sub = true;
    defer in_sub = false;
    switch (which) {
        .none => {},
        .view => viewMenu(self, kit),
        .sort => sortMenu(self, kit),
        .group => groupMenu(self, kit),
        .new => newMenu(self, kit),
        .send_to => sendToMenu(self, kit),
        .open_with => openWithMenu(self, kit),
        .show => showMenu(self, kit),
    }
}

// -------------------------------------------------------------------------
// What is chosen
// -------------------------------------------------------------------------

/// Windows 11's: the glyph row, then the rest.
fn itemMenu(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    {
        u.open(.{ .id = "context/row", .width = .grow, .padding = .xy(4, 2), .gap = 2 });
        defer u.close();
        const glyphs = [_]struct { id: []const u8, glyph: Glyph, tip: []const u8 }{
            .{ .id = "context/cut", .glyph = .cut, .tip = "Cut" },
            .{ .id = "context/copy", .glyph = .copy, .tip = "Copy" },
            .{ .id = "context/paste", .glyph = .clipboard_paste, .tip = "Paste" },
            .{ .id = "context/rename", .glyph = .rename, .tip = "Rename" },
            .{ .id = "context/share", .glyph = .share, .tip = "Share" },
            .{ .id = "context/delete", .glyph = .delete, .tip = "Delete" },
        };
        for (glyphs) |r| {
            const enabled = if (std.mem.eql(u8, r.id, "context/paste")) actions.canPaste(self) else if (std.mem.eql(u8, r.id, "context/rename")) t.selectedCount() == 1 and t.location != .search else true;
            const hovered = enabled and u.isPointerOver(r.id);
            if (u.isPointerOver(r.id) and self.context_sub != .none) self.context_sub = .none;
            u.open(.{
                .id = r.id,
                .width = .fixed(40),
                .height = .fixed(36),
                .align_x = .center,
                .align_y = .center,
                .corner_radius = .all(4),
                .background_color = if (hovered) p.subtle_secondary else .transparent,
            });
            kit.icon(r.glyph, 18, if (enabled) p.text_primary else p.text_disabled, .regular);
            const clicked = enabled and u.justReleased();
            u.close();
            kit.tooltip(r.id, r.tip);
            if (clicked) {
                done(self);
                if (std.mem.eql(u8, r.id, "context/cut")) actions.copy(self, true);
                if (std.mem.eql(u8, r.id, "context/copy")) actions.copy(self, false);
                if (std.mem.eql(u8, r.id, "context/paste")) actions.paste(self);
                if (std.mem.eql(u8, r.id, "context/rename")) if (t.current()) |i| self.startRename(i);
                if (std.mem.eql(u8, r.id, "context/share")) actions.email(self);
                if (std.mem.eql(u8, r.id, "context/delete")) actions.delete(self, false);
                return;
            }
        }
    }
    separator(self, kit);
    const one = t.selectedCount() == 1;
    const folder = if (t.current()) |i| t.entry(i).isFolder() else false;
    if (row(self, kit, "context/open", "Open", .{ .icon = .open, .shortcut = "Enter" })) {
        done(self);
        if (t.current()) |i| self.open(i, false);
        return;
    }
    if (!folder and one) subRow(self, kit, "context/open-with", "Open with", .apps, .open_with, false);
    if (t.location == .search and one) if (row(self, kit, "context/location", "Open file location", .{ .icon = .folder_open })) {
        done(self);
        return self.openFileLocation();
    };
    if (folder and one) {
        if (row(self, kit, "context/open-tab", "Open in new tab", .{ .icon = .tab_add })) {
            done(self);
            if (t.current()) |i| self.open(i, true);
            return;
        }
        if (row(self, kit, "context/open-window", "Open in new window", .{ .icon = .window })) {
            done(self);
            return openChosenInNewWindow(self);
        }
        const pinned = if (chosenPath(self)) |path| self.places.isPinned(path) else false;
        if (row(self, kit, "context/pin", if (pinned) "Unpin from Quick access" else "Pin to Quick access", .{ .icon = .pin })) {
            done(self);
            return actions.pinChosen(self);
        }
    }
    if (row(self, kit, "context/zip", "Compress to ZIP file", .{ .icon = .folder, .disabled = t.path() == null })) {
        done(self);
        return actions.zip(self);
    }
    if (row(self, kit, "context/path", "Copy as path", .{ .icon = .clipboard_paste, .shortcut = "Ctrl+Shift+C" })) {
        done(self);
        return actions.copyAsPath(self);
    }
    if (row(self, kit, "context/properties", "Properties", .{ .icon = .info, .shortcut = "Alt+Enter" })) {
        done(self);
        return self.openProperties();
    }
    if (folder and one) {
        separator(self, kit);
        if (row(self, kit, "context/terminal", "Open in Terminal", .{ .icon = .window_console })) {
            done(self);
            return actions.terminalChosen(self);
        }
    }
    separator(self, kit);
    if (row(self, kit, "context/more", "Show more options", .{ .icon = .more_horizontal, .shortcut = "Shift+F10" })) {
        self.context_more = true;
        self.context_sub = .none;
        self.window.redraw();
    }
}

/// The full list: Windows 10's, and Windows 11's "more".
fn itemMenuFull(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const one = t.selectedCount() == 1;
    const folder = if (t.current()) |i| t.entry(i).isFolder() else false;
    if (row(self, kit, "context/open", "Open", .{ .strong = true })) {
        done(self);
        if (t.current()) |i| self.open(i, false);
        return;
    }
    if (folder and one) {
        if (row(self, kit, "context/open-window", "Open in new window", .{})) {
            done(self);
            return openChosenInNewWindow(self);
        }
        if (!self.ten()) if (row(self, kit, "context/open-tab", "Open in new tab", .{})) {
            done(self);
            if (t.current()) |i| self.open(i, true);
            return;
        };
        const pinned = if (chosenPath(self)) |path| self.places.isPinned(path) else false;
        if (row(self, kit, "context/pin", if (pinned) "Unpin from Quick access" else "Pin to Quick access", .{})) {
            done(self);
            return actions.pinChosen(self);
        }
        if (row(self, kit, "context/terminal", "Open in Terminal", .{})) {
            done(self);
            return actions.terminalChosen(self);
        }
    }
    if (!folder and one) subRow(self, kit, "context/open-with", "Open with", null, .open_with, false);
    if (t.location == .search and one) if (row(self, kit, "context/location", "Open file location", .{})) {
        done(self);
        return self.openFileLocation();
    };
    separator(self, kit);
    if (row(self, kit, "context/share", "Share", .{ .icon = .share, .disabled = folder })) {
        done(self);
        return actions.email(self);
    }
    separator(self, kit);
    subRow(self, kit, "context/send-to", "Send to", null, .send_to, false);
    separator(self, kit);
    if (row(self, kit, "context/cut", "Cut", .{})) {
        done(self);
        return actions.copy(self, true);
    }
    if (row(self, kit, "context/copy", "Copy", .{})) {
        done(self);
        return actions.copy(self, false);
    }
    separator(self, kit);
    if (row(self, kit, "context/shortcut", "Create shortcut", .{})) {
        done(self);
        return actions.createShortcut(self);
    }
    if (row(self, kit, "context/delete", "Delete", .{})) {
        done(self);
        return actions.delete(self, false);
    }
    if (row(self, kit, "context/rename", "Rename", .{ .disabled = !one or t.location == .search })) {
        done(self);
        if (t.current()) |i| self.startRename(i);
        return;
    }
    separator(self, kit);
    if (row(self, kit, "context/properties", "Properties", .{})) {
        done(self);
        return self.openProperties();
    }
}

/// What is in the Recycle Bin: put back, or gone for good.
fn trashItemMenu(self: *Files, kit: *Kit) void {
    if (row(self, kit, "context/restore", "Restore", .{ .strong = self.ten(), .icon = if (self.ten()) null else .arrow_reply })) {
        done(self);
        return actions.restore(self, false);
    }
    separator(self, kit);
    if (row(self, kit, "context/delete", "Delete", .{ .icon = if (self.ten()) null else .delete, .shortcut = if (self.ten()) null else "Del" })) {
        done(self);
        return actions.delete(self, true);
    }
    separator(self, kit);
    if (row(self, kit, "context/properties", "Properties", .{ .icon = if (self.ten()) null else .info, .shortcut = if (self.ten()) null else "Alt+Enter" })) {
        done(self);
        return self.openProperties();
    }
}

/// The full path of the one chosen.
fn chosenPath(self: *Files) ?[]const u8 {
    const t = self.tab();
    const i = t.current() orelse return null;
    const e = t.entry(i);
    const dir = t.dirOf(e) orelse return null;
    const S = struct {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
    };
    return Ops.join(&S.buffer, dir, e.name) catch null;
}

fn openChosenInNewWindow(self: *Files) void {
    const path = chosenPath(self) orelse return;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(self.gpa);
    line.appendSlice(self.gpa, "fluxion-files '") catch return;
    for (path) |c| if (c == '\'') line.appendSlice(self.gpa, "'\\''") catch return else line.append(self.gpa, c) catch return;
    line.append(self.gpa, '\'') catch return;
    apps_mod.run(self.gpa, self.io, "Files", line.items, null);
}

// -------------------------------------------------------------------------
// The folder itself
// -------------------------------------------------------------------------

/// Windows 11's: what to see, then New, Properties and the terminal.
fn folderMenu(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const in_folder = t.path() != null;
    subRow(self, kit, "context/view", "View", .grid, .view, false);
    subRow(self, kit, "context/sort", "Sort by", .arrow_sort, .sort, false);
    subRow(self, kit, "context/group", "Group by", .apps_list, .group, false);
    separator(self, kit);
    if (row(self, kit, "context/paste", "Paste", .{ .icon = .clipboard_paste, .shortcut = "Ctrl+V", .disabled = !actions.canPaste(self) })) {
        done(self);
        return actions.paste(self);
    }
    separator(self, kit);
    subRow(self, kit, "context/new", "New", .add, .new, !in_folder);
    separator(self, kit);
    if (row(self, kit, "context/properties", "Properties", .{ .icon = .info, .shortcut = "Alt+Enter", .disabled = !in_folder })) {
        done(self);
        return self.openProperties();
    }
    separator(self, kit);
    if (row(self, kit, "context/terminal", "Open in Terminal", .{ .icon = .window_console, .disabled = !in_folder })) {
        done(self);
        return actions.terminalHere(self);
    }
    separator(self, kit);
    if (row(self, kit, "context/more", "Show more options", .{ .icon = .more_horizontal, .shortcut = "Shift+F10" })) {
        self.context_more = true;
        self.context_sub = .none;
        self.window.redraw();
    }
}

/// Windows 10's, and Windows 11's "more".
fn folderMenuFull(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const in_folder = t.path() != null;
    subRow(self, kit, "context/view", "View", null, .view, false);
    subRow(self, kit, "context/sort", "Sort by", null, .sort, false);
    subRow(self, kit, "context/group", "Group by", null, .group, false);
    if (row(self, kit, "context/refresh", "Refresh", .{})) {
        done(self);
        return self.refresh();
    }
    separator(self, kit);
    if (row(self, kit, "context/paste", "Paste", .{ .disabled = !actions.canPaste(self) })) {
        done(self);
        return actions.paste(self);
    }
    if (row(self, kit, "context/paste-shortcut", "Paste shortcut", .{ .disabled = !actions.canPaste(self) })) {
        done(self);
        return actions.pasteShortcut(self);
    }
    // What Ctrl+Z and Ctrl+Y would do, as Windows' menu says it.
    if (self.undo.next()) |step| if (row(self, kit, "context/undo", kit.print("Undo {s}", .{step.verb()}), .{ .shortcut = "Ctrl+Z" })) {
        done(self);
        return actions.undo(self);
    };
    if (self.undo.nextRedo()) |step| if (row(self, kit, "context/redo", kit.print("Redo {s}", .{step.verb()}), .{ .shortcut = "Ctrl+Y" })) {
        done(self);
        return actions.redo(self);
    };
    separator(self, kit);
    if (row(self, kit, "context/terminal", "Open in Terminal", .{ .disabled = !in_folder })) {
        done(self);
        return actions.terminalHere(self);
    }
    separator(self, kit);
    subRow(self, kit, "context/new", "New", null, .new, !in_folder);
    separator(self, kit);
    if (row(self, kit, "context/properties", "Properties", .{ .disabled = !in_folder })) {
        done(self);
        return self.openProperties();
    }
}

/// The Recycle Bin's own.
fn trashMenu(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const ten = self.ten();
    subRow(self, kit, "context/view", "View", if (ten) null else .grid, .view, false);
    subRow(self, kit, "context/sort", "Sort by", if (ten) null else .arrow_sort, .sort, false);
    subRow(self, kit, "context/group", "Group by", if (ten) null else .apps_list, .group, false);
    if (row(self, kit, "context/refresh", "Refresh", .{ .icon = if (ten) null else .arrow_clockwise })) {
        done(self);
        return self.refresh();
    }
    separator(self, kit);
    if (row(self, kit, "context/empty", "Empty Recycle Bin", .{ .icon = if (ten) null else .delete, .disabled = t.count() == 0 })) {
        done(self);
        self.confirm = .empty_trash;
        return;
    }
    if (row(self, kit, "context/restore-all", "Restore all items", .{ .icon = if (ten) null else .arrow_reply, .disabled = t.count() == 0 })) {
        done(self);
        return actions.restore(self, true);
    }
}

// -------------------------------------------------------------------------
// The menus beside
// -------------------------------------------------------------------------

pub const view_names = [_][]const u8{ "Extra large icons", "Large icons", "Medium icons", "Small icons", "List", "Details", "Tiles", "Content" };
pub const view_glyphs = [_]Glyph{ .image, .image_multiple, .grid, .apps, .list, .text_bullet_list, .apps_list, .task_list_ltr };

fn viewMenu(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const ten = self.ten();
    for (view_names, 0..) |name, i| {
        const view: Tab.View = @enumFromInt(i);
        if (row(self, kit, kit.print("context/view/{t}", .{view}), name, .{ .marked = t.view == view, .icon = if (ten) null else view_glyphs[i], .shortcut = if (ten) null else kit.print("Ctrl+Shift+{d}", .{i + 1}) })) {
            done(self);
            return self.setView(view);
        }
    }
    if (!ten) {
        separator(self, kit);
        if (row(self, kit, "context/view/compact", "Compact view", .{ .marked = self.compact, .ticked = true, .icon = .list })) {
            done(self);
            self.compact = !self.compact;
            return;
        }
    }
}

/// Windows 11's View ▸ Show: the panes, and what is shown of the items.
pub fn showMenu(self: *Files, kit: *Kit) void {
    const Choice = struct { id: []const u8, name: []const u8, on: bool, keys: ?[]const u8 = null, glyph: Glyph };
    const choices = [_]Choice{
        .{ .id = "show/nav", .name = "Navigation pane", .on = self.show_nav, .glyph = .navigation },
        .{ .id = "show/details", .name = "Details pane", .on = self.pane == .details, .keys = "Alt+Shift+P", .glyph = .info },
        .{ .id = "show/preview", .name = "Preview pane", .on = self.pane == .preview, .keys = "Alt+P", .glyph = .eye },
        .{ .id = "show/checkboxes", .name = "Item check boxes", .on = self.check_boxes, .glyph = .checkmark_circle },
        .{ .id = "show/extensions", .name = "File name extensions", .on = self.show_extensions, .glyph = .document },
        .{ .id = "show/hidden", .name = "Hidden items", .on = self.show_hidden, .glyph = .eye_off },
    };
    for (choices, 0..) |c, k| {
        if (k == 3) separator(self, kit);
        if (row(self, kit, c.id, c.name, .{ .marked = c.on, .ticked = true, .icon = c.glyph, .shortcut = c.keys })) {
            done(self);
            self.menu = .none;
            switch (k) {
                0 => self.show_nav = !self.show_nav,
                1 => self.togglePane(.details),
                2 => self.togglePane(.preview),
                3 => self.check_boxes = !self.check_boxes,
                4 => self.show_extensions = !self.show_extensions,
                else => self.toggleHidden(),
            }
            self.savePrefs();
            return;
        }
    }
}

const columns = [_]struct { by: Folder.Column, name: []const u8 }{
    .{ .by = .name, .name = "Name" },
    .{ .by = .modified, .name = "Date modified" },
    .{ .by = .type, .name = "Type" },
    .{ .by = .size, .name = "Size" },
};

fn sortMenu(self: *Files, kit: *Kit) void {
    const t = self.tab();
    for (columns) |c| if (row(self, kit, kit.print("context/sort/{t}", .{c.by}), c.name, .{ .marked = t.sort_by == c.by })) {
        done(self);
        // Chosen again it keeps its order.
        if (t.sort_by != c.by) self.sortBy(c.by);
        return;
    };
    separator(self, kit);
    if (row(self, kit, "context/sort/ascending", "Ascending", .{ .marked = t.ascending })) {
        done(self);
        return self.sortOrder(true);
    }
    if (row(self, kit, "context/sort/descending", "Descending", .{ .marked = !t.ascending })) {
        done(self);
        return self.sortOrder(false);
    }
}

fn groupMenu(self: *Files, kit: *Kit) void {
    const t = self.tab();
    for (columns) |c| if (row(self, kit, kit.print("context/group/{t}", .{c.by}), c.name, .{ .marked = t.group_by == c.by })) {
        done(self);
        return self.groupBy(c.by);
    };
    separator(self, kit);
    if (row(self, kit, "context/group/none", "(None)", .{ .marked = t.group_by == null })) {
        done(self);
        return self.groupBy(null);
    }
}

fn newMenu(self: *Files, kit: *Kit) void {
    const ten = self.ten();
    if (row(self, kit, "context/new/folder", "Folder", .{ .icon = .folder })) {
        done(self);
        return actions.newFolder(self);
    }
    separator(self, kit);
    if (row(self, kit, "context/new/text", "Text Document", .{ .icon = .document })) {
        done(self);
        return actions.newTextFile(self);
    }
    _ = ten;
}

fn sendToMenu(self: *Files, kit: *Kit) void {
    const t = self.tab();
    if (row(self, kit, "context/send/zip", "Compressed (zipped) folder", .{ .icon = .folder, .disabled = t.path() == null })) {
        done(self);
        return actions.zip(self);
    }
    if (row(self, kit, "context/send/desktop", "Desktop (create shortcut)", .{ .icon = .desktop, .disabled = self.places.pathOf(.desktop) == null })) {
        done(self);
        return actions.shortcutOnDesktop(self);
    }
    if (self.places.pathOf(.documents)) |documents| if (row(self, kit, "context/send/documents", "Documents", .{ .icon = .document })) {
        done(self);
        return actions.sendTo(self, documents, false);
    };
    if (row(self, kit, "context/send/mail", "Mail recipient", .{ .icon = .mail })) {
        done(self);
        return actions.email(self);
    }
    // The drives that come and go: a USB stick, as Windows lists them.
    for (self.places.drives.items, 0..) |d, i| {
        if (!d.removable) continue;
        if (row(self, kit, kit.print("context/send/drive/{d}", .{i}), kit.print("{s} ({s})", .{ d.label, d.mount }), .{ .icon = .usb_stick })) {
            done(self);
            return actions.sendTo(self, d.mount, false);
        }
    }
}

fn openWithMenu(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const i = t.current() orelse return;
    const e = t.entry(i);
    const installed = self.installedApps() orelse return;
    var found: [10]*const apps_mod.App = undefined;
    const list = self.open_with.appsFor(installed, e.mime, &found);
    if (list.len == 0) {
        _ = row(self, kit, "context/with/none", "No apps open this kind of file", .{ .disabled = true });
        return;
    }
    for (list, 0..) |app, k| {
        const image = if (app.icon.len > 0) self.window.icons.lookup(app.icon, 16) else null;
        if (row(self, kit, kit.print("context/with/{d}", .{k}), app.name, .{ .image = image, .icon = if (image == null) .apps else null })) {
            done(self);
            return actions.openWith(self, app);
        }
    }
}

// -------------------------------------------------------------------------
// Questions
// -------------------------------------------------------------------------

/// Yes to the question asked.
pub fn confirmed(self: *Files) void {
    const which = self.confirm orelse return;
    self.confirm = null;
    switch (which) {
        .delete_permanently => actions.deleteChosen(self, true),
        .empty_trash => actions.emptyTrash(self),
    }
    self.window.redraw();
}

/// The question, over the window dimmed: Windows' Delete File dialog.
pub fn confirmDialog(self: *Files, kit: *Kit) void {
    const which = self.confirm orelse return;
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    u.open(.{
        .id = "dialog/smoke",
        .width = .grow,
        .height = .grow,
        .align_x = .center,
        .align_y = .center,
        .background_color = p.smoke,
        .floating = .{ .attach = .root, .z_index = 90 },
    });
    defer u.close();
    u.open(.{
        .id = "dialog",
        .width = .fixed(420),
        .direction = .top_to_bottom,
        .corner_radius = .all(if (self.ten()) 0 else 8),
        .background_color = p.solid_base,
        .border = .{ .color = p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .clip = .both,
    });
    defer u.close();
    switch (which) {
        .empty_trash => {
            {
                u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .all(24), .gap = 12 });
                defer u.close();
                kit.label("Delete Multiple Items", .subtitle, p.text_primary);
                var style = kit.style(.body, p.text_primary);
                style.wrap = .words;
                u.text(kit.print("Are you sure you want to permanently delete these {d} items?", .{t.count()}), style);
            }
            u.open(.{ .width = .grow, .padding = .all(24), .gap = 8, .align_x = .right, .background_color = p.solid_secondary, .border = .{ .color = p.divider, .width = .{ .top = 1 } } });
            defer u.close();
            if (kit.button("dialog/yes", "Yes", .{ .kind = .accent, .width = .fixed(120) })) confirmed(self);
            if (kit.button("dialog/no", "No", .{ .width = .fixed(120) })) self.confirm = null;
        },
        .delete_permanently => {
            const n = t.selectedCount();
            {
                u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .all(24), .gap = 12 });
                defer u.close();
                kit.label(if (n == 1) "Delete File" else "Delete Multiple Items", .subtitle, p.text_primary);
                var style = kit.style(.body, p.text_primary);
                style.wrap = .words;
                if (n == 1) {
                    const name = if (t.current()) |i| t.entry(i).name else "";
                    u.text(kit.print("Are you sure you want to permanently delete \u{201C}{s}\u{201D}?", .{name}), style);
                } else u.text(kit.print("Are you sure you want to permanently delete these {d} items?", .{n}), style);
            }
            u.open(.{ .width = .grow, .padding = .all(24), .gap = 8, .align_x = .right, .background_color = p.solid_secondary, .border = .{ .color = p.divider, .width = .{ .top = 1 } } });
            defer u.close();
            if (kit.button("dialog/yes", "Yes", .{ .kind = .accent, .width = .fixed(120) })) confirmed(self);
            if (kit.button("dialog/no", "No", .{ .width = .fixed(120) })) self.confirm = null;
        },
    }
}
