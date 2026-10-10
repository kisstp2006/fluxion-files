// SPDX-License-Identifier: BSD-2-Clause

//! Folder Options - Windows 10's View ▸ Options, Windows 11's "···" ▸
//! Options - the property sheet File Explorer has kept since Windows XP,
//! and every setting on it doing what it says:
//!
//! - **General**: open to Home or This PC; each folder in the same window
//!   or its own; single-click or double-click, the names underlined always
//!   or under the pointer; Home's recent files, frequent folders and
//!   favorites, and Clear for the history behind them;
//! - **View**: Apply to Folders and Reset Folders, for the view of the
//!   folder shown; and the advanced settings - thumbnails or icons, the
//!   pop-up descriptions and the sizes in them, the full path in the title
//!   bar, hidden items, empty drives, extensions, preview handlers, the
//!   status bar, check boxes, and how the navigation pane follows;
//! - **Search**: system folders, compressed folders, what is in the files.
//!
//! Changed on a copy; OK and Apply take it, and it is kept in files.ini.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;

const Files = @import("Files.zig");
const Prefs = @import("Prefs.zig");
const Places = @import("Places.zig");
const icons = @import("icons.zig");

pub const Page = enum { general, view, search };

pub const Options = struct {
    page: Page = .general,
    /// What the boxes say, not yet taken.
    edit: Prefs,
};

pub fn open(self: *Files) void {
    self.menu = .none;
    self.context_open = null;
    var edit = self.prefs;
    // What the window shows now, which the boxes start from.
    edit.hidden = self.show_hidden;
    edit.extensions = self.show_extensions;
    edit.check_boxes = self.check_boxes;
    self.options = .{ .edit = edit };
    self.window.redraw();
}

/// What the boxes say, taken: kept, and shown at once.
fn apply(self: *Files) void {
    const o = &(self.options orelse return);
    const e = o.edit;
    const hidden_changed = e.hidden != self.show_hidden;
    self.prefs = e;
    self.show_extensions = e.extensions;
    self.check_boxes = e.check_boxes;
    if (hidden_changed) self.toggleHidden();
    // Home lists what it is told to - and forgets nothing it was not.
    self.savePrefs();
    var buffer: [256]u8 = undefined;
    self.window.setTitle(self.windowTitleOf(self.tab(), &buffer));
    self.window.redraw();
}

fn colours(kit: *Kit) struct { dialog: Color, page: Color, edge: Color } {
    const dark = kit.theme.palette.mode == .dark;
    return .{
        .dialog = if (dark) widgets.argb(0xFF2B2B2B) else widgets.argb(0xFFF0F0F0),
        .page = if (dark) widgets.argb(0xFF202020) else widgets.argb(0xFFFFFFFF),
        .edge = if (dark) widgets.argb(0xFF4A4A4A) else widgets.argb(0xFFD9D9D9),
    };
}

