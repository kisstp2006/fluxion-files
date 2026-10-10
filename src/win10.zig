// SPDX-License-Identifier: BSD-2-Clause

//! Windows 10's window: its own title bar with the Quick Access Toolbar,
//! and the ribbon - File, Home, Share and View - over the address row.
//!
//! ```
//! ┌▢ ✓ ▢ ▾ │ Documents ──────────────────────────────────[─][□][✕]┐
//! │ File │ Home │ Share │ View │                                   ˄ ? │
//! │ ┌────────┐┌─────────────┐┌────────┐┌──────────┐┌───────────────┐   │
//! │ │📌 ⧉ 📋 ││Move Copy 🗑 ✎││▢ New   ││Properties││☑ Select all   │   │
//! │ │Clipboard││ Organize    ││ New    ││ Open     ││ Select        │   │
//! │ └────────┘└─────────────┘└────────┘└──────────┘└───────────────┘   │
//! ```
//!
//! Its colours are Windows 10's own: the ribbon white, its buttons lit
//! light blue under the pointer with a blue edge, File in blue - and in dark
//! mode the ribbon a near-black, its buttons lit grey.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Window = @import("Window.zig");
const actions = @import("actions.zig");
const icons = @import("icons.zig");
const property_sheet = @import("properties.zig");

pub const title_h = 31;
const caption_w = 46;

// -- Windows 10's colours --

pub fn windowColor(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF191919) else widgets.argb(0xFFFFFFFF);
}

pub fn titleColor(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF000000) else widgets.argb(0xFFFFFFFF);
}

fn ribbonColor(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF1F1F1F) else widgets.argb(0xFFFFFFFF);
}

pub fn edgeColor(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF3C3C3C) else widgets.argb(0xFFDADBDC);
}

pub fn hoverColor(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF3E3E3E) else widgets.argb(0xFFE5F3FF);
}

pub fn pressColor(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF4D4D4D) else widgets.argb(0xFFCCE8FF);
}

pub fn hoverEdge(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF5A5A5A) else widgets.argb(0xFFCCE8FF);
}

/// The blue Windows 10 draws its glyphs and File with.
fn blue(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF4CA0E0) else widgets.argb(0xFF1979CA);
}

fn ink(kit: *Kit, enabled: bool) Color {
    return if (enabled) kit.theme.palette.text_primary else kit.theme.palette.text_disabled;
}

// -------------------------------------------------------------------------
// The title bar, with the Quick Access Toolbar
// -------------------------------------------------------------------------

pub fn titleBar(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const window = &self.window;
    const t = self.tab();
    u.open(.{ .id = "titlebar", .width = .grow, .height = .fixed(title_h), .align_y = .center, .background_color = titleColor(kit), .padding = .trbl(0, 0, 0, 6) });
    defer u.close();
    const text = if (window.activated) kit.theme.palette.text_primary else kit.theme.palette.text_secondary;
    // The window's own icon, then the toolbar: Properties, New folder, and
    // its menu.
    icons.themed(self, kit, "folder", 16);
    u.empty(.{ .width = .fixed(6) });
    if (qatButton(kit, "qat/properties", .info, "Properties", t.current() != null or t.path() != null)) self.openProperties();
    if (qatButton(kit, "qat/new-folder", .folder, "New folder", t.path() != null)) actions.newFolder(self);
    _ = qatButton(kit, "qat/customize", .chevron_down, "Customize Quick Access Toolbar", true);
    u.empty(.{ .width = .fixed(1), .height = .fixed(16), .background_color = kit.theme.palette.divider });
    u.empty(.{ .width = .fixed(8) });
    {
        // The title starts past a contextual tab's header, as Windows 10
        // moves it along - by where the last drawing put both.
        var past: f32 = 0;
        if (window.boxOf("ribbon/tab/contextual")) |tab_box| if (window.boxOf("titlebar/drag")) |drag| {
            past = @max(0, tab_box.x + tab_box.width + 8 - drag.x);
        };
        u.open(.{ .id = "titlebar/drag", .width = .grow, .height = .grow, .padding = .trbl(0, 0, 0, @intFromFloat(@min(past, 600))), .align_y = .center, .clip = .both });
        defer u.close();
        var style = kit.style(.caption, text);
        style.wrap = .none;
        var buffer: [256]u8 = undefined;
        u.text(kit.print("{s}", .{self.titleOf(t, &buffer)}), style);
        if (u.justPressed()) {
            if (window.clickCount() >= 2) window.toggleMaximized() else window.startMove();
        }
    }
    u.open(.{ .width = .fixed(3 * caption_w + 16), .height = .grow });
    defer u.close();
    const caption = kit.titleBar("title", .{
        .title = "",
        .height = title_h,
        .window = .{ .active = window.activated, .maximized = window.maximized, .snapped = window.tiled },
    });
    switch (caption) {
        .minimize => window.minimize(),
        .maximize => window.toggleMaximized(),
        .close => window.close(),
        else => {},
    }
}

