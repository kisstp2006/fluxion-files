// SPDX-License-Identifier: BSD-2-Clause

//! The right-click menus and the questions asked over the window.
//!
//! **Windows 11's menu** for what is chosen has the commonest commands as a
//! row of glyphs along its top - Cut, Copy, Paste, Rename, Share, Delete -
//! then Open, Open in new tab, Pin to Quick access, Copy as path,
//! Properties, and "Show more options" for the full one. **Windows 10's**,
//! and Windows 11's "more", is that full one: a plain list. A right click on
//! the folder itself offers View, Sort by, Refresh, Paste and New.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const actions = @import("actions.zig");

const menu_id = "context";

/// The menu a right click asked for: open it where the pointer was, for
/// what it was on.
pub fn openAt(self: *Files, at: [2]f32, on_item: bool) void {
    self.context_open = at;
    self.context_on_item = on_item;
    self.menu = .none;
}

pub fn context(self: *Files, kit: *Kit) void {
    const at = self.context_open orelse return;
    const u = kit.ui;
    // A press anywhere else closes it - the press is answered as well.
    if (self.window.down and !u.isPointerOver(menu_id) and !u.isPointerOver("context/row")) {
        self.context_open = null;
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
    kit.menuBegin(menu_id, .{ .attach = .root, .offset = .{ .x = x, .y = y }, .z_index = 80 });
    defer kit.menuEnd();
    const full = self.ten() or self.context_more;
    if (self.context_on_item) {
        if (full) itemMenuFull(self, kit) else itemMenu(self, kit);
    } else folderMenu(self, kit);
}

fn done(self: *Files) void {
    self.context_open = null;
    self.context_more = false;
    self.window.redraw();
}

/// Windows 11's: the glyph row, then the rest.
fn itemMenu(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    {
        u.open(.{ .id = "context/row", .width = .grow, .padding = .xy(4, 2), .gap = 2 });
        defer u.close();
        const row = [_]struct { id: []const u8, glyph: widgets.icons.Name, tip: []const u8 }{
            .{ .id = "context/cut", .glyph = .cut, .tip = "Cut" },
            .{ .id = "context/copy", .glyph = .copy, .tip = "Copy" },
            .{ .id = "context/paste", .glyph = .clipboard_paste, .tip = "Paste" },
            .{ .id = "context/rename", .glyph = .rename, .tip = "Rename" },
            .{ .id = "context/share", .glyph = .share, .tip = "Share" },
            .{ .id = "context/delete", .glyph = .delete, .tip = "Delete" },
        };
        for (row) |r| {
            const enabled = if (std.mem.eql(u8, r.id, "context/paste")) actions.canPaste(self) else if (std.mem.eql(u8, r.id, "context/rename")) t.selectedCount() == 1 else !std.mem.eql(u8, r.id, "context/share");
            const hovered = enabled and u.isPointerOver(r.id);
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
                if (std.mem.eql(u8, r.id, "context/delete")) actions.delete(self, false);
                return;
            }
        }
    }
    kit.menuSeparator();
    const one = t.selectedCount() == 1;
    const folder = if (t.current()) |i| t.entry(i).isFolder() else false;
    if (kit.menuItem("context/open", "Open", .{ .icon = .open, .shortcut = "Enter" })) {
        done(self);
        if (t.current()) |i| self.open(i, false);
        return;
    }
    if (folder and one) {
        if (kit.menuItem("context/open-tab", "Open in new tab", .{ .icon = .tab_add })) {
            done(self);
            if (t.current()) |i| self.open(i, true);
            return;
        }
    }
    if (kit.menuItem("context/path", "Copy as path", .{ .icon = .clipboard_paste, .shortcut = "Ctrl+Shift+C" })) {
        done(self);
        actions.copyAsPath(self);
        return;
    }
    kit.menuSeparator();
    if (kit.menuItem("context/more", "Show more options", .{ .icon = .more_horizontal, .shortcut = "Shift+F10" })) {
        self.context_more = true;
        self.window.redraw();
    }
}

/// The full list: Windows 10's, and Windows 11's "more".
fn itemMenuFull(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const one = t.selectedCount() == 1;
    const folder = if (t.current()) |i| t.entry(i).isFolder() else false;
    if (kit.menuItem("context/open", "Open", .{})) {
        done(self);
        if (t.current()) |i| self.open(i, false);
        return;
    }
    if (folder and one and !self.ten()) if (kit.menuItem("context/open-tab", "Open in new tab", .{})) {
        done(self);
        if (t.current()) |i| self.open(i, true);
        return;
    };
    kit.menuSeparator();
    if (kit.menuItem("context/cut", "Cut", .{ .shortcut = "Ctrl+X" })) {
        done(self);
        return actions.copy(self, true);
    }
    if (kit.menuItem("context/copy", "Copy", .{ .shortcut = "Ctrl+C" })) {
        done(self);
        return actions.copy(self, false);
    }
    if (kit.menuItem("context/paste", "Paste", .{ .shortcut = "Ctrl+V", .disabled = !actions.canPaste(self) })) {
        done(self);
        return actions.paste(self);
    }
    kit.menuSeparator();
    if (kit.menuItem("context/delete", "Delete", .{ .shortcut = "Del" })) {
        done(self);
        return actions.delete(self, false);
    }
    if (kit.menuItem("context/rename", "Rename", .{ .shortcut = "F2", .disabled = !one })) {
        done(self);
        if (t.current()) |i| self.startRename(i);
        return;
    }
    kit.menuSeparator();
    if (kit.menuItem("context/path", "Copy as path", .{})) {
        done(self);
        return actions.copyAsPath(self);
    }
}

/// The folder's own: View, Sort by, Refresh, Paste, New.
fn folderMenu(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const in_folder = t.path() != null;
    if (kit.menuItem("context/view", "View", .{ .icon = .grid })) {
        done(self);
        self.menu = .view;
        return;
    }
    if (kit.menuItem("context/sort", "Sort by", .{ .icon = .arrow_sort, .disabled = !in_folder })) {
        done(self);
        self.menu = .sort;
        return;
    }
    if (kit.menuItem("context/refresh", "Refresh", .{ .icon = .arrow_clockwise, .shortcut = "F5", .disabled = !in_folder })) {
        done(self);
        return self.refresh();
    }
    kit.menuSeparator();
    if (kit.menuItem("context/paste", "Paste", .{ .icon = .clipboard_paste, .shortcut = "Ctrl+V", .disabled = !actions.canPaste(self) })) {
        done(self);
        return actions.paste(self);
    }
    kit.menuSeparator();
    if (kit.menuItem("context/new-folder", "New folder", .{ .icon = .folder, .shortcut = "Ctrl+Shift+N", .disabled = !in_folder })) {
        done(self);
        return actions.newFolder(self);
    }
    if (kit.menuItem("context/new-text", "New Text Document", .{ .icon = .document, .disabled = !in_folder })) {
        done(self);
        return actions.newTextFile(self);
    }
    kit.menuSeparator();
    if (kit.menuItem("context/path", "Copy as path", .{ .icon = .clipboard_paste, .disabled = !in_folder })) {
        done(self);
        return actions.copyAsPath(self);
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