pub fn draw(self: *Files, kit: *Kit) void {
    const o = &(self.options orelse return);
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const c = colours(kit);
    u.open(.{ .id = "options/smoke", .width = .grow, .height = .grow, .align_x = .center, .align_y = .center, .background_color = p.smoke.withAlpha(0.15), .floating = .{ .attach = .root, .z_index = 95 } });
    defer u.close();
    u.open(.{
        .id = "options",
        .width = .fixed(440),
        .direction = .top_to_bottom,
        .corner_radius = .all(if (ten) 0 else 8),
        .background_color = c.dialog,
        .border = .{ .color = if (ten) widgets.argb(0xFF1979CA) else p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .clip = .both,
    });
    defer u.close();
    {
        u.open(.{ .width = .grow, .height = .fixed(32), .padding = .trbl(0, 0, 0, 12), .gap = 8, .align_y = .center, .background_color = c.page });
        defer u.close();
        icons.themed(self, kit, "folder", 16);
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .none;
        u.open(.{ .width = .grow });
        u.text("Folder Options", style);
        u.close();
        const close_id = "options/close";
        u.open(.{ .id = close_id, .width = .fixed(46), .height = .grow, .align_x = .center, .align_y = .center, .background_color = if (u.isPointerOver(close_id)) p.close_hover else .transparent });
        kit.icon(.dismiss, 10, if (u.isPointerOver(close_id)) widgets.argb(0xFFFFFFFF) else p.text_primary, .regular);
        if (u.justReleased()) self.options = null;
        u.close();
    }
    if (self.options == null) return;
    // The page tabs, as a property sheet's.
    {
        u.open(.{ .width = .grow, .padding = .trbl(8, 8, 0, 8) });
        defer u.close();
        for ([_]Page{ .general, .view, .search }) |page| {
            const id = kit.print("options/tab/{t}", .{page});
            const front = o.page == page;
            u.open(.{
                .id = id,
                .padding = .xy(10, 4),
                .background_color = if (front) c.page else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
                .border = .{ .color = c.edge, .width = if (front) .{ .left = 1, .right = 1, .top = 1 } else .{ .bottom = 1 } },
            });
            kit.label(switch (page) {
                .general => "General",
                .view => "View",
                .search => "Search",
            }, .caption, p.text_primary);
            if (u.justReleased()) o.page = page;
            u.close();
        }
        u.empty(.{ .width = .grow, .height = .grow, .border = .{ .color = c.edge, .width = .{ .bottom = 1 } } });
    }
    {
        u.open(.{ .width = .grow, .padding = .trbl(0, 8, 0, 8) });
        defer u.close();
        u.open(.{ .width = .grow, .height = .fixed(440), .direction = .top_to_bottom, .padding = .all(12), .gap = 10, .background_color = c.page, .border = .{ .color = c.edge, .width = .{ .left = 1, .right = 1, .bottom = 1 } } });
        defer u.close();
        switch (o.page) {
            .general => general(self, kit, &o.edit),
            .view => view(self, kit, &o.edit),
            .search => search(kit, &o.edit),
        }
    }
    u.open(.{ .width = .grow, .padding = .all(10), .gap = 8, .align_x = .right });
    defer u.close();
    if (kit.button("options/ok", "OK", .{ .width = .fixed(80) })) {
        apply(self);
        self.options = null;
        return;
    }
    if (kit.button("options/cancel", "Cancel", .{ .width = .fixed(80) })) {
        self.options = null;
        return;
    }
    if (kit.button("options/apply", "Apply", .{ .width = .fixed(80), .disabled = std.meta.eql(o.edit, self.prefs) })) apply(self);
}

/// A group of the page: its name, and what it holds beside a picture.
fn groupBegin(kit: *Kit, name: []const u8, glyph: widgets.icons.Name) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 4 });
    kit.label(name, .caption, p.text_primary);
    u.open(.{ .width = .grow, .gap = 10, .padding = .trbl(0, 0, 0, 6) });
    u.open(.{ .width = .fixed(32), .padding = .trbl(2, 0, 0, 0) });
    kit.icon(glyph, 28, if (kit.theme.look.style == .win10) widgets.argb(0xFFE8B428) else p.accent, .regular);
    u.close();
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 0 });
}

fn groupEnd(kit: *Kit) void {
    kit.ui.close();
    kit.ui.close();
    kit.ui.close();
}

fn radio(kit: *Kit, id: []const u8, on: bool, text: []const u8) bool {
    return classicRadio(kit, id, on, text, .{});
}

const Small = struct { disabled: bool = false };

/// A check box as the property sheet's are: thirteen pixels, square, its
/// words small beside it. Flips `on`; true when clicked.
fn classicCheck(kit: *Kit, id: []const u8, on: *bool, text: []const u8, o: Small) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = !o.disabled and u.isPointerOver(id);
    u.open(.{ .id = id, .height = .fixed(20), .gap = 6, .align_y = .center });
    defer u.close();
    const ink = if (o.disabled) p.text_disabled else p.text_primary;
    u.open(.{
        .width = .fixed(13),
        .height = .fixed(13),
        .align_x = .center,
        .align_y = .center,
        .background_color = if (on.*) (if (o.disabled) p.text_disabled else p.accent) else p.solid_base,
        .corner_radius = .all(if (kit.theme.look.style == .win10) 0 else 2),
        .border = if (on.*) .{} else .{ .color = if (hovered) p.accent else if (o.disabled) p.text_disabled else p.text_secondary, .width = .all(1) },
    });
    if (on.*) kit.icon(.checkmark, 10, p.text_on_accent, .regular);
    u.close();
    var style = kit.style(.caption, ink);
    style.wrap = .none;
    u.text(text, style);
    if (o.disabled or !u.justReleased()) return false;
    on.* = !on.*;
    return true;
}