fn qatButton(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, tip: []const u8, enabled: bool) bool {
    const u = kit.ui;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(22),
        .height = .fixed(22),
        .align_x = .center,
        .align_y = .center,
        .background_color = if (enabled and u.isElementPressed(id)) pressColor(kit) else if (hovered) hoverColor(kit) else .transparent,
        .border = if (hovered) .{ .color = hoverEdge(kit), .width = .all(1) } else .{},
    });
    kit.icon(glyph, if (glyph == .chevron_down) 10 else 14, if (enabled) (if (glyph == .folder) widgets.argb(0xFFE8B428) else blue(kit)) else kit.theme.palette.text_disabled, if (glyph == .folder) .filled else .regular);
    const clicked = enabled and u.justReleased();
    u.close();
    kit.tooltip(id, tip);
    return clicked;
}

// -------------------------------------------------------------------------
// The ribbon
// -------------------------------------------------------------------------

pub fn ribbon(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const tool = contextual(self);
    {
        u.open(.{ .id = "ribbon/tabs", .width = .grow, .height = .fixed(24), .align_y = .bottom, .background_color = titleColor(kit) });
        defer u.close();
        // File: Windows 10's blue, its menu under it.
        const file_id = "ribbon/file";
        u.open(.{ .id = file_id, .height = .grow, .padding = .xy(16, 0), .align_y = .center, .background_color = if (u.isPointerOver(file_id) or self.menu == .file) widgets.argb(0xFF2A8AD4) else widgets.argb(0xFF1979CA) });
        kit.label("File", .caption, widgets.argb(0xFFFFFFFF));
        if (u.justReleased()) self.menu = if (self.menu == .file) .none else .file;
        u.close();
        // A tab for what is shown, gone where it is not.
        if (self.ribbon_tab == .manage or self.ribbon_tab == .search) {
            if (tool == null or (tool.?.tab == .search) != (self.ribbon_tab == .search)) self.ribbon_tab = .home;
        }
        for ([_]Files.RibbonTab{ .home, .share, .view }) |which| {
            const id = kit.print("ribbon/tab/{t}", .{which});
            const front = self.ribbon_tab == which and !self.ribbon_folded;
            u.open(.{
                .id = id,
                .height = .grow,
                .padding = .xy(12, 0),
                .align_y = .center,
                .background_color = if (front) ribbonColor(kit) else if (u.isPointerOver(id)) hoverColor(kit) else .transparent,
                .border = if (front) .{ .color = edgeColor(kit), .width = .{ .left = 1, .right = 1, .top = 1 } } else .{},
            });
            const names = [_][]const u8{ "Home", "Share", "View" };
            kit.label(names[@intFromEnum(which)], .caption, p.text_primary);
            if (u.justReleased()) {
                // Folded, a tab opens it a moment; open, it changes tab.
                self.ribbon_tab = which;
                self.ribbon_folded = false;
            }
            u.close();
        }
        if (tool) |c| contextualTab(self, kit, c);
        u.empty(.{ .width = .grow });
        // Fold it to its tab names, or open it again; and help.
        const fold_id = "ribbon/fold";
        u.open(.{ .id = fold_id, .width = .fixed(24), .height = .grow, .align_x = .center, .align_y = .center, .background_color = if (u.isPointerOver(fold_id)) hoverColor(kit) else .transparent });
        kit.icon(if (self.ribbon_folded) .chevron_down else .chevron_up, 10, p.text_secondary, .regular);
        if (u.justReleased()) self.ribbon_folded = !self.ribbon_folded;
        u.close();
        kit.tooltip(fold_id, if (self.ribbon_folded) "Expand the Ribbon (Ctrl+F1)" else "Minimize the Ribbon (Ctrl+F1)");
        u.open(.{ .width = .fixed(24), .height = .grow, .align_x = .center, .align_y = .center });
        u.open(.{ .width = .fixed(16), .height = .fixed(16), .corner_radius = .all(8), .background_color = blue(kit), .align_x = .center, .align_y = .center });
        kit.label("?", .caption, widgets.argb(0xFFFFFFFF));
        u.close();
        u.close();
    }
    if (self.ribbon_folded) {
        u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = edgeColor(kit) });
        return;
    }
    u.open(.{
        .id = "ribbon",
        .width = .grow,
        .height = .fixed(94),
        .padding = .trbl(2, 2, 0, 2),
        .background_color = ribbonColor(kit),
        .border = .{ .color = edgeColor(kit), .width = .{ .top = 1, .bottom = 1 } },
    });
    defer u.close();
    switch (self.ribbon_tab) {
        .home => homeTab(self, kit),
        .share => shareTab(self, kit),
        .view => viewTab(self, kit),
        .manage => if (tool) |c| switch (c.what) {
            .recycle_bin => recycleBinTab(self, kit),
            .picture => pictureTab(self, kit),
            .drive => driveTab(self, kit),
            .search => {},
        },
        .search => searchTab(self, kit),
    }
}

