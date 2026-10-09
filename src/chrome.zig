// SPDX-License-Identifier: BSD-2-Clause

//! What frames the folder in both looks: the address row, the status bar,
//! and the menus the command bar and the ribbon open. The title bars, the
//! command bar and the ribbon are each look's own: `win11.zig`, `win10.zig`.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const actions = @import("actions.zig");
const win10 = @import("win10.zig");
const win11 = @import("win11.zig");
const menus_mod = @import("menus.zig");
const icons = @import("icons.zig");
const nav = @import("nav.zig");

/// The surface the address row and the command bar are on - which the tab
/// in front joins.
pub fn toolbarColor(kit: *Kit) Color {
    const p = &kit.theme.palette;
    if (kit.theme.look.style == .win10) return win10.windowColor(kit);
    return if (p.mode == .dark) widgets.argb(0xFF2C2C2C) else widgets.argb(0xFFF9F9F9);
}

/// The surface the folder and the navigation pane are on.
pub fn contentColor(kit: *Kit) Color {
    const p = &kit.theme.palette;
    if (kit.theme.look.style == .win10) return win10.windowColor(kit);
    return if (p.mode == .dark) widgets.argb(0xFF191919) else widgets.argb(0xFFFFFFFF);
}

/// What is chosen or under the pointer, Windows 10's way or 11's.
pub fn hoverFill(kit: *Kit) Color {
    return if (kit.theme.look.style == .win10) win10.hoverColor(kit) else kit.theme.palette.subtle_secondary;
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
        .padding = .xy(if (ten) 6 else 8, if (ten) 5 else 8),
        .gap = if (ten) 0 else 4,
        .align_y = .center,
        .background_color = toolbarColor(kit),
    });
    defer u.close();
    if (navButton(self, kit, "nav/back", .arrow_left, t.canGoBack(), "Back (Alt+Left)")) self.goBack();
    if (navButton(self, kit, "nav/forward", .arrow_right, t.canGoForward(), "Forward (Alt+Right)")) self.goForward();
    // Windows 10's: the places been to lately, under a small arrow.
    if (ten) if (navButton(self, kit, "nav/recent", .chevron_down, t.canGoBack() or t.canGoForward(), "Recent locations")) {
        self.menu = if (self.menu == .recent) .none else .recent;
    };
    if (navButton(self, kit, "nav/up", .arrow_up, t.parentPath() != null or t.location == .home, "Up to the folder above (Alt+Up)")) self.goUp();
    if (!ten) if (navButton(self, kit, "nav/refresh", .arrow_clockwise, t.path() != null, "Refresh (F5)")) self.refresh();
    if (ten) u.empty(.{ .width = .fixed(6) });
    address(self, kit);
    u.empty(.{ .width = .fixed(if (ten) 6 else 0) });
    {
        u.open(.{ .width = .fixed(if (ten) 220 else 280) });
        defer u.close();
        var placeholder_buffer: [256]u8 = undefined;
        searchField(self, kit, kit.print("Search {s}", .{self.titleOf(t, &placeholder_buffer)}));
    }
}

/// The search box: the address bar's twin - as tall, the same frame and
/// type - the magnifier at its end, an ✕ to clear it while it has a
/// search.
fn searchField(self: *Files, kit: *Kit, placeholder: []const u8) void {
    const u = kit.ui;
    fieldBegin(self, kit, "search/frame", "search/field", placeholder);
    defer u.close();
    const value: []const u8 = u.textValueOf("search/field") orelse "";
    const typed = value.len > 0;
    if (fieldEnd(self, kit, "search/end", if (typed) .dismiss else .search, if (typed) 10 else 14) and typed) self.closeSearch();
    if (u.textChanged("search/field")) self.searchChanged();
}

