// SPDX-License-Identifier: BSD-2-Clause

//! Windows 11's window: the tabs in its title bar, and the command bar
//! under the address row.
//!
//! ```
//! ┌[▢ Documents ×]│[▢ Downloads ×][+]───────────────────────[─][▢][✕]┐
//! │ (address row)                                                      │
//! │ ⊕ New ˅ │ ✂ ⧉ 📋 ✎ ⤴ 🗑 │ ⇅ Sort ˅  ▦ View ˅  ···        ▭ Details │
//! ```

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;

const Files = @import("Files.zig");
const Window = @import("Window.zig");
const actions = @import("actions.zig");
const chrome = @import("chrome.zig");

/// The title bar's height, the tabs at its foot.
pub const title_h = 40;
const tab_h = 32;
const caption_w = 46;
/// How long the pointer rests on the maximise button before the layouts.
const maximize_rest_ms = 400;

pub fn titleBar(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const window = &self.window;
    u.open(.{ .id = "titlebar", .width = .grow, .height = .fixed(title_h), .align_y = .bottom, .padding = .trbl(0, 0, 0, 8) });
    defer u.close();
    const ink = if (window.activated) p.text_primary else p.text_secondary;
    {
        u.open(.{ .id = "tabs", .height = .fixed(tab_h), .align_y = .center, .gap = 0 });
        defer u.close();
        var close_index: ?usize = null;
        var switch_index: ?usize = null;
        for (self.tabs.items, 0..) |t, i| {
            const id = kit.print("tab/{d}", .{i});
            const front = i == self.active;
            const hovered = u.isPointerOver(id);
            // Between two tabs neither in front: a thin line, as Windows'.
            if (i > 0 and !front and i - 1 != self.active) {
                u.empty(.{ .width = .fixed(1), .height = .fixed(16), .background_color = p.divider });
            } else if (i > 0) u.empty(.{ .width = .fixed(1) });
            u.open(.{
                .id = id,
                .width = .fixed(tabWidth(self)),
                .height = .fixed(tab_h),
                .padding = .trbl(0, 4, 0, 12),
                .gap = 8,
                .align_y = .center,
                .corner_radius = .corners(8, 8, 0, 0),
                .background_color = if (front) chrome.toolbarColor(kit) else if (hovered) p.subtle_secondary else .transparent,
            });
            {
                kit.icon(.folder, 16, widgets.argb(0xFFE8B428), .filled);
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
            // A middle click closes it; a right click opens its menu.
            if (self.middle_click and hovered) {
                self.middle_click = false;
                close_index = i;
            }
            if (self.context_at != null and hovered) {
                self.context_at = null;
                self.tab_menu = i;
                self.menu = .tab;
            }
        }
        u.empty(.{ .width = .fixed(4) });
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

/// A tab's own menu: Windows 11's.
pub fn tabMenu(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const index = self.tab_menu;
    if (index >= self.tabs.items.len) {
        self.menu = .none;
        return;
    }
    const anchor = kit.print("tab/{d}", .{index});
    if (self.window.down and !u.isPointerOver("menu/tab") and !u.isPointerOver(anchor)) {
        self.menu = .none;
        return;
    }
    kit.menuBegin("menu/tab", .{ .attach = .id, .to = anchor, .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 }, .offset = .{ .x = 0, .y = 2 }, .z_index = 50 });
    defer kit.menuEnd();
    const many = self.tabs.items.len > 1;
    if (kit.menuItem("menu/tab/duplicate", "Duplicate tab", .{ .icon = .tab_add })) {
        self.menu = .none;
        self.newTab(self.tabs.items[index].location);
    }
    if (kit.menuItem("menu/tab/close", "Close tab", .{ .icon = .dismiss, .shortcut = "Ctrl+W" })) {
        self.menu = .none;
        self.closeTab(index);
        return;
    }
    if (kit.menuItem("menu/tab/others", "Close other tabs", .{ .disabled = !many })) {
        self.menu = .none;
        self.closeOtherTabs(index);
        return;
    }
    if (kit.menuItem("menu/tab/right", "Close tabs to the right", .{ .disabled = index + 1 >= self.tabs.items.len })) {
        self.menu = .none;
        while (self.tabs.items.len > index + 1) self.closeTab(self.tabs.items.len - 1);
    }
}

// -------------------------------------------------------------------------
// The command bar
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
        .gap = 2,
        .align_y = .center,
        .background_color = chrome.toolbarColor(kit),
        .border = .{ .color = p.divider, .width = .{ .bottom = 1 } },
    });
    defer u.close();
    if (menuButton(kit, "cmd/new", .add, "New", in_folder, true)) self.menu = if (self.menu == .new) .none else .new;
    divider(kit);
    if (commandButton(kit, "cmd/cut", .cut, "Cut (Ctrl+X)", chosen)) actions.copy(self, true);
    if (commandButton(kit, "cmd/copy", .copy, "Copy (Ctrl+C)", chosen)) actions.copy(self, false);
    if (commandButton(kit, "cmd/paste", .clipboard_paste, "Paste (Ctrl+V)", actions.canPaste(self))) actions.paste(self);
    if (commandButton(kit, "cmd/rename", .rename, "Rename (F2)", t.selectedCount() == 1)) if (t.current()) |i| self.startRename(i);
    if (commandButton(kit, "cmd/share", .share, "Share", chosen)) actions.email(self);
    if (commandButton(kit, "cmd/delete", .delete, "Delete (Del)", chosen)) actions.delete(self, false);
    divider(kit);
    if (menuButton(kit, "cmd/sort", .arrow_sort, "Sort", in_folder, false)) self.menu = if (self.menu == .sort) .none else .sort;
    if (menuButton(kit, "cmd/view", .grid, "View", true, false)) self.menu = if (self.menu == .view) .none else .view;
    // The Recycle Bin's own: emptied, or what is in it put back.
    if (t.location == .trash) {
        divider(kit);
        if (labelButton(kit, "cmd/empty", .delete, "Empty Recycle Bin") and t.count() > 0) self.confirm = .empty_trash;
        if (labelButton(kit, "cmd/restore", .arrow_reply, if (chosen) "Restore the selected items" else "Restore all items")) actions.restore(self, !chosen);
    }
    // What the chosen file is: a picture can be the wallpaper, an archive
    // taken out of.
    if (t.current()) |i| if (t.selectedCount() == 1) {
        const e = t.entry(i);
        if (std.mem.startsWith(u8, e.mime, "image/")) {
            divider(kit);
            if (labelButton(kit, "cmd/background", .image, "Set as background")) actions.setAsBackground(self);
        }
    };
    if (commandButton(kit, "cmd/more", .more_horizontal, "See more", true)) self.menu = if (self.menu == .more) .none else .more;
    u.empty(.{ .width = .grow });
    // The details pane, as Windows 11's command bar ends.
    const id = "cmd/details";
    const on = self.pane == .details;
    u.open(.{
        .id = id,
        .height = .fixed(32),
        .padding = .xy(10, 0),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(4),
        .background_color = if (on) p.subtle_tertiary else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
    });
    kit.icon(.info, 16, p.text_primary, .regular);
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.text("Details", style);
    if (u.justReleased()) self.togglePane(.details);
    u.close();
    kit.tooltip(id, "Details pane (Alt+Shift+P)");
}

