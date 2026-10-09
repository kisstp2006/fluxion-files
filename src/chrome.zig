// SPDX-License-Identifier: BSD-2-Clause

//! What frames the folder: the title bar with the tabs (Windows 11's look),
//! the address row, Windows 11's command bar or Windows 10's ribbon, the
//! status bar, and the menus they open.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const Window = @import("Window.zig");

/// The title bar's height in Windows 11's look, the tabs at its foot.
const title_h = 40;
const tab_h = 32;
const caption_w = 46;
/// How long the pointer rests on the maximise button before the layouts.
const maximize_rest_ms = 400;

/// The surface the address row and the command bar are on - which the tab
/// in front joins - and the one the folder is on.
pub fn toolbarColor(kit: *Kit) Color {
    const p = &kit.theme.palette;
    if (kit.theme.look.style == .win10) return p.solid_base;
    return if (p.mode == .dark) widgets.argb(0xFF2C2C2C) else widgets.argb(0xFFF9F9F9);
}

pub fn contentColor(kit: *Kit) Color {
    const p = &kit.theme.palette;
    if (kit.theme.look.style == .win10) return p.solid_base;
    return if (p.mode == .dark) widgets.argb(0xFF191919) else widgets.argb(0xFFFFFFFF);
}

// -------------------------------------------------------------------------
// The title bar, the tabs in it
// -------------------------------------------------------------------------

pub fn titleBar(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const window = &self.window;
    u.open(.{ .id = "titlebar", .width = .grow, .height = .fixed(title_h), .align_y = .bottom, .padding = .trbl(0, 0, 0, 8) });
    defer u.close();
    const ink = if (window.activated) p.text_primary else p.text_secondary;
    {
        u.open(.{ .id = "tabs", .height = .fixed(tab_h), .align_y = .center, .gap = 2 });
        defer u.close();
        var close_index: ?usize = null;
        var switch_index: ?usize = null;
        for (self.tabs.items, 0..) |t, i| {
            const id = kit.print("tab/{d}", .{i});
            const front = i == self.active;
            const hovered = u.isPointerOver(id);
            u.open(.{
                .id = id,
                .width = .fixed(tabWidth(self)),
                .height = .fixed(tab_h),
                .padding = .trbl(0, 4, 0, 12),
                .gap = 8,
                .align_y = .center,
                .corner_radius = .corners(8, 8, 0, 0),
                .background_color = if (front) toolbarColor(kit) else if (hovered) p.subtle_secondary else .transparent,
            });
            {
                kit.icon(.folder, 16, if (front) p.accent_text else ink, .filled);
                u.open(.{ .width = .grow, .clip = .both });
                var style = kit.style(.caption, ink);
                style.wrap = .none;
                var buffer: [256]u8 = undefined;
                u.text(kit.print("{s}", .{self.titleOf(t, &buffer)}), style);
                u.close();
                const close_id = kit.print("tab/{d}/close", .{i});
                if (front or hovered or u.isPointerOver(close_id)) {
                    u.open(.{
                        .id = close_id,
                        .width = .fixed(24),
                        .height = .fixed(24),
                        .align_x = .center,
                        .align_y = .center,
                        .corner_radius = .all(4),
                        .background_color = if (u.isPointerOver(close_id)) p.subtle_secondary else .transparent,
                    });
                    kit.icon(.dismiss, 12, ink, .regular);
                    if (u.justReleased()) close_index = i;
                    u.close();
                }
                const on_close = u.isPointerOver(close_id);
                if (u.justPressed() and !on_close) switch_index = i;
            }
            u.close();
            // A middle click closes it - see `Files.pointerButton`.
        }
        if (kit.button("tab/new", "", .{ .kind = .subtle, .icon = .add })) self.newTab(self.tab().location);
        kit.tooltip("tab/new", "New tab (Ctrl+T)");
        if (switch_index) |i| self.switchTab(i);
        if (close_index) |i| self.closeTab(i);
    }
    // The empty part: where the window is dragged from, and a double click
    // maximises it.
    u.open(.{ .id = "titlebar/drag", .width = .grow, .height = .grow });
    if (u.justPressed()) {
        if (window.clickCount() >= 2) window.toggleMaximized() else window.startMove();
    }
    u.close();
    {
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
        // Resting on the maximise button: the compositor's layouts under
        // it, as under its own.
        if (u.isPointerOver("title/maximize") and !window.down) {
            const now = Window.nowMs();
            if (self.maximize_rest_ms == 0) self.maximize_rest_ms = now;
            if (!self.layouts_shown and now - self.maximize_rest_ms >= maximize_rest_ms) {
                self.layouts_shown = true;
                if (window.boxOf("title/maximize")) |box| window.showLayouts(box);
            } else if (!self.layouts_shown) window.wakeAt(self.maximize_rest_ms + maximize_rest_ms);
        } else {
            self.maximize_rest_ms = 0;
            self.layouts_shown = false;
        }
    }
}