/// A button at a field's end: Windows 10's square, 11's rounded.
fn fieldEnd(self: *Files, kit: *Kit, id: []const u8, glyph: widgets.icons.Name, size: u16) bool {
    if (self.ten()) return addressEnd(kit, id, glyph, size);
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .id = id, .width = .fixed(26), .height = .fixed(24), .align_x = .center, .align_y = .center, .corner_radius = .all(4), .background_color = if (u.isPointerOver(id)) p.subtle_secondary else .transparent });
    kit.icon(glyph, size, p.text_secondary, .regular);
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

/// A field as the address bar and the search box are, in either look: its
/// frame opened - the caller adds what goes at its end and closes it -
/// and the text in it in the address bar's type.
fn fieldBegin(self: *Files, kit: *Kit, frame_id: []const u8, field_id: []const u8, placeholder: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const focused = u.isFocused(field_id);
    const hovered = u.isPointerOver(frame_id);
    u.open(.{
        .id = frame_id,
        .width = .grow,
        .height = .fixed(if (ten) address_h else 32),
        .padding = if (ten) .trbl(0, 0, 0, 6) else .trbl(0, 4, 0, 10),
        .gap = 2,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (ten) win10.windowColor(kit) else if (focused) p.control_input_active else if (hovered) p.control_secondary else p.control,
        .border = .{ .color = if (ten) win10Frame(kit, focused, hovered) else p.control_stroke, .width = .all(1) },
        .cursor = .ibeam,
    });
    // Windows 11's accent line along the bottom while it has the caret.
    if (!ten and focused) u.empty(.{
        .width = .percent(1),
        .height = .fixed(2),
        .background_color = p.accent,
        .floating = .{ .attach = .parent, .fractions = .{ .element_x = 0, .element_y = 1, .target_x = 0, .target_y = 1 } },
        .passthrough = true,
    });
    const caption = kit.typeOf(.caption);
    u.textInput(.{ .id = field_id, .width = .grow, .height = .fixed(@floatFromInt(caption.line)) }, .{
        .placeholder = placeholder,
        .font_size = caption.size,
        .line_height = caption.line,
        .text_color = p.text_primary,
        .placeholder_color = p.text_secondary,
        .cursor_color = p.text_primary,
        .selection_color = kit.theme.accent.base.withAlpha(0.6),
    });
}

/// The frame of Windows 10's address bar and search box: grey, darker
/// under the pointer, blue with the caret.
fn win10Frame(kit: *Kit, focused: bool, hovered: bool) Color {
    if (focused) return widgets.argb(0xFF0078D7);
    if (hovered) return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF7A7A7A) else widgets.argb(0xFFA6A6A6);
    return win10.edgeColor(kit);
}

/// Windows 10's address bar and search box are this tall.
const address_h = 24;