/// A round one: chosen, a dot in it. True when clicked.
fn classicRadio(kit: *Kit, id: []const u8, on: bool, text: []const u8, o: Small) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = !o.disabled and u.isPointerOver(id);
    u.open(.{ .id = id, .height = .fixed(20), .gap = 6, .align_y = .center });
    defer u.close();
    const ink = if (o.disabled) p.text_disabled else p.text_primary;
    u.open(.{
        .width = .fixed(13),
        .height = .fixed(13),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(7),
        .background_color = p.solid_base,
        .border = .{ .color = if (on and !o.disabled) p.accent else if (hovered) p.accent else if (o.disabled) p.text_disabled else p.text_secondary, .width = .all(1) },
    });
    if (on) u.empty(.{ .width = .fixed(7), .height = .fixed(7), .corner_radius = .all(4), .background_color = if (o.disabled) p.text_disabled else p.accent });
    u.close();
    var style = kit.style(.caption, ink);
    style.wrap = .none;
    u.text(text, style);
    return !o.disabled and u.justReleased();
}

fn general(self: *Files, kit: *Kit, e: *Prefs) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    {
        u.open(.{ .width = .grow, .gap = 8, .align_y = .center });
        defer u.close();
        kit.label("Open File Explorer to:", .caption, p.text_primary);
        const names = [_][]const u8{ if (ten) "Quick access" else "Home", "This PC" };
        var state: widgets.Kit.Dropdown = .{ .selected = @intFromEnum(e.open_to), .open = self.options_dropdown };
        if (kit.dropdown("options/open-to", &state, &names, .fixed(170))) e.open_to = @enumFromInt(state.selected);
        self.options_dropdown = state.open;
    }
    groupBegin(kit, "Browse folders", .folder_open);
    if (radio(kit, "options/same-window", !e.own_window, "Open each folder in the same window")) e.own_window = false;
    if (radio(kit, "options/own-window", e.own_window, "Open each folder in its own window")) e.own_window = true;
    groupEnd(kit);
    groupBegin(kit, "Click items as follows", .open);
    if (radio(kit, "options/single", e.single_click, "Single-click to open an item (point to select)")) e.single_click = true;
    {
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 0, .padding = .trbl(0, 0, 0, 20) });
        defer u.close();
        if (classicRadio(kit, "options/underline-always", e.underline == .always, "Underline icon titles consistent with my browser", .{ .disabled = !e.single_click })) e.underline = .always;
        if (classicRadio(kit, "options/underline-hover", e.underline == .hover, "Underline icon titles only when I point at them", .{ .disabled = !e.single_click })) e.underline = .hover;
    }
    if (radio(kit, "options/double", !e.single_click, "Double-click to open an item (single-click to select)")) e.single_click = false;
    groupEnd(kit);
    groupBegin(kit, "Privacy", .lock_closed);
    _ = classicCheck(kit, "options/recent", &e.show_recent, "Show recently used files", .{});
    _ = classicCheck(kit, "options/frequent", &e.show_frequent, "Show frequently used folders", .{});
    if (!ten) _ = classicCheck(kit, "options/favorites", &e.show_favorites, "Show favorites", .{});
    {
        u.open(.{ .width = .grow, .gap = 8, .align_y = .center });
        defer u.close();
        kit.label("Clear File Explorer history", .caption, p.text_primary);
        u.empty(.{ .width = .grow });
        if (kit.button("options/clear", "Clear", .{ .width = .fixed(80) })) self.history.clear(self.io);
    }
    groupEnd(kit);
    u.empty(.{ .height = .grow });
    restoreDefaults(kit, e, .general);
}