/// Tabs share the room as Windows' do: up to 240 wide each, at least 100.
fn tabWidth(self: *Files) f32 {
    const room: f32 = @as(f32, @floatFromInt(self.window.width)) - 3 * caption_w - 160;
    const n: f32 = @floatFromInt(self.tabs.items.len);
    return std.math.clamp(room / @max(1, n), 100, 240);
}

// -------------------------------------------------------------------------
// The address row
// -------------------------------------------------------------------------

pub fn addressRow(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const t = self.tab();
    const ten = self.ten();
    u.open(.{
        .id = "address-row",
        .width = .grow,
        .height = .fixed(if (ten) 34 else 48),
        .padding = .xy(if (ten) 4 else 8, if (ten) 2 else 8),
        .gap = if (ten) 2 else 4,
        .align_y = .center,
        .background_color = toolbarColor(kit),
    });
    defer u.close();
    if (navButton(kit, "nav/back", .arrow_left, t.canGoBack(), "Back (Alt+Left)", ten)) self.goBack();
    if (navButton(kit, "nav/forward", .arrow_right, t.canGoForward(), "Forward (Alt+Right)", ten)) self.goForward();
    if (navButton(kit, "nav/up", .arrow_up, t.parentPath() != null, "Up (Alt+Up)", ten)) self.goUp();
    if (!ten) if (navButton(kit, "nav/refresh", .arrow_clockwise, t.path() != null, "Refresh (F5)", ten)) self.refresh();
    address(self, kit);
    {
        u.open(.{ .width = .fixed(if (ten) 240 else 280) });
        defer u.close();
        var placeholder_buffer: [256]u8 = undefined;
        kit.textField("search/field", .{
            .placeholder = kit.print("Search {s}", .{self.titleOf(t, &placeholder_buffer)}),
            .width = .grow,
            .icon = .search,
        });
    }
}

fn navButton(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, enabled: bool, tip: []const u8, ten: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const size: f32 = if (ten) 28 else 32;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(size),
        .height = .fixed(size),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(4),
        .background_color = if (enabled and u.isElementPressed(id)) p.subtle_tertiary else if (hovered) p.subtle_secondary else .transparent,
    });
    kit.icon(glyph, 16, if (enabled) p.text_primary else p.text_disabled, .regular);
    const clicked = enabled and u.justReleased();
    u.close();
    if (enabled) kit.tooltip(id, tip);
    return clicked;
}