fn navButton(self: *Files, kit: *Kit, id: []const u8, glyph: widgets.icons.Name, enabled: bool, tip: []const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const small = glyph == .chevron_down;
    const size: f32 = if (ten) (if (small) 14 else 26) else 32;
    const hovered = enabled and u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(size),
        .height = .fixed(if (ten) 24 else 32),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (ten) .transparent else if (enabled and u.isElementPressed(id)) p.subtle_tertiary else if (hovered) p.subtle_secondary else .transparent,
    });
    // Windows 10's arrows turn blue under the pointer rather than lighting
    // a plate.
    const colour = if (!enabled) p.text_disabled else if (ten and hovered) widgets.argb(0xFF1979CA) else if (ten) p.text_secondary else p.text_primary;
    kit.icon(glyph, if (small) 10 else 16, colour, .regular);
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
        fieldBegin(self, kit, "address/frame", "address/field", "");
        defer u.close();
        if (ten) {
            _ = addressEnd(kit, "address/history", .chevron_down, 10);
            u.empty(.{ .width = .fixed(1), .height = .grow, .background_color = win10.edgeColor(kit) });
        }
        _ = fieldEnd(self, kit, "address/go", .arrow_right, 14);
        // Go to: on the press - the field has lost the caret by the release.
        if (u.justPressed() and u.isPointerOver("address/go")) {
            const typed: []const u8 = u.textValueOf("address/field") orelse "";
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const copy = std.fmt.bufPrint(&buffer, "{s}", .{typed}) catch return;
            self.editing_address = false;
            return self.goToTyped(copy);
        }
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
        .height = .fixed(if (ten) address_h else 32),
        .padding = .trbl(0, 0, 0, if (ten) 4 else 8),
        .gap = 0,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (ten) win10.windowColor(kit) else p.control,
        .border = .{ .color = if (ten) win10Frame(kit, false, u.isPointerOver(id)) else p.control_stroke, .width = .all(1) },
        .clip = .both,
    });
    defer u.close();
    var to: ?Tab.Location = null;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    switch (t.location) {
        // A folder's own picture, as Windows puts it at the start.
        .folder => |path| icons.themed(self, kit, if (std.mem.eql(u8, path, "/")) "drive-harddisk" else icons.special(self.places.specialOf(path)), 16),
        .trash => icons.themed(self, kit, "user-trash", 16),
        else => kit.icon(switch (t.location) {
            .home => if (ten) .star else .home,
            .this_pc => .desktop,
            else => .search,
        }, 16, if (ten and t.location == .home) widgets.argb(0xFF2B88D8) else p.text_secondary, if (ten and t.location == .home) .filled else .regular),
    }
    crumbSeparator(self, kit, "crumb/sep/root", "");
    switch (t.location) {
        .home => {
            if (crumb(self, kit, "crumb/home", if (ten) "Quick access" else "Home")) to = .home;
        },
        .this_pc => {
            if (crumb(self, kit, "crumb/pc", "This PC")) to = .this_pc;
        },
        .trash => {
            if (crumb(self, kit, "crumb/trash", "Recycle Bin")) to = .trash;
        },
        .search => |q| {
            var style = kit.style(.caption, p.text_primary);
            style.wrap = .none;
            u.text(kit.print("Search results in {s}", .{std.fs.path.basename(q.folder)}), style);
        },
        .folder => |path| {
            // In a person's folder: from it - after This PC in Windows 10,
            // on its own in 11, as Windows shows its known folders. Under
            // the home folder: from it. Elsewhere from This PC and the
            // drive.
            const home = self.places.home;
            var start: usize = 0;
            var root: []const u8 = "/";
            if (self.knownFolderOf(path)) |known| {
                start = known.path.len;
                root = known.path;
                if (ten) {
                    if (crumb(self, kit, "crumb/pc", "This PC")) to = .this_pc;
                    crumbSeparator(self, kit, "crumb/sep/pc", "");
                }
                if (crumb(self, kit, "crumb/root", known.name)) to = .{ .folder = known.path };
            } else if (within(path, home)) {
                start = home.len;
                root = home;
                if (crumb(self, kit, "crumb/root", std.fs.path.basename(home))) to = .{ .folder = home };
            } else {
                if (crumb(self, kit, "crumb/pc", "This PC")) to = .this_pc;
                crumbSeparator(self, kit, "crumb/sep/pc", "");
                if (crumb(self, kit, "crumb/root", self.places.rootName())) to = .{ .folder = "/" };
            }
            var parts = std.mem.tokenizeScalar(u8, path[start..], '/');
            var n: usize = 0;
            var before: []const u8 = root;
            while (parts.next()) |part| : (n += 1) {
                crumbSeparator(self, kit, kit.print("crumb/sep/{d}", .{n}), before);
                const end = @intFromPtr(part.ptr) - @intFromPtr(path.ptr) + part.len;
                if (crumb(self, kit, kit.print("crumb/{d}", .{n}), part)) {
                    to = .{ .folder = std.fmt.bufPrint(&to_buffer, "{s}", .{path[0..end]}) catch path };
                }
                before = path[0..end];
            }
            // The last one's "›" too: the folders in the one shown.
            crumbSeparator(self, kit, "crumb/sep/last", path);
        },
    }
    // The empty part: the path to type.
    u.open(.{ .id = "address/empty", .width = .grow, .height = .grow });
    if (u.justReleased()) self.editAddress();
    u.close();
    // Windows 10's: the address's history, and refresh, at its end.
    if (ten) {
        _ = addressEnd(kit, "address/history", .chevron_down, 10);
        u.empty(.{ .width = .fixed(1), .height = .grow, .background_color = win10.edgeColor(kit) });
        if (addressEnd(kit, "address/refresh", .arrow_clockwise, 14)) self.refresh();
        kit.tooltip("address/refresh", "Refresh (F5)");
    }
    if (to) |where| self.goTo(where);
}