// -- The tabs for what is shown: Windows 10's contextual tabs --

const Contextual = struct {
    what: enum { recycle_bin, picture, drive, search },
    /// Over the tab, in its colour: "Recycle Bin Tools".
    header: []const u8,
    tab: Files.RibbonTab,
    name: []const u8,
    colour: Color,
};

/// The tab what is shown has: the Recycle Bin's Manage, a picture's, a
/// drive's, a search's.
fn contextual(self: *Files) ?Contextual {
    const t = self.tab();
    const dark = kit_dark(self);
    switch (t.location) {
        .trash => return .{ .what = .recycle_bin, .header = "Recycle Bin Tools", .tab = .manage, .name = "Manage", .colour = if (dark) widgets.argb(0xFF5C4A1E) else widgets.argb(0xFFFCEFC4) },
        .search => return .{ .what = .search, .header = "Search Tools", .tab = .search, .name = "Search", .colour = if (dark) widgets.argb(0xFF1E3F5C) else widgets.argb(0xFFD5E8F8) },
        .this_pc => if (self.page_chosen != null and std.mem.startsWith(u8, self.page_chosen_buffer[0..self.page_chosen_len], "pc/drive/")) {
            return .{ .what = .drive, .header = "Drive Tools", .tab = .manage, .name = "Manage", .colour = if (dark) widgets.argb(0xFF3F2A5C) else widgets.argb(0xFFE6DCF5) };
        },
        else => {},
    }
    if (t.selectedCount() >= 1) if (t.current()) |i| if (std.mem.startsWith(u8, t.entry(i).mime, "image/")) {
        return .{ .what = .picture, .header = "Picture Tools", .tab = .manage, .name = "Manage", .colour = if (dark) widgets.argb(0xFF5C4A1E) else widgets.argb(0xFFFCEFC4) };
    };
    return null;
}

fn kit_dark(self: *Files) bool {
    return self.window.theme.palette.mode == .dark;
}

/// The tab, its header over it in the title bar's room, both in the tab's
/// colour.
fn contextualTab(self: *Files, kit: *Kit, c: Contextual) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const id = "ribbon/tab/contextual";
    const front = self.ribbon_tab == c.tab and !self.ribbon_folded;
    u.open(.{
        .id = id,
        .width = .fixed(116),
        .height = .grow,
        .align_x = .center,
        .align_y = .center,
        .background_color = if (front) ribbonColor(kit) else c.colour.withAlpha(0.6),
        .border = if (front) .{ .color = edgeColor(kit), .width = .{ .left = 1, .right = 1, .top = 1 } } else .{},
    });
    kit.label(c.name, .caption, p.text_primary);
    if (u.justReleased()) {
        self.ribbon_tab = c.tab;
        self.ribbon_folded = false;
    }
    {
        u.open(.{
            .width = .fixed(116),
            .height = .fixed(title_h),
            .align_x = .center,
            .align_y = .center,
            .background_color = c.colour,
            .floating = .{ .attach = .parent, .anchor = .above, .z_index = 3 },
            .passthrough = true,
        });
        defer u.close();
        kit.label(c.header, .caption, p.text_primary);
    }
    u.close();
}