/// The address bar: the way here as crumbs - each a button, a "›"
/// between - or, clicked on its empty part or F4, the path to type over.
fn address(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const ten = self.ten();
    if (self.editing_address) {
        u.open(.{ .width = .grow });
        defer u.close();
        kit.textField("address/field", .{ .width = .grow });
        // The path put in, chosen, once the field is there - a value set
        // before it is would be lost.
        if (self.address_draws < 3) {
            self.address_draws += 1;
            if (self.address_draws == 1) u.setFocus("address/field");
            if (self.address_draws == 2) {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const shown = switch (t.location) {
                    .folder => |path| path,
                    else => self.titleOf(t, &buffer),
                };
                u.setTextValue("address/field", shown);
                _ = u.textAction(.select_all);
            }
            self.window.redraw();
        }
        // Left without a path: the crumbs again.
        if (self.address_draws >= 3 and !u.isFocused("address/field")) self.editing_address = false;
        return;
    }
    const id = "address";
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(if (ten) 26 else 32),
        .padding = .xy(8, 0),
        .gap = 2,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (ten) p.solid_base else p.control,
        .border = .{ .color = p.control_stroke, .width = .all(1) },
        .clip = .both,
    });
    defer u.close();
    var to: ?Tab.Location = null;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    kit.icon(switch (t.location) {
        .home => .home,
        .this_pc => .desktop,
        .folder => .folder,
    }, 16, p.text_secondary, .regular);
    crumbSeparator(kit);
    switch (t.location) {
        .home => {
            if (crumb(kit, "crumb/home", if (ten) "Quick access" else "Home")) to = .home;
        },
        .this_pc => {
            if (crumb(kit, "crumb/pc", "This PC")) to = .this_pc;
        },
        .folder => |path| {
            // Under the home folder: from it, as Windows starts from the
            // person's folder; elsewhere from This PC and the drive.
            const home = self.places.home;
            const under_home = std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == '/');
            var start: usize = 0;
            if (under_home) {
                start = home.len;
                if (crumb(kit, "crumb/root", std.fs.path.basename(home))) to = .{ .folder = home };
            } else {
                if (crumb(kit, "crumb/pc", "This PC")) to = .this_pc;
                crumbSeparator(kit);
                if (crumb(kit, "crumb/root", "Local Disk (/)")) to = .{ .folder = "/" };
            }
            var parts = std.mem.tokenizeScalar(u8, path[start..], '/');
            var n: usize = 0;
            while (parts.next()) |part| : (n += 1) {
                crumbSeparator(kit);
                if (crumb(kit, kit.print("crumb/{d}", .{n}), part)) {
                    const end = @intFromPtr(part.ptr) - @intFromPtr(path.ptr) + part.len;
                    to = .{ .folder = std.fmt.bufPrint(&to_buffer, "{s}", .{path[0..end]}) catch path };
                }
            }
        },
    }
    // The empty part: the path to type.
    u.open(.{ .id = "address/empty", .width = .grow, .height = .grow });
    if (u.justReleased()) self.editAddress();
    u.close();
    if (to) |where| self.goTo(where);
}

fn crumb(kit: *Kit, id: []const u8, text: []const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{
        .id = id,
        .padding = .xy(6, 3),
        .corner_radius = .all(4),
        .background_color = if (u.isElementPressed(id)) p.subtle_tertiary else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
    });
    var style = kit.style(.body, p.text_primary);
    style.wrap = .none;
    u.text(text, style);
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

fn crumbSeparator(kit: *Kit) void {
    kit.icon(.chevron_right, 12, kit.theme.palette.text_secondary, .regular);
}

// -------------------------------------------------------------------------
// Windows 11's command bar
// -------------------------------------------------------------------------

pub fn commandBar(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const in_folder = t.path() != null;
    const chosen = t.selectedCount() > 0;
    u.open(.{
        .id = "commandbar",
        .width = .grow,
        .height = .fixed(48),
        .padding = .xy(12, 6),
        .gap = 4,
        .align_y = .center,
        .background_color = toolbarColor(kit),
        .border = .{ .color = p.divider, .width = .{ .bottom = 1 } },
    });
    defer u.close();
    if (menuButton(kit, "cmd/new", .add, "New", in_folder)) self.menu = if (self.menu == .new) .none else .new;
    divider(kit);
    _ = commandButton(kit, "cmd/cut", .cut, "Cut", chosen);
    _ = commandButton(kit, "cmd/copy", .copy, "Copy", chosen);
    _ = commandButton(kit, "cmd/paste", .clipboard_paste, "Paste", false);
    _ = commandButton(kit, "cmd/rename", .rename, "Rename", t.selectedCount() == 1);
    _ = commandButton(kit, "cmd/share", .share, "Share", chosen);
    _ = commandButton(kit, "cmd/delete", .delete, "Delete", chosen);
    divider(kit);
    if (menuButton(kit, "cmd/sort", .arrow_sort, "Sort", in_folder)) self.menu = if (self.menu == .sort) .none else .sort;
    if (menuButton(kit, "cmd/view", .grid, "View", true)) self.menu = if (self.menu == .view) .none else .view;
    if (commandButton(kit, "cmd/more", .more_horizontal, "See more", true)) self.menu = if (self.menu == .more) .none else .more;
    u.empty(.{ .width = .grow });
}