fn addressEnd(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, size: u16) bool {
    const u = kit.ui;
    u.open(.{ .id = id, .width = .fixed(22), .height = .grow, .align_x = .center, .align_y = .center, .background_color = if (u.isPointerOver(id)) win10.hoverColor(kit) else .transparent });
    kit.icon(glyph, size, kit.theme.palette.text_secondary, .regular);
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

fn crumb(self: *Files, kit: *Kit, id: []const u8, text: []const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .height = .fixed(if (ten) 22 else 26),
        .padding = .xy(if (ten) 4 else 6, 0),
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (u.isElementPressed(id)) (if (ten) win10.pressColor(kit) else p.subtle_tertiary) else if (hovered) hoverFill(kit) else .transparent,
        .border = if (ten and hovered) .{ .color = win10.hoverEdge(kit), .width = .all(1) } else .{},
    });
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.text(text, style);
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

/// Whether `path` is `folder` or inside it.
fn within(path: []const u8, folder: []const u8) bool {
    return std.mem.startsWith(u8, path, folder) and (path.len == folder.len or path[folder.len] == '/');
}

/// A "›" between crumbs: clicked, the folders in `folder` - the crumb
/// before it - to go to, "˅" while they are shown. The first, with no
/// folder, lists the places.
fn crumbSeparator(self: *Files, kit: *Kit, id: []const u8, folder: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const open = self.menu == .crumb and std.mem.eql(u8, self.crumb_anchor_buffer[0..self.crumb_anchor_len], id);
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(if (ten) 16 else 18),
        .height = .fixed(if (ten) 22 else 26),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (open) (if (ten) win10.pressColor(kit) else p.subtle_tertiary) else if (hovered) hoverFill(kit) else .transparent,
        .border = if (ten and (hovered or open)) .{ .color = win10.hoverEdge(kit), .width = .all(1) } else .{},
    });
    kit.icon(if (open) .chevron_down else .chevron_right, 10, p.text_secondary, .regular);
    const clicked = u.justReleased();
    u.close();
    if (!clicked) return;
    if (open) {
        self.menu = .none;
        return;
    }
    if (self.crumb_list) |l| l.free(self.gpa);
    self.crumb_list = if (folder.len > 0) nav.readFolders(self, folder) else null;
    self.crumb_anchor_len = @min(id.len, self.crumb_anchor_buffer.len);
    @memcpy(self.crumb_anchor_buffer[0..self.crumb_anchor_len], id[0..self.crumb_anchor_len]);
    self.menu = .crumb;
}