fn divider(kit: *Kit) void {
    kit.ui.empty(.{ .width = .fixed(1), .height = .fixed(24), .background_color = kit.theme.palette.divider });
    kit.ui.empty(.{ .width = .fixed(2) });
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
        .height = .fixed(32),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(4),
        .background_color = if (enabled and u.isElementPressed(id)) p.subtle_tertiary else if (hovered) p.subtle_secondary else .transparent,
    });
    kit.icon(glyph, 16, if (enabled) p.text_primary else p.text_disabled, .regular);
    const clicked = enabled and u.justReleased();
    u.close();
    kit.tooltip(id, name);
    return clicked;
}

/// A command with its name beside its glyph: Set as background.
fn labelButton(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, name: []const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{
        .id = id,
        .height = .fixed(32),
        .padding = .xy(10, 0),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(4),
        .background_color = if (u.isElementPressed(id)) p.subtle_tertiary else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
    });
    kit.icon(glyph, 16, p.text_primary, .regular);
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.text(name, style);
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

/// A command with words and a "˅": New, Sort, View.
fn menuButton(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, name: []const u8, enabled: bool, accent: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .height = .fixed(32),
        .padding = .xy(10, 0),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(4),
        .background_color = if (enabled and u.isElementPressed(id)) p.subtle_tertiary else if (hovered) p.subtle_secondary else .transparent,
    });
    const ink = if (enabled) p.text_primary else p.text_disabled;
    kit.icon(glyph, 16, if (enabled and accent) p.accent_text else ink, .regular);
    var style = kit.style(.caption, ink);
    style.wrap = .none;
    u.text(name, style);
    kit.icon(.chevron_down, 10, ink, .regular);
    const clicked = enabled and u.justReleased();
    u.close();
    return clicked;
}