fn divider(kit: *Kit) void {
    kit.ui.empty(.{ .width = .fixed(1), .height = .fixed(24), .background_color = kit.theme.palette.divider });
}

/// A command's icon - its name a tooltip - as Windows 11's command bar has
/// them.
fn commandButton(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, name: []const u8, enabled: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(40),
        .height = .fixed(36),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(4),
        .background_color = if (enabled and u.isElementPressed(id)) p.subtle_tertiary else if (hovered) p.subtle_secondary else .transparent,
    });
    kit.icon(glyph, 20, if (enabled) p.text_primary else p.text_disabled, .regular);
    const clicked = enabled and u.justReleased();
    u.close();
    kit.tooltip(id, name);
    return clicked;
}

/// A command with words and a "˅": New, Sort, View.
fn menuButton(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, name: []const u8, enabled: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .height = .fixed(36),
        .padding = .xy(10, 0),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(4),
        .background_color = if (enabled and u.isElementPressed(id)) p.subtle_tertiary else if (hovered) p.subtle_secondary else .transparent,
    });
    const ink = if (enabled) p.text_primary else p.text_disabled;
    kit.icon(glyph, 20, if (enabled and glyph == .add) p.accent_text else ink, .regular);
    var style = kit.style(.body, ink);
    style.wrap = .none;
    u.text(name, style);
    kit.icon(.chevron_down, 12, ink, .regular);
    const clicked = enabled and u.justReleased();
    u.close();
    return clicked;
}

// -------------------------------------------------------------------------
// Windows 10's ribbon
// -------------------------------------------------------------------------

pub fn ribbon(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const chosen = t.selectedCount() > 0;
    // The tabs' names: File in the accent, then Home, Share, View.
    {
        u.open(.{ .width = .grow, .height = .fixed(24), .align_y = .center, .background_color = p.solid_base });
        defer u.close();
        u.open(.{ .height = .grow, .padding = .xy(14, 0), .align_y = .center, .background_color = p.accent });
        kit.label("File", .body, p.text_on_accent);
        u.close();
        for ([_][]const u8{ "Home", "Share", "View" }, 0..) |name, i| {
            const id = kit.print("ribbon/tab/{d}", .{i});
            const front = i == 0;
            u.open(.{
                .id = id,
                .height = .grow,
                .padding = .xy(12, 0),
                .align_y = .center,
                .background_color = if (front) toolbarColor(kit) else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
                .border = if (front) .{ .color = p.divider, .width = .{ .left = 1, .right = 1, .top = 1 } } else .{},
            });
            kit.label(name, .body, p.text_primary);
            u.close();
        }
    }
    u.open(.{
        .id = "ribbon",
        .width = .grow,
        .height = .fixed(92),
        .padding = .xy(4, 4),
        .gap = 0,
        .background_color = toolbarColor(kit),
        .border = .{ .color = p.divider, .width = .{ .top = 1, .bottom = 1 } },
    });
    defer u.close();
    {
        ribbonGroupBegin(kit, "Clipboard");
        defer ribbonGroupEnd(kit, "Clipboard");
        _ = ribbonLarge(kit, "ribbon/pin", .pin, "Pin to Quick\naccess", false);
        _ = ribbonLarge(kit, "ribbon/copy", .copy, "Copy", chosen);
        _ = ribbonLarge(kit, "ribbon/paste", .clipboard_paste, "Paste", false);
    }
    {
        ribbonGroupBegin(kit, "Organise");
        defer ribbonGroupEnd(kit, "Organise");
        _ = ribbonLarge(kit, "ribbon/delete", .delete, "Delete", chosen);
        _ = ribbonLarge(kit, "ribbon/rename", .rename, "Rename", t.selectedCount() == 1);
    }
    {
        ribbonGroupBegin(kit, "New");
        defer ribbonGroupEnd(kit, "New");
        _ = ribbonLarge(kit, "ribbon/new-folder", .folder, "New\nfolder", t.path() != null);
    }
    {
        ribbonGroupBegin(kit, "Open");
        defer ribbonGroupEnd(kit, "Open");
        if (ribbonLarge(kit, "ribbon/open", .open, "Open", t.selectedCount() == 1)) if (t.current()) |i| self.open(i, false);
    }
    {
        ribbonGroupBegin(kit, "Select");
        defer ribbonGroupEnd(kit, "Select");
        u.open(.{ .direction = .top_to_bottom, .gap = 2, .padding = .xy(4, 2) });
        defer u.close();
        if (ribbonSmall(kit, "ribbon/select-all", .checkmark, "Select all", t.count() > 0)) t.selectAll();
        if (ribbonSmall(kit, "ribbon/select-none", .dismiss, "Select none", chosen)) t.selectNone();
        if (ribbonSmall(kit, "ribbon/invert", .arrow_sync, "Invert selection", t.count() > 0)) t.invertSelection();
    }
}