/// The folders a "›" opened, or the places for the first.
fn crumbMenu(self: *Files, kit: *Kit) void {
    const anchor = self.crumb_anchor_buffer[0..self.crumb_anchor_len];
    if (closeOnPressOutside(self, kit, "menu/crumb", &.{anchor})) return;
    menus_mod.begin(self, kit, "menu/crumb", .{ .attach = .id, .to = anchor, .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 }, .z_index = 50 });
    defer menus_mod.end(kit);
    const list = self.crumb_list orelse {
        // The places, as the first "›" lists the desktop's.
        if (menus_mod.row(self, kit, "menu/crumb/home", if (self.ten()) "Quick access" else "Home", .{ .icon = if (self.ten()) .star else .home })) {
            close(self);
            return self.goTo(.home);
        }
        for (self.places.user.items, 0..) |f, i| if (menus_mod.row(self, kit, kit.print("menu/crumb/user/{d}", .{i}), f.name, .{ .themed = icons.special(f.special) })) {
            close(self);
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            return self.goTo(.{ .folder = std.fmt.bufPrint(&buffer, "{s}", .{f.path}) catch return });
        };
        if (menus_mod.row(self, kit, "menu/crumb/pc", "This PC", .{ .icon = .desktop })) {
            close(self);
            return self.goTo(.this_pc);
        }
        if (menus_mod.row(self, kit, "menu/crumb/trash", "Recycle Bin", .{ .themed = "user-trash" })) {
            close(self);
            return self.goTo(.trash);
        }
        return;
    };
    if (list.children.len == 0) {
        _ = menus_mod.row(self, kit, "menu/crumb/empty", "No folders", .{ .disabled = true });
        return;
    }
    const here = self.tab().path() orelse "";
    for (list.children, 0..) |child, i| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ if (std.mem.eql(u8, list.path, "/")) "" else list.path, child }) catch continue;
        // The one on the way to what is shown, in bold, as Windows marks it.
        if (menus_mod.row(self, kit, kit.print("menu/crumb/{d}", .{i}), child, .{ .themed = icons.special(self.places.specialOf(full)), .strong = within(here, full) })) {
            close(self);
            return self.goTo(.{ .folder = full });
        }
        if (i >= 200) break;
    }
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
        .padding = .xy(if (ten) 4 else 12, 0),
        .gap = if (ten) 12 else 8,
        .align_y = .center,
        .background_color = contentColor(kit),
    });
    defer u.close();
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    if (t.path() != null or t.location == .trash or t.location == .search) {
        const n = t.count();
        u.text(kit.print("{d} item{s}", .{ n, if (n == 1) "" else "s" }), style);
        const chosen = t.selectedCount();
        if (chosen > 0) {
            separator(self, kit);
            var size_buffer: [32]u8 = undefined;
            const size = t.selectedSize();
            if (size > 0) {
                u.text(kit.print("{d} item{s} selected  {s}", .{ chosen, if (chosen == 1) "" else "s", Folder.sizeText(size, &size_buffer) }), style);
            } else u.text(kit.print("{d} item{s} selected", .{ chosen, if (chosen == 1) "" else "s" }), style);
        }
        if (!ten and n > 0) separator(self, kit);
        if (self.searching()) {
            separator(self, kit);
            u.text("Searching…", style);
        }
    } else if (t.location == .this_pc) {
        u.text(kit.print("{d} items", .{self.places.drives.items.len + if (ten) self.places.user.items.len else 0}), style);
    }
    u.empty(.{ .width = .grow });
    if (viewToggle(self, kit, "status/details", .text_bullet_list, t.view == .details, "Displays information about each item in the window. (Ctrl+Shift+6)")) self.setView(.details);
    if (viewToggle(self, kit, "status/icons", .grid, t.view == .large, "Displays items by using large thumbnails. (Ctrl+Shift+2)")) self.setView(.large);
}

fn separator(self: *Files, kit: *Kit) void {
    if (self.ten()) return;
    kit.ui.empty(.{ .width = .fixed(1), .height = .fixed(14), .background_color = kit.theme.palette.divider });
}

fn viewToggle(self: *Files, kit: *Kit, id: []const u8, glyph: widgets.icons.Name, on: bool, tip: []const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(if (ten) 22 else 24),
        .height = .fixed(if (ten) 18 else 20),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 3),
        .background_color = if (on) (if (ten) win10.pressColor(kit) else p.subtle_tertiary) else if (hovered) hoverFill(kit) else .transparent,
        .border = if (ten and (on or hovered)) .{ .color = win10.hoverEdge(kit), .width = .all(1) } else .{},
    });
    kit.icon(glyph, 14, p.text_primary, .regular);
    const clicked = u.justReleased();
    u.close();
    kit.tooltip(id, tip);
    return clicked;
}