fn recycleBinTab(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const chosen = t.selectedCount() > 0;
    {
        groupBegin(kit);
        defer groupEnd(kit, "Manage");
        if (large(kit, "ribbon/empty", .delete, null, "Empty\nRecycle Bin", false, t.count() > 0)) self.confirm = .empty_trash;
        if (large(kit, "ribbon/bin-properties", .info, null, "Recycle Bin\nproperties", false, true)) self.openProperties();
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Restore");
        if (large(kit, "ribbon/restore-all", .arrow_reply, null, "Restore\nall items", false, t.count() > 0)) actions.restore(self, true);
        if (large(kit, "ribbon/restore", .arrow_reply, null, "Restore the\nselected items", false, chosen)) actions.restore(self, false);
    }
}

fn pictureTab(self: *Files, kit: *Kit) void {
    {
        groupBegin(kit);
        defer groupEnd(kit, "View");
        if (large(kit, "ribbon/background", .image, null, "Set as\nbackground", false, self.tab().selectedCount() == 1)) actions.setAsBackground(self);
        if (large(kit, "ribbon/open-picture", .open, null, "Open", false, true)) if (self.tab().current()) |i| self.open(i, false);
    }
}

fn driveTab(self: *Files, kit: *Kit) void {
    const d = self.chosenDrive() orelse return;
    {
        groupBegin(kit);
        defer groupEnd(kit, "Manage");
        if (large(kit, "ribbon/drive-open", .open, null, "Open", false, true)) self.goTo(.{ .folder = d.mount });
        if (large(kit, "ribbon/drive-terminal", .window_console, null, "Open in\nTerminal", false, true)) actions.terminalIn(self, d.mount);
        if (large(kit, "ribbon/drive-properties", .info, null, "Properties", false, true)) property_sheet.open(self, d.mount, true, "inode/directory");
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Media");
        if (large(kit, "ribbon/eject", .arrow_up, null, "Eject", false, d.removable)) actions.eject(self, d);
    }
}

fn searchTab(self: *Files, kit: *Kit) void {
    const t = self.tab();
    if (t.location != .search) return;
    {
        groupBegin(kit);
        defer groupEnd(kit, "Location");
        const q = t.location.search;
        const in_home = std.mem.eql(u8, q.folder, self.places.home);
        if (large(kit, "ribbon/search-here", .folder_open, widgets.argb(0xFFE8B428), "Current\nfolder", false, true)) {}
        smallColumnBegin(kit);
        defer smallColumnEnd(kit);
        if (small(kit, "ribbon/search-home", .home, null, "Search again in your home folder", false, !in_home)) {
            var buffer: [256]u8 = undefined;
            const query = std.fmt.bufPrint(&buffer, "{s}", .{q.query}) catch return;
            self.searchIn(self.places.home, query);
        }
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Options");
        if (large(kit, "ribbon/file-location", .folder_open, null, "Open file\nlocation", false, t.selectedCount() == 1)) self.openFileLocation();
        if (large(kit, "ribbon/close-search", .dismiss, widgets.argb(0xFFE81123), "Close\nsearch", false, true)) self.closeSearch();
    }
}

fn groupBegin(kit: *Kit) void {
    const u = kit.ui;
    u.open(.{ .height = .grow, .direction = .top_to_bottom, .padding = .xy(3, 0), .border = .{ .color = edgeColor(kit), .width = .{ .right = 1 } } });
    u.open(.{ .height = .grow, .gap = 1, .padding = .trbl(1, 0, 0, 0) });
}

fn groupEnd(kit: *Kit, name: []const u8) void {
    const u = kit.ui;
    u.close();
    u.open(.{ .width = .grow, .height = .fixed(18), .align_x = .center, .align_y = .center });
    kit.label(name, .caption, kit.theme.palette.text_secondary);
    u.close();
    u.close();
}