fn ribbonGroupBegin(kit: *Kit, _: []const u8) void {
    const u = kit.ui;
    u.open(.{ .height = .grow, .direction = .top_to_bottom, .padding = .xy(2, 0), .border = .{ .color = kit.theme.palette.divider, .width = .{ .right = 1 } } });
    u.open(.{ .height = .grow, .gap = 2 });
}

fn ribbonGroupEnd(kit: *Kit, name: []const u8) void {
    const u = kit.ui;
    u.close();
    u.open(.{ .width = .grow, .align_x = .center });
    kit.label(name, .caption, kit.theme.palette.text_secondary);
    u.close();
    u.close();
}

/// A large ribbon button: a 32 px glyph over its name.
fn ribbonLarge(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, name: []const u8, enabled: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .xy(6, 2),
        .gap = 2,
        .align_x = .center,
        .background_color = if (enabled and u.isElementPressed(id)) argbWin10Pressed(kit) else if (hovered) argbWin10Hover(kit) else .transparent,
        .border = if (hovered) .{ .color = argbWin10Edge(kit), .width = .all(1) } else .{},
    });
    kit.icon(glyph, 28, if (enabled) p.accent_text else p.text_disabled, .regular);
    var style = kit.style(.caption, if (enabled) p.text_primary else p.text_disabled);
    style.alignment = .center;
    u.text(name, style);
    const clicked = enabled and u.justReleased();
    u.close();
    return clicked;
}

fn ribbonSmall(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, name: []const u8, enabled: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .height = .fixed(22),
        .padding = .xy(4, 0),
        .gap = 6,
        .align_y = .center,
        .background_color = if (enabled and u.isElementPressed(id)) argbWin10Pressed(kit) else if (hovered) argbWin10Hover(kit) else .transparent,
        .border = if (hovered) .{ .color = argbWin10Edge(kit), .width = .all(1) } else .{},
    });
    kit.icon(glyph, 16, if (enabled) p.accent_text else p.text_disabled, .regular);
    var style = kit.style(.caption, if (enabled) p.text_primary else p.text_disabled);
    style.wrap = .none;
    u.text(name, style);
    const clicked = enabled and u.justReleased();
    u.close();
    return clicked;
}

/// Windows 10's ribbon buttons: light blue under the pointer, a deeper blue
/// pressed - in dark mode, greys.
fn argbWin10Hover(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF3E3E3E) else widgets.argb(0xFFE5F3FF);
}