// -------------------------------------------------------------------------
// The menus the command bar and the ribbon open
// -------------------------------------------------------------------------

pub fn menus(self: *Files, kit: *Kit) void {
    switch (self.menu) {
        .none => if (self.context_open == null) {
            self.context_sub = .none;
        },
        .view => viewMenu(self, kit),
        .sort => sortMenu(self, kit),
        .group => groupMenu(self, kit),
        .more => moreMenu(self, kit),
        .new => newMenu(self, kit),
        .file => win10.fileMenu(self, kit),
        .move_to, .copy_to => placesMenu(self, kit),
        .recent => recentMenu(self, kit),
        .tab => win11.tabMenu(self, kit),
        .crumb => crumbMenu(self, kit),
    }
}

/// Under the button that opened it, whichever look's it is.
fn under(self: *Files, kit: *Kit, eleven: []const u8, ten: []const u8) ui.layout.Floating {
    const id = if (self.ten()) ten else eleven;
    _ = kit;
    return .{
        .attach = .id,
        .to = id,
        .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 },
        .offset = .{ .x = 0, .y = if (self.ten()) 0 else 4 },
        .z_index = 50,
    };
}

/// A press anywhere but on the menu or what opened it closes it.
fn closeOnPressOutside(self: *Files, kit: *Kit, menu_id: []const u8, buttons: []const []const u8) bool {
    const u = kit.ui;
    if (!self.window.down or u.isPointerOver(menu_id) or u.isPointerOver("context/sub")) return false;
    for (buttons) |b| if (u.isPointerOver(b)) return false;
    self.menu = .none;
    return true;
}

fn viewMenu(self: *Files, kit: *Kit) void {
    if (closeOnPressOutside(self, kit, "menu/view", &.{ "cmd/view", "context" })) return;
    menus_mod.begin(self, kit, "menu/view", under(self, kit, "cmd/view", "ribbon/tab/view"));
    defer menus_mod.end(kit);
    const t = self.tab();
    const ten = self.ten();
    for (menus_mod.view_names, 0..) |name, i| {
        const view: Tab.View = @enumFromInt(i);
        if (menus_mod.row(self, kit, kit.print("menu/view/{t}", .{view}), name, .{ .marked = t.view == view, .icon = if (ten) null else menus_mod.view_glyphs[i], .shortcut = kit.print("Ctrl+Shift+{d}", .{i + 1}) })) {
            self.setView(view);
            return close(self);
        }
    }
    menus_mod.separator(self, kit);
    if (!ten) {
        if (menus_mod.row(self, kit, "menu/view/compact", "Compact view", .{ .marked = self.compact, .ticked = true, .icon = .list })) {
            self.compact = !self.compact;
            return close(self);
        }
        menus_mod.separator(self, kit);
        // Windows 11 keeps the panes and the rest under Show.
        menus_mod.subRowMarked(self, kit, "menu/view/show", "Show", .eye, .show, false, false);
        return;
    }
    menus_mod.showMenu(self, kit);
}

fn close(self: *Files) void {
    self.menu = .none;
    self.context_sub = .none;
    self.window.redraw();
}

fn sortMenu(self: *Files, kit: *Kit) void {
    if (closeOnPressOutside(self, kit, "menu/sort", &.{ "cmd/sort", "ribbon/sort", "context" })) return;
    menus_mod.begin(self, kit, "menu/sort", under(self, kit, "cmd/sort", "ribbon/sort"));
    defer menus_mod.end(kit);
    const t = self.tab();
    const items = [_]struct { by: Folder.Column, name: []const u8 }{
        .{ .by = .name, .name = "Name" },
        .{ .by = .modified, .name = "Date modified" },
        .{ .by = .type, .name = "Type" },
        .{ .by = .size, .name = "Size" },
    };
    for (items) |item| {
        if (menus_mod.row(self, kit, kit.print("menu/sort/{t}", .{item.by}), item.name, .{ .marked = t.sort_by == item.by })) {
            if (t.sort_by != item.by) self.sortBy(item.by);
            return close(self);
        }
    }
    menus_mod.separator(self, kit);
    if (menus_mod.row(self, kit, "menu/sort/ascending", "Ascending", .{ .marked = t.ascending })) {
        self.sortOrder(true);
        return close(self);
    }
    if (menus_mod.row(self, kit, "menu/sort/descending", "Descending", .{ .marked = !t.ascending })) {
        self.sortOrder(false);
        return close(self);
    }
    // Windows 11's Sort ends in Group by; Windows 10's ribbon has its own.
    if (!self.ten()) {
        menus_mod.separator(self, kit);
        menus_mod.subRowMarked(self, kit, "menu/sort/group", "Group by", .apps_list, .group, false, false);
    }
}