/// A column of small buttons, three high.
fn smallColumnBegin(kit: *Kit) void {
    kit.ui.open(.{ .direction = .top_to_bottom, .gap = 0, .padding = .xy(1, 0) });
}

fn smallColumnEnd(kit: *Kit) void {
    kit.ui.close();
}

/// A large ribbon button: a 32-pixel glyph over its name, on two lines
/// where it is long, "▾" under it where it opens a menu.
fn large(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, colour: ?Color, name: []const u8, drop: bool, enabled: bool) bool {
    const u = kit.ui;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .height = .grow,
        .width = .fit,
        .direction = .top_to_bottom,
        .padding = .xy(5, 3),
        .gap = 3,
        .align_x = .center,
        .background_color = if (enabled and u.isElementPressed(id)) pressColor(kit) else if (hovered) hoverColor(kit) else .transparent,
        .border = if (hovered) .{ .color = hoverEdge(kit), .width = .all(1) } else .{},
    });
    kit.icon(glyph, 32, if (enabled) colour orelse blue(kit) else kit.theme.palette.text_disabled, .regular);
    var style = kit.style(.caption, ink(kit, enabled));
    style.alignment = .center;
    style.wrap = .none;
    // A line each; the "▾" of one that opens a menu after the last, or
    // under a name of one line, as Windows 10 sets them.
    u.open(.{ .direction = .top_to_bottom, .align_x = .center });
    var lines = std.mem.splitScalar(u8, name, '\n');
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    lines.reset();
    var k: usize = 0;
    while (lines.next()) |line| : (k += 1) {
        const last = k + 1 == count;
        if (!(drop and last and count > 1)) {
            u.text(line, style);
            continue;
        }
        u.open(.{ .gap = 3, .align_y = .center });
        u.text(line, style);
        kit.icon(.chevron_down, 8, ink(kit, enabled), .regular);
        u.close();
    }
    if (drop and count == 1) kit.icon(.chevron_down, 8, ink(kit, enabled), .regular);
    u.close();
    const clicked = enabled and u.justReleased();
    u.close();
    return clicked;
}

/// A small ribbon button: a 16-pixel glyph and its name on one line.
fn small(kit: *Kit, id: []const u8, glyph: ?widgets.icons.Name, colour: ?Color, name: []const u8, drop: bool, enabled: bool) bool {
    const u = kit.ui;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .height = .fixed(22),
        .padding = .xy(3, 0),
        .gap = 5,
        .align_y = .center,
        .background_color = if (enabled and u.isElementPressed(id)) pressColor(kit) else if (hovered) hoverColor(kit) else .transparent,
        .border = if (hovered) .{ .color = hoverEdge(kit), .width = .all(1) } else .{},
    });
    if (glyph) |g| kit.icon(g, 16, if (enabled) colour orelse blue(kit) else kit.theme.palette.text_disabled, .regular);
    var style = kit.style(.caption, ink(kit, enabled));
    style.wrap = .none;
    u.text(name, style);
    if (drop) kit.icon(.chevron_down, 8, ink(kit, enabled), .regular);
    const clicked = enabled and u.justReleased();
    u.close();
    return clicked;
}