fn argbWin10Pressed(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF4D4D4D) else widgets.argb(0xFFCCE8FF);
}

fn argbWin10Edge(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF5A5A5A) else widgets.argb(0xFFCCE8FF);
}

// -------------------------------------------------------------------------
// The status bar
// -------------------------------------------------------------------------

pub fn statusBar(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const ten = self.ten();
    u.open(.{
        .id = "statusbar",
        .width = .grow,
        .height = .fixed(if (ten) 22 else 26),
        .padding = .xy(12, 0),
        .gap = 16,
        .align_y = .center,
        .background_color = contentColor(kit),
    });
    defer u.close();
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    if (t.path() != null) {
        const n = t.count();
        u.text(kit.print("{d} item{s}", .{ n, if (n == 1) "" else "s" }), style);
        const chosen = t.selectedCount();
        if (chosen > 0) {
            u.empty(.{ .width = .fixed(1), .height = .fixed(12), .background_color = p.divider });
            var size_buffer: [32]u8 = undefined;
            const size = t.selectedSize();
            if (size > 0) {
                u.text(kit.print("{d} item{s} selected  {s}", .{ chosen, if (chosen == 1) "" else "s", Folder.sizeText(size, &size_buffer) }), style);
            } else u.text(kit.print("{d} item{s} selected", .{ chosen, if (chosen == 1) "" else "s" }), style);
        }
        if (t.folder) |f| if (f.failure) |err| {
            var failed = kit.style(.caption, p.critical);
            failed.wrap = .none;
            u.text(kit.print("Could not read this folder: {t}", .{err}), failed);
        };
    }
    u.empty(.{ .width = .grow });
    if (viewToggle(kit, "status/details", .text_bullet_list, t.view == .details, "Details")) self.setView(.details);
    if (viewToggle(kit, "status/icons", .grid, t.view == .large, "Large icons")) self.setView(.large);
}

fn viewToggle(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, on: bool, tip: []const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{
        .id = id,
        .width = .fixed(24),
        .height = .fixed(20),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(3),
        .background_color = if (on) p.subtle_tertiary else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
    });
    kit.icon(glyph, 14, p.text_primary, .regular);
    const clicked = u.justReleased();
    u.close();
    kit.tooltip(id, tip);
    return clicked;
}

// -------------------------------------------------------------------------
// The menus the command bar opens
// -------------------------------------------------------------------------

pub fn menus(self: *Files, kit: *Kit) void {
    switch (self.menu) {
        .none => {},
        .view => viewMenu(self, kit),
        .sort => sortMenu(self, kit),
        .more => moreMenu(self, kit),
        .new => newMenu(self, kit),
    }
}

fn under(id: []const u8) ui.layout.Floating {
    return .{
        .attach = .id,
        .to = id,
        .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 },
        .offset = .{ .x = 0, .y = 4 },
        .z_index = 50,
    };
}

/// A press anywhere but on the menu or its button closes it.
fn closeOnPressOutside(self: *Files, kit: *Kit, menu_id: []const u8, button_id: []const u8) void {
    const u = kit.ui;
    if (self.window.down and !u.isPointerOver(menu_id) and !u.isPointerOver(button_id)) self.menu = .none;
}