fn groupMenu(self: *Files, kit: *Kit) void {
    if (closeOnPressOutside(self, kit, "menu/group", &.{ "cmd/sort", "ribbon/group", "context" })) return;
    menus_mod.begin(self, kit, "menu/group", under(self, kit, "cmd/sort", "ribbon/group"));
    defer menus_mod.end(kit);
    const t = self.tab();
    const items = [_]struct { by: ?Folder.Column, name: []const u8 }{
        .{ .by = .name, .name = "Name" },
        .{ .by = .modified, .name = "Date modified" },
        .{ .by = .type, .name = "Type" },
        .{ .by = .size, .name = "Size" },
        .{ .by = null, .name = "(None)" },
    };
    for (items, 0..) |item, k| {
        const on = if (item.by) |b| t.group_by == b else t.group_by == null;
        if (k == items.len - 1) menus_mod.separator(self, kit);
        if (menus_mod.row(self, kit, kit.print("menu/group/{d}", .{k}), item.name, .{ .marked = on })) {
            self.groupBy(item.by);
            return close(self);
        }
    }
}

fn moreMenu(self: *Files, kit: *Kit) void {
    if (closeOnPressOutside(self, kit, "menu/more", &.{"cmd/more"})) return;
    menus_mod.begin(self, kit, "menu/more", under(self, kit, "cmd/more", "cmd/more"));
    defer menus_mod.end(kit);
    const t = self.tab();
    const in_folder = t.path() != null;
    const pinned = if (t.path()) |p| self.places.isPinned(p) else false;
    if (menus_mod.row(self, kit, "menu/more/pin", if (pinned) "Unpin from Quick access" else "Pin to Quick access", .{ .icon = .pin, .disabled = !in_folder })) {
        close(self);
        return actions.pinChosen(self);
    }
    menus_mod.separator(self, kit);
    if (menus_mod.row(self, kit, "menu/more/all", "Select all", .{ .icon = .checkmark_circle, .shortcut = "Ctrl+A", .disabled = t.count() == 0 })) {
        t.selectAll();
        return close(self);
    }
    if (menus_mod.row(self, kit, "menu/more/none", "Select none", .{ .icon = .dismiss, .disabled = t.selectedCount() == 0 })) {
        t.selectNone();
        return close(self);
    }
    if (menus_mod.row(self, kit, "menu/more/invert", "Invert selection", .{ .icon = .arrow_sync, .disabled = t.count() == 0 })) {
        t.invertSelection();
        return close(self);
    }
    menus_mod.separator(self, kit);
    if (menus_mod.row(self, kit, "menu/more/properties", "Properties", .{ .icon = .info, .shortcut = "Alt+Enter", .disabled = !in_folder and t.selectedCount() == 0 })) {
        close(self);
        return self.openProperties();
    }
    if (menus_mod.row(self, kit, "menu/more/terminal", "Open in Terminal", .{ .icon = .window_console, .disabled = !in_folder })) {
        close(self);
        return actions.terminalHere(self);
    }
    menus_mod.separator(self, kit);
    if (menus_mod.row(self, kit, "menu/more/window", "Open new window", .{ .icon = .window, .shortcut = "Ctrl+N" })) {
        close(self);
        return self.openNewWindow();
    }
}