fn view(self: *Files, kit: *Kit, e: *Prefs) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const c = colours(kit);
    groupBegin(kit, "Folder views", .grid);
    {
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .words;
        u.text("You can apply this view (such as Details or Icons) to all folders of this type.", style);
        u.open(.{ .gap = 8 });
        defer u.close();
        if (kit.button("options/apply-folders", "Apply to Folders", .{ .disabled = self.tab().path() == null })) self.folder_views.applyToAll(self.io, &self.places, self.tab());
        if (kit.button("options/reset-folders", "Reset Folders", .{})) self.folder_views.reset(self.io);
    }
    groupEnd(kit);
    kit.label("Advanced settings:", .caption, p.text_primary);
    {
        u.open(.{
            .id = "options/advanced",
            .width = .grow,
            .height = .grow,
            .direction = .top_to_bottom,
            .padding = .all(4),
            .gap = 2,
            .background_color = c.page,
            .border = .{ .color = c.edge, .width = .all(1) },
            .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
        });
        defer u.close();
        branch(self, kit, "Files and Folders", "folder");
        leaf(kit, "options/v/icons", &e.always_icons, "Always show icons, never thumbnails", 1);
        leaf(kit, "options/v/size-tips", &e.folder_size_tips, "Display file size information in folder tips", 1);
        leaf(kit, "options/v/full-path", &e.full_path_title, "Display the full path in the title bar", 1);
        branch(self, kit, "Hidden files and folders", "folder");
        {
            u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2, .padding = .trbl(0, 0, 0, 40) });
            defer u.close();
            if (classicRadio(kit, "options/v/hide-hidden", !e.hidden, "Don't show hidden files, folders, or drives", .{})) e.hidden = false;
            if (classicRadio(kit, "options/v/show-hidden", e.hidden, "Show hidden files, folders, and drives", .{})) e.hidden = true;
        }
        leaf(kit, "options/v/empty-drives", &e.hide_empty_drives, "Hide empty drives", 1);
        var hide_extensions = !e.extensions;
        leaf(kit, "options/v/extensions", &hide_extensions, "Hide extensions for known file types", 1);
        e.extensions = !hide_extensions;
        leaf(kit, "options/v/infotips", &e.infotips, "Show pop-up description for folder and desktop items", 1);
        leaf(kit, "options/v/handlers", &e.preview_handlers, "Show preview handlers in preview pane", 1);
        leaf(kit, "options/v/status", &e.status_bar, "Show status bar", 1);
        leaf(kit, "options/v/check", &e.check_boxes, "Use check boxes to select items", 1);
        branch(self, kit, "Navigation pane", "folder");
        leaf(kit, "options/v/expand", &e.expand_to_open, "Expand to open folder", 1);
        leaf(kit, "options/v/all", &e.show_all_folders, "Show all folders", 1);
    }
    restoreDefaults(kit, e, .view);
}

/// A heading of the advanced settings' tree, with its folder.
fn branch(self: *Files, kit: *Kit, text: []const u8, icon: []const u8) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .gap = 6, .align_y = .center, .padding = .trbl(2, 0, 2, 0) });
    defer u.close();
    icons.themed(self, kit, icon, 16);
    kit.label(text, .caption, kit.theme.palette.text_primary);
}

fn leaf(kit: *Kit, id: []const u8, on: *bool, text: []const u8, depth: u8) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .padding = .trbl(0, 0, 0, @as(u16, depth) * 20) });
    defer u.close();
    _ = classicCheck(kit, id, on, text, .{});
}

fn search(kit: *Kit, e: *Prefs) void {
    const u = kit.ui;
    groupBegin(kit, "When searching non-indexed locations", .search);
    _ = classicCheck(kit, "options/s/system", &e.search_system, "Include system directories", .{});
    _ = classicCheck(kit, "options/s/archives", &e.search_archives, "Include compressed files (ZIP, CAB...)", .{});
    _ = classicCheck(kit, "options/s/contents", &e.search_contents, "Always search file names and contents (this might take several minutes)", .{});
    groupEnd(kit);
    u.empty(.{ .height = .grow });
    restoreDefaults(kit, e, .search);
}

/// "Restore Defaults": the page's settings as they come.
fn restoreDefaults(kit: *Kit, e: *Prefs, page: Page) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .align_x = .right });
    defer u.close();
    if (!kit.button(kit.print("options/defaults/{t}", .{page}), "Restore Defaults", .{})) return;
    const d: Prefs = .{};
    switch (page) {
        .general => {
            e.open_to = d.open_to;
            e.own_window = d.own_window;
            e.single_click = d.single_click;
            e.underline = d.underline;
            e.show_recent = d.show_recent;
            e.show_frequent = d.show_frequent;
            e.show_favorites = d.show_favorites;
        },
        .view => {
            inline for (.{ "always_icons", "infotips", "folder_size_tips", "full_path_title", "hidden", "extensions", "hide_empty_drives", "preview_handlers", "status_bar", "check_boxes", "expand_to_open", "show_all_folders" }) |f| @field(e, f) = @field(d, f);
        },
        .search => {
            e.search_archives = d.search_archives;
            e.search_contents = d.search_contents;
            e.search_system = d.search_system;
        },
    }
}