fn viewMenu(self: *Files, kit: *Kit) void {
    closeOnPressOutside(self, kit, "menu/view", "cmd/view");
    kit.menuBegin("menu/view", under("cmd/view"));
    defer kit.menuEnd();
    const t = self.tab();
    const items = [_]struct { view: Tab.View, name: []const u8, keys: []const u8 }{
        .{ .view = .extra_large, .name = "Extra large icons", .keys = "Ctrl+Shift+1" },
        .{ .view = .large, .name = "Large icons", .keys = "Ctrl+Shift+2" },
        .{ .view = .medium, .name = "Medium icons", .keys = "Ctrl+Shift+3" },
        .{ .view = .small, .name = "Small icons", .keys = "Ctrl+Shift+4" },
        .{ .view = .list, .name = "List", .keys = "Ctrl+Shift+5" },
        .{ .view = .details, .name = "Details", .keys = "Ctrl+Shift+6" },
        .{ .view = .tiles, .name = "Tiles", .keys = "Ctrl+Shift+7" },
        .{ .view = .content, .name = "Content", .keys = "Ctrl+Shift+8" },
    };
    for (items) |item| {
        if (kit.menuItem(kit.print("menu/view/{t}", .{item.view}), item.name, .{ .icon = if (t.view == item.view) .checkmark else null, .shortcut = item.keys })) self.setView(item.view);
    }
    kit.menuSeparator();
    if (kit.menuItem("menu/view/hidden", "Hidden items", .{ .icon = if (self.show_hidden) .checkmark else null })) {
        self.show_hidden = !self.show_hidden;
        for (self.tabs.items) |each| each.refilter(self.show_hidden);
        self.menu = .none;
    }
    if (kit.menuItem("menu/view/extensions", "File name extensions", .{ .icon = if (self.show_extensions) .checkmark else null })) {
        self.show_extensions = !self.show_extensions;
        self.menu = .none;
    }
}

fn sortMenu(self: *Files, kit: *Kit) void {
    closeOnPressOutside(self, kit, "menu/sort", "cmd/sort");
    kit.menuBegin("menu/sort", under("cmd/sort"));
    defer kit.menuEnd();
    const t = self.tab();
    const items = [_]struct { by: Folder.Column, name: []const u8 }{
        .{ .by = .name, .name = "Name" },
        .{ .by = .modified, .name = "Date modified" },
        .{ .by = .type, .name = "Type" },
        .{ .by = .size, .name = "Size" },
    };
    for (items) |item| {
        if (kit.menuItem(kit.print("menu/sort/{t}", .{item.by}), item.name, .{ .icon = if (t.sort_by == item.by) .checkmark else null })) {
            if (t.sort_by != item.by) t.sortBy(item.by, &self.mime, self.show_hidden);
            self.menu = .none;
        }
    }
    kit.menuSeparator();
    if (kit.menuItem("menu/sort/ascending", "Ascending", .{ .icon = if (t.ascending) .checkmark else null })) {
        if (!t.ascending) t.sortBy(t.sort_by, &self.mime, self.show_hidden);
        self.menu = .none;
    }
    if (kit.menuItem("menu/sort/descending", "Descending", .{ .icon = if (!t.ascending) .checkmark else null })) {
        if (t.ascending) t.sortBy(t.sort_by, &self.mime, self.show_hidden);
        self.menu = .none;
    }
}

fn moreMenu(self: *Files, kit: *Kit) void {
    closeOnPressOutside(self, kit, "menu/more", "cmd/more");
    kit.menuBegin("menu/more", under("cmd/more"));
    defer kit.menuEnd();
    const t = self.tab();
    if (kit.menuItem("menu/more/all", "Select all", .{ .icon = .checkmark, .shortcut = "Ctrl+A", .disabled = t.count() == 0 })) {
        t.selectAll();
        self.menu = .none;
    }
    if (kit.menuItem("menu/more/none", "Select none", .{ .icon = .dismiss, .disabled = t.selectedCount() == 0 })) {
        t.selectNone();
        self.menu = .none;
    }
    if (kit.menuItem("menu/more/invert", "Invert selection", .{ .icon = .arrow_sync, .disabled = t.count() == 0 })) {
        t.invertSelection();
        self.menu = .none;
    }
}

fn newMenu(self: *Files, kit: *Kit) void {
    closeOnPressOutside(self, kit, "menu/new", "cmd/new");
    kit.menuBegin("menu/new", under("cmd/new"));
    defer kit.menuEnd();
    _ = kit.menuItem("menu/new/folder", "Folder", .{ .icon = .folder, .shortcut = "Ctrl+Shift+N" });
    _ = kit.menuItem("menu/new/text", "Text Document", .{ .icon = .document });
}