fn newMenu(self: *Files, kit: *Kit) void {
    if (closeOnPressOutside(self, kit, "menu/new", &.{ "cmd/new", "ribbon/new-item", "context" })) return;
    menus_mod.begin(self, kit, "menu/new", under(self, kit, "cmd/new", "ribbon/new-item"));
    defer menus_mod.end(kit);
    if (menus_mod.row(self, kit, "menu/new/folder", "Folder", .{ .themed = "folder", .shortcut = "Ctrl+Shift+N" })) {
        close(self);
        return actions.newFolder(self);
    }
    if (menus_mod.row(self, kit, "menu/new/shortcut", "Shortcut", .{ .icon = .arrow_reply, .disabled = !actions.canPaste(self) })) {
        close(self);
        return actions.pasteShortcut(self);
    }
    menus_mod.separator(self, kit);
    if (menus_mod.row(self, kit, "menu/new/text", "Text Document", .{ .themed = "text-x-generic" })) {
        close(self);
        return actions.newTextFile(self);
    }
}

/// Windows 10's Move to and Copy to: the person's folders, at once, as
/// large as Windows shows them.
fn placesMenu(self: *Files, kit: *Kit) void {
    const moving = self.menu == .move_to;
    const button = if (moving) "ribbon/move-to" else "ribbon/copy-to";
    if (closeOnPressOutside(self, kit, "menu/places", &.{button})) return;
    menus_mod.begin(self, kit, "menu/places", .{ .attach = .id, .to = button, .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 }, .z_index = 50 });
    defer menus_mod.end(kit);
    for (self.places.user.items, 0..) |f, i| {
        if (menus_mod.row(self, kit, kit.print("menu/places/{d}", .{i}), f.name, .{ .themed = @import("icons.zig").special(f.special) })) {
            close(self);
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const to = std.fmt.bufPrint(&buffer, "{s}", .{f.path}) catch return;
            return actions.sendTo(self, to, moving);
        }
    }
    for (self.places.pinned.items, 0..) |f, i| {
        if (menus_mod.row(self, kit, kit.print("menu/places/pin/{d}", .{i}), f.name, .{ .themed = "folder" })) {
            close(self);
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const to = std.fmt.bufPrint(&buffer, "{s}", .{f.path}) catch return;
            return actions.sendTo(self, to, moving);
        }
    }
}

/// Windows 10's recent locations: back and forward in one list.
fn recentMenu(self: *Files, kit: *Kit) void {
    if (closeOnPressOutside(self, kit, "menu/recent", &.{"nav/recent"})) return;
    menus_mod.begin(self, kit, "menu/recent", .{ .attach = .id, .to = "nav/recent", .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 }, .z_index = 50 });
    defer menus_mod.end(kit);
    const t = self.tab();
    var buffer: [256]u8 = undefined;
    // Forward ones above, the one here ticked, back ones below - newest
    // nearest.
    var steps: isize = @intCast(t.forward_stack.items.len);
    for (t.forward_stack.items) |l| {
        if (menus_mod.row(self, kit, kit.print("menu/recent/f{d}", .{steps}), self.locationName(l, &buffer), .{ .marked = false })) {
            close(self);
            for (0..@intCast(steps)) |_| t.goForward();
            self.arrivedPublic();
            return;
        }
        steps -= 1;
    }
    _ = menus_mod.row(self, kit, "menu/recent/here", self.locationName(t.location, &buffer), .{ .marked = true, .ticked = true, .strong = true });
    var back: usize = 1;
    var k = t.back_stack.items.len;
    while (k > 0) : (back += 1) {
        k -= 1;
        if (menus_mod.row(self, kit, kit.print("menu/recent/b{d}", .{back}), self.locationName(t.back_stack.items[k], &buffer), .{ .marked = false })) {
            close(self);
            for (0..back) |_| t.goBack();
            self.arrivedPublic();
            return;
        }
    }
}