/// A check box in the ribbon: Show/hide's.
fn check(kit: *Kit, id: []const u8, name: []const u8, on: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = u.isPointerOver(id);
    u.open(.{ .id = id, .height = .fixed(22), .padding = .xy(3, 0), .gap = 6, .align_y = .center, .background_color = if (hovered) hoverColor(kit) else .transparent });
    u.open(.{ .width = .fixed(13), .height = .fixed(13), .align_x = .center, .align_y = .center, .background_color = windowColor(kit), .border = .{ .color = if (hovered) blue(kit) else p.text_secondary, .width = .all(1) } });
    if (on) kit.icon(.checkmark, 10, p.text_primary, .regular);
    u.close();
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.text(name, style);
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

fn homeTab(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const chosen = t.selectedCount() > 0;
    const one = t.selectedCount() == 1;
    const in_folder = t.path() != null;
    {
        groupBegin(kit);
        defer groupEnd(kit, "Clipboard");
        if (large(kit, "ribbon/pin", .pin, null, "Pin to Quick\naccess", false, in_folder)) actions.pinChosen(self);
        if (large(kit, "ribbon/copy", .copy, null, "Copy", false, chosen)) actions.copy(self, false);
        if (large(kit, "ribbon/paste", .clipboard_paste, null, "Paste", false, actions.canPaste(self))) actions.paste(self);
        smallColumnBegin(kit);
        defer smallColumnEnd(kit);
        if (small(kit, "ribbon/cut", .cut, null, "Cut", false, chosen)) actions.copy(self, true);
        if (small(kit, "ribbon/copy-path", .copy, null, "Copy path", false, in_folder)) actions.copyAsPath(self);
        if (small(kit, "ribbon/paste-shortcut", .clipboard_paste, null, "Paste shortcut", false, actions.canPaste(self))) actions.pasteShortcut(self);
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Organize");
        if (large(kit, "ribbon/move-to", .folder_open, widgets.argb(0xFFE8B428), "Move\nto", true, chosen)) self.menu = .move_to;
        if (large(kit, "ribbon/copy-to", .folder_open, widgets.argb(0xFFE8B428), "Copy\nto", true, chosen)) self.menu = .copy_to;
        if (large(kit, "ribbon/delete", .dismiss, widgets.argb(0xFFE81123), "Delete", true, chosen)) actions.delete(self, false);
        if (large(kit, "ribbon/rename", .rename, null, "Rename", false, one)) if (t.current()) |i| self.startRename(i);
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "New");
        if (large(kit, "ribbon/new-folder", .folder, widgets.argb(0xFFE8B428), "New\nfolder", false, in_folder)) actions.newFolder(self);
        smallColumnBegin(kit);
        defer smallColumnEnd(kit);
        if (small(kit, "ribbon/new-item", .document, null, "New item", true, in_folder)) self.menu = .new;
        _ = small(kit, "ribbon/easy-access", .star, null, "Easy access", true, false);
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Open");
        if (large(kit, "ribbon/properties", .info, null, "Properties", true, chosen or in_folder)) self.openProperties();
        smallColumnBegin(kit);
        defer smallColumnEnd(kit);
        if (small(kit, "ribbon/open", .open, null, "Open", true, chosen)) if (t.current()) |i| self.open(i, false);
        _ = small(kit, "ribbon/edit", .edit, null, "Edit", false, false);
        _ = small(kit, "ribbon/history", .clock, null, "History", false, false);
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Select");
        smallColumnBegin(kit);
        defer smallColumnEnd(kit);
        if (small(kit, "ribbon/select-all", .checkmark_circle, null, "Select all", false, t.count() > 0)) t.selectAll();
        if (small(kit, "ribbon/select-none", .dismiss, null, "Select none", false, chosen)) t.selectNone();
        if (small(kit, "ribbon/invert", .arrow_sync, null, "Invert selection", false, t.count() > 0)) t.invertSelection();
    }
}

fn shareTab(self: *Files, kit: *Kit) void {
    const t = self.tab();
    const chosen = t.selectedCount() > 0;
    {
        groupBegin(kit);
        defer groupEnd(kit, "Send");
        _ = large(kit, "ribbon/share", .share, null, "Share", false, false);
        if (large(kit, "ribbon/email", .mail, null, "Email", false, chosen)) actions.email(self);
        if (large(kit, "ribbon/zip", .folder, widgets.argb(0xFFE8B428), "Zip", false, chosen)) actions.zip(self);
        smallColumnBegin(kit);
        defer smallColumnEnd(kit);
        _ = small(kit, "ribbon/burn", .save, null, "Burn to disc", false, false);
        _ = small(kit, "ribbon/print", .print, null, "Print", false, false);
        _ = small(kit, "ribbon/fax", .document, null, "Fax", false, false);
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Share with");
        _ = large(kit, "ribbon/stop-sharing", .lock_closed, null, "Stop\nsharing", false, false);
        _ = large(kit, "ribbon/security", .shield, null, "Advanced\nsecurity", false, false);
    }
}

fn viewTab(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const t = self.tab();
    {
        groupBegin(kit);
        defer groupEnd(kit, "Panes");
        if (large(kit, "ribbon/nav-pane", .navigation, null, "Navigation\npane", true, true)) {
            self.show_nav = !self.show_nav;
            self.savePrefs();
        }
        smallColumnBegin(kit);
        defer smallColumnEnd(kit);
        if (small(kit, "ribbon/preview-pane", .eye, null, "Preview pane", false, true)) self.togglePane(.preview);
        if (small(kit, "ribbon/details-pane", .info, null, "Details pane", false, true)) self.togglePane(.details);
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Layout");
        const names = [_][]const u8{ "Extra large icons", "Large icons", "Medium icons", "Small icons", "List", "Details", "Tiles", "Content" };
        const glyphs = [_]widgets.icons.Name{ .image, .image, .grid, .grid, .list, .text_bullet_list, .apps_list, .task_list_ltr };
        // Two rows of four, the one shown lit.
        u.open(.{ .direction = .top_to_bottom, .gap = 0 });
        defer u.close();
        for (0..3) |row| {
            u.open(.{ .gap = 0 });
            defer u.close();
            for (0..3) |col| {
                const k = row * 3 + col;
                if (k >= names.len) break;
                const view: Tab.View = @enumFromInt(k);
                const id = kit.print("ribbon/layout/{d}", .{k});
                const lit = t.view == view;
                const hovered = u.isPointerOver(id);
                u.open(.{
                    .id = id,
                    .width = .fixed(118),
                    .height = .fixed(22),
                    .padding = .xy(3, 0),
                    .gap = 5,
                    .align_y = .center,
                    .background_color = if (lit) pressColor(kit) else if (hovered) hoverColor(kit) else .transparent,
                    .border = if (lit or hovered) .{ .color = hoverEdge(kit), .width = .all(1) } else .{},
                });
                kit.icon(glyphs[k], 16, blue(kit), .regular);
                var style = kit.style(.caption, kit.theme.palette.text_primary);
                style.wrap = .none;
                u.text(names[k], style);
                if (u.justReleased()) self.setView(view);
                u.close();
            }
        }
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Current view");
        if (large(kit, "ribbon/sort", .arrow_sort, null, "Sort\nby", true, t.lists())) self.menu = .sort;
        smallColumnBegin(kit);
        defer smallColumnEnd(kit);
        if (small(kit, "ribbon/group", .apps_list, null, "Group by", true, t.lists())) self.menu = .group;
        _ = small(kit, "ribbon/columns", .text_bullet_list, null, "Add columns", true, false);
        _ = small(kit, "ribbon/fit", .arrow_sync, null, "Size all columns to fit", false, false);
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "Show/hide");
        smallColumnBegin(kit);
        if (check(kit, "ribbon/checkboxes", "Item check boxes", self.check_boxes)) {
            self.check_boxes = !self.check_boxes;
            self.savePrefs();
        }
        if (check(kit, "ribbon/extensions", "File name extensions", self.show_extensions)) {
            self.show_extensions = !self.show_extensions;
            self.savePrefs();
        }
        if (check(kit, "ribbon/hidden", "Hidden items", self.show_hidden)) self.toggleHidden();
        smallColumnEnd(kit);
        _ = large(kit, "ribbon/hide-selected", .eye_off, null, "Hide selected\nitems", false, false);
    }
    {
        groupBegin(kit);
        defer groupEnd(kit, "");
        _ = large(kit, "ribbon/options", .settings, null, "Options", false, false);
    }
}

/// Windows 10's File menu: a new window, the terminal here, close.
pub fn fileMenu(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    if (self.window.down and !u.isPointerOver("menu/file") and !u.isPointerOver("ribbon/file")) {
        self.menu = .none;
        return;
    }
    kit.menuBegin("menu/file", .{ .attach = .id, .to = "ribbon/file", .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 }, .z_index = 50 });
    defer kit.menuEnd();
    if (kit.menuItem("menu/file/window", "Open new window", .{ .icon = .window, .shortcut = "Ctrl+N" })) {
        self.menu = .none;
        self.openNewWindow();
    }
    if (kit.menuItem("menu/file/terminal", "Open terminal here", .{ .icon = .window_console, .disabled = self.tab().path() == null })) {
        self.menu = .none;
        actions.terminalHere(self);
    }
    kit.menuSeparator();
    if (kit.menuItem("menu/file/close", "Close", .{ .icon = .dismiss })) {
        self.menu = .none;
        self.window.close();
    }
}
