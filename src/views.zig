// SPDX-License-Identifier: BSD-2-Clause

//! What a tab shows: Home (Windows 10's Quick access), This PC, or a folder
//! in one of Windows' eight views - Extra large, Large, Medium and Small
//! icons, List, Details, Tiles, Content.
//!
//! **Only what is in sight is laid out**: a folder of a hundred thousand
//! files costs what forty do. The rows above and below are a spacer each,
//! as tall as they would be.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const Places = @import("Places.zig");
const Window = @import("Window.zig");
const chrome = @import("chrome.zig");
const nav = @import("nav.zig");
const icons = @import("icons.zig");
const menus = @import("menus.zig");
const actions = @import("actions.zig");

const scroll_id = "view/scroll";

/// Items on a row of the view drawn last: one but for the icon views.
pub fn columns(self: *Files) usize {
    return self.grid_columns;
}

pub fn content(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const t = self.tab();
    u.open(.{
        .id = "view",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = chrome.contentColor(kit),
    });
    defer u.close();
    switch (t.location) {
        .home => homePage(self, kit),
        .this_pc => thisPcPage(self, kit),
        .folder => folderView(self, kit),
    }
}

fn scrollbar(kit: *Kit) ui.layout.Scrollbar {
    return .{ .width = 6, .corner_radius = 3, .thumb_color = kit.theme.palette.text_tertiary, .hide_after_seconds = 1.5 };
}

fn scrollClip(kit: *Kit) ui.layout.Clip {
    return .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true, .scrollbar = scrollbar(kit) };
}

/// The colour an item is drawn on: chosen, under the pointer, or neither.
fn itemFill(self: *Files, kit: *Kit, selected: bool, hovered: bool) Color {
    const p = &kit.theme.palette;
    if (self.ten()) {
        if (selected) return nav.win10Selection(kit);
        if (hovered) return nav.win10Hover(kit);
        return .transparent;
    }
    if (selected) return p.accent.withAlpha(if (p.mode == .dark) 0.32 else 0.18);
    if (hovered) return p.subtle_secondary;
    return .transparent;
}

/// A name as shown: without its extension when they are hidden.
fn shownName(self: *Files, e: *const Folder.Entry) []const u8 {
    if (self.show_extensions or e.isFolder()) return e.name;
    const dot = std.mem.lastIndexOfScalar(u8, e.name, '.') orelse return e.name;
    return if (dot == 0) e.name else e.name[0..dot];
}

/// A right click on item `i`: chosen, if it was not, and its menu; a
/// middle click on a folder: it in a new tab.
fn requests(self: *Files, u: *ui.Ui, id: []const u8, i: usize) void {
    const t = self.tab();
    if (self.context_at) |at| if (u.isPointerOver(id)) {
        if (!t.selected.items[i]) t.click(i, false, false);
        menus.openAt(self, at, true);
        self.context_at = null;
    };
    if (self.middle_click and u.isPointerOver(id)) {
        self.middle_click = false;
        if (t.entry(i).isFolder()) self.open(i, true);
    }
}

/// An item's name - or, being renamed, the field its new name is typed in,
/// the name in it with all but its extension chosen, as Windows has it.
fn nameOrField(self: *Files, kit: *Kit, i: usize, e: *const Folder.Entry, style: ui.TextStyle) void {
    const u = kit.ui;
    if (self.renaming != i) {
        u.text(shownName(self, e), style);
        return;
    }
    kit.textField("rename/field", .{ .width = .grow });
    switch (self.rename_draws) {
        0 => u.setFocus("rename/field"),
        1 => {
            u.setTextValue("rename/field", e.name);
            _ = u.textAction(.moveTo(.start, false));
            const dot = if (e.isFolder()) e.name.len else std.mem.lastIndexOfScalar(u8, e.name, '.') orelse e.name.len;
            const stem = if (dot == 0) e.name.len else dot;
            const chars = std.unicode.utf8CountCodepoints(e.name[0..stem]) catch stem;
            for (0..chars) |_| _ = u.textAction(.moveTo(.right, true));
        },
        else => {},
    }
    if (self.rename_draws < 3) {
        self.rename_draws += 1;
        self.window.redraw();
    } else if (!u.isFocused("rename/field")) {
        // Clicked away: the name typed is given, as Windows gives it.
        actions.commitRename(self);
    }
}

/// A click, a Ctrl or Shift click, a double click, on item `i`.
fn pressed(self: *Files, i: usize) void {
    const t = self.tab();
    const w = &self.window;
    const ctrl = w.modifierHeld("Control");
    const shift = w.modifierHeld("Shift");
    if (w.clickCount() >= 2 and !ctrl and !shift) {
        self.open(i, false);
        return;
    }
    t.click(i, ctrl, shift);
}

// -------------------------------------------------------------------------
// A folder
// -------------------------------------------------------------------------

fn folderView(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    noticeBar(self, kit);
    if (t.view == .details) detailsHeader(self, kit);
    defer if (self.context_at) |at| if (u.isPointerOver(scroll_id)) {
        // On nothing: the folder's own menu, and nothing chosen.
        t.selectNone();
        menus.openAt(self, at, false);
        self.context_at = null;
    };
    u.open(.{
        .id = scroll_id,
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .trbl(if (t.view == .details) 0 else 8, if (self.ten()) 0 else 8, 8, if (self.ten()) 0 else 8),
        .clip = scrollClip(kit),
    });
    defer u.close();
    // A press on nothing chooses nothing.
    if (u.justPressed() and !self.window.modifierHeld("Control") and !overAnItem(self, u)) t.selectNone();
    if (t.count() == 0) {
        u.open(.{ .width = .grow, .padding = .all(24), .align_x = .center });
        kit.label(if (t.folder != null and t.folder.?.failure != null) "This folder could not be read." else "This folder is empty.", .body, p.text_secondary);
        u.close();
        return;
    }
    switch (t.view) {
        .details => rows(self, kit, if (self.ten()) 22 else 32, detailsRow),
        .content => rows(self, kit, 64, contentRow),
        .extra_large => grid(self, kit, .{ 232, 264 }, 192),
        .large => grid(self, kit, .{ 120, 140 }, 96),
        .medium => grid(self, kit, .{ 96, 96 }, 48),
        .small, .list => grid(self, kit, .{ 240, if (self.ten()) 22 else 28 }, 16),
        .tiles => grid(self, kit, .{ 280, 68 }, 48),
    }
}

/// Whether the pointer is on an item - by the last drawing.
fn overAnItem(self: *Files, u: *ui.Ui) bool {
    const t = self.tab();
    var buffer: [32]u8 = undefined;
    for (0..t.count()) |i| {
        const id = std.fmt.bufPrint(&buffer, "item/{d}", .{i}) catch continue;
        if (u.isPointerOver(id)) return true;
    }
    return false;
}

/// Where in the scrolled list the view is, in the window's pixels: the
/// first pixel shown and how many are.
fn scrolled(self: *Files, u: *ui.Ui) struct { top: f32, height: f32, width: f32 } {
    const s = self.window.scale;
    const scroll = u.scrollOf(scroll_id) orelse return .{ .top = 0, .height = @floatFromInt(self.window.height), .width = @floatFromInt(self.window.width) };
    return .{
        .top = scroll.position.y / s,
        .height = if (scroll.viewport.height > 0) scroll.viewport.height / s else @floatFromInt(self.window.height),
        .width = if (scroll.viewport.width > 0) scroll.viewport.width / s else @floatFromInt(self.window.width),
    };
}

/// Scrolled so the item the keyboard moved to is in sight.
fn reveal(self: *Files, u: *ui.Ui, top_of: f32, height: f32, view: anytype) void {
    const t = self.tab();
    if (!t.reveal) return;
    t.reveal = false;
    const s = self.window.scale;
    if (top_of < view.top) {
        u.scrollTo(scroll_id, 0, top_of * s);
    } else if (top_of + height > view.top + view.height) {
        u.scrollTo(scroll_id, 0, (top_of + height - view.height) * s);
    }
    self.window.redraw();
}

/// One item a row, `row_h` high, only those in sight drawn.
fn rows(self: *Files, kit: *Kit, row_h: f32, comptime drawRow: fn (*Files, *Kit, usize, f32) void) void {
    const u = kit.ui;
    const t = self.tab();
    self.grid_columns = 1;
    const view = scrolled(self, u);
    const n = t.count();
    const first: usize = @min(n, @as(usize, @intFromFloat(@max(0, @floor(view.top / row_h)))) -| 2);
    const last: usize = @min(n, first + @as(usize, @intFromFloat(@ceil(view.height / row_h))) + 6);
    if (t.focus) |f| reveal(self, u, @as(f32, @floatFromInt(f)) * row_h, row_h, view);
    if (first > 0) u.empty(.{ .width = .grow, .height = .fixed(@as(f32, @floatFromInt(first)) * row_h) });
    for (first..last) |i| drawRow(self, kit, i, row_h);
    if (last < n) u.empty(.{ .width = .grow, .height = .fixed(@as(f32, @floatFromInt(n - last)) * row_h) });
}

// -- Details --

const date_w = 170;
const type_w = 170;
const size_w = 100;

fn detailsHeader(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const ten = self.ten();
    u.open(.{
        .id = "details/header",
        .width = .grow,
        .height = .fixed(if (ten) 24 else 32),
        .padding = .trbl(0, if (ten) 0 else 16, 0, if (ten) 0 else 16),
        .align_y = .center,
        .border = if (ten) .{ .color = p.divider, .width = .{ .bottom = 1 } } else .{},
    });
    defer u.close();
    const cols = [_]struct { by: Folder.Column, name: []const u8, width: ?f32 }{
        .{ .by = .name, .name = "Name", .width = null },
        .{ .by = .modified, .name = "Date modified", .width = date_w },
        .{ .by = .type, .name = "Type", .width = type_w },
        .{ .by = .size, .name = "Size", .width = size_w },
    };
    for (cols) |c| {
        const id = kit.print("details/column/{t}", .{c.by});
        const hovered = u.isPointerOver(id);
        u.open(.{
            .id = id,
            .width = if (c.width) |w| .fixed(w) else .grow,
            .height = .grow,
            .padding = .xy(if (ten) 6 else 8, 0),
            .gap = 4,
            .align_y = .center,
            .background_color = if (hovered) (if (ten) nav.win10Hover(kit) else p.subtle_secondary) else .transparent,
            .border = if (ten) .{ .color = p.divider, .width = .{ .right = 1 } } else .{},
        });
        var style = kit.style(if (ten) .body else .caption, if (ten) p.text_secondary else p.text_secondary);
        style.wrap = .none;
        u.text(c.name, style);
        if (t.sort_by == c.by) kit.icon(if (t.ascending) .chevron_up else .chevron_down, 10, p.text_secondary, .regular);
        if (u.justReleased()) t.sortBy(c.by, &self.mime, self.show_hidden);
        u.close();
    }
}

fn detailsRow(self: *Files, kit: *Kit, i: usize, row_h: f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const e = t.entry(i);
    const ten = self.ten();
    const id = kit.print("item/{d}", .{i});
    const selected = t.selected.items[i];
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(row_h),
        .padding = .xy(if (ten) 0 else 8, 0),
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = itemFill(self, kit, selected, hovered),
        .border = if (ten and selected) .{ .color = win10Edge(kit), .width = .all(1) } else if (t.focus == i and !selected) .{ .color = p.focus_outer.withAlpha(0.5), .width = .all(1) } else .{},
    });
    defer u.close();
    if (u.justPressed()) pressed(self, i);
    requests(self, u, id, i);
    const faded = e.hidden;
    const ink = if (faded) p.text_secondary else p.text_primary;
    {
        u.open(.{ .width = .grow, .height = .grow, .padding = .xy(if (ten) 6 else 8, 0), .gap = 8, .align_y = .center, .clip = .both });
        defer u.close();
        u.open(.{ .width = .fixed(16), .height = .fixed(16), .opacity = if (faded) 0.55 else 1 });
        icons.forEntry(self, kit, t.path().?, e, 16);
        u.close();
        var style = kit.style(.body, ink);
        style.wrap = .none;
        nameOrField(self, kit, i, e, style);
    }
    var secondary = kit.style(.body, p.text_secondary);
    secondary.wrap = .none;
    {
        u.open(.{ .width = .fixed(date_w), .padding = .xy(8, 0), .clip = .both });
        defer u.close();
        var date_buffer: [32]u8 = undefined;
        u.text(kit.print("{s}", .{dateText(e.mtime, &date_buffer)}), secondary);
    }
    {
        u.open(.{ .width = .fixed(type_w), .padding = .xy(8, 0), .clip = .both });
        defer u.close();
        var type_buffer: [64]u8 = undefined;
        u.text(kit.print("{s}", .{self.mime.describe(e.mime, e.name, &type_buffer)}), secondary);
    }
    {
        u.open(.{ .width = .fixed(size_w), .padding = .xy(8, 0), .align_x = .right, .clip = .both });
        defer u.close();
        if (!e.isFolder()) {
            var size_buffer: [32]u8 = undefined;
            u.text(kit.print("{s}", .{detailsSize(e.size, &size_buffer)}), secondary);
        }
    }
}

/// Windows 10's chosen row has an edge a shade deeper than its fill.
fn win10Edge(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF999999) else widgets.argb(0xFF99D1FF);
}

/// The Size column as Windows' Details has it: whole kilobytes, rounded up.
fn detailsSize(bytes: u64, buffer: []u8) []const u8 {
    const kb = (bytes + 1023) / 1024;
    // Thousands apart with a comma, as "2,048 KB".
    var digits: [24]u8 = undefined;
    const plain = std.fmt.bufPrint(&digits, "{d}", .{kb}) catch return "";
    var out: usize = 0;
    for (plain, 0..) |c, k| {
        if (k > 0 and (plain.len - k) % 3 == 0) {
            if (out >= buffer.len) return "";
            buffer[out] = ',';
            out += 1;
        }
        if (out >= buffer.len) return "";
        buffer[out] = c;
        out += 1;
    }
    const tail = " KB";
    if (out + tail.len > buffer.len) return "";
    @memcpy(buffer[out .. out + tail.len], tail);
    return buffer[0 .. out + tail.len];
}

/// libc's `struct tm`.
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

/// "10/09/2026 14:05", local time, from nanoseconds since the epoch.
pub fn dateText(ns: i128, buffer: []u8) []const u8 {
    if (ns <= 0) return "";
    const seconds: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));
    var tm: Tm = undefined;
    if (localtime_r(&seconds, &tm) == null) return "";
    return std.fmt.bufPrint(buffer, "{d:0>2}/{d:0>2}/{d} {d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.mon + 1)),
        @as(u32, @intCast(tm.mday)),
        @as(u32, @intCast(tm.year + 1900)),
        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),
    }) catch "";
}

// -- Content --

fn contentRow(self: *Files, kit: *Kit, i: usize, row_h: f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const e = t.entry(i);
    const id = kit.print("item/{d}", .{i});
    const selected = t.selected.items[i];
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(row_h),
        .padding = .xy(12, 0),
        .gap = 12,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, selected, u.isPointerOver(id)),
        .border = .{ .color = p.divider, .width = .{ .bottom = 1 } },
    });
    defer u.close();
    if (u.justPressed()) pressed(self, i);
    requests(self, u, id, i);
    icons.forEntry(self, kit, t.path().?, e, 32);
    {
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2, .clip = .both });
        defer u.close();
        var style = kit.style(.body, p.text_primary);
        style.wrap = .none;
        nameOrField(self, kit, i, e, style);
        var type_buffer: [64]u8 = undefined;
        var small = kit.style(.caption, p.text_secondary);
        small.wrap = .none;
        u.text(kit.print("{s}", .{self.mime.describe(e.mime, e.name, &type_buffer)}), small);
    }
    {
        u.open(.{ .width = .fixed(220), .direction = .top_to_bottom, .gap = 2, .align_x = .right });
        defer u.close();
        var small = kit.style(.caption, p.text_secondary);
        small.wrap = .none;
        var date_buffer: [32]u8 = undefined;
        u.text(kit.print("Date modified: {s}", .{dateText(e.mtime, &date_buffer)}), small);
        if (!e.isFolder()) {
            var size_buffer: [32]u8 = undefined;
            u.text(kit.print("Size: {s}", .{Folder.sizeText(e.size, &size_buffer)}), small);
        }
    }
}

// -- The icon views, and Tiles --

/// Items in cells `cell` big, as many to a row as fit, an icon `icon`
/// across in each - only the rows in sight drawn.
fn grid(self: *Files, kit: *Kit, cell: [2]f32, icon: u16) void {
    const u = kit.ui;
    const t = self.tab();
    const view = scrolled(self, u);
    const room = view.width - 16;
    const across: usize = @max(1, @as(usize, @intFromFloat(@floor(room / cell[0]))));
    self.grid_columns = across;
    const n = t.count();
    const total_rows = (n + across - 1) / across;
    const first_row: usize = @as(usize, @intFromFloat(@max(0, @floor(view.top / cell[1])))) -| 1;
    const last_row: usize = @min(total_rows, first_row + @as(usize, @intFromFloat(@ceil(view.height / cell[1]))) + 3);
    if (t.focus) |f| reveal(self, u, @as(f32, @floatFromInt(f / across)) * cell[1], cell[1], view);
    if (first_row > 0) u.empty(.{ .width = .grow, .height = .fixed(@as(f32, @floatFromInt(first_row)) * cell[1]) });
    for (first_row..last_row) |r| {
        u.open(.{ .width = .grow, .height = .fixed(cell[1]) });
        defer u.close();
        for (r * across..@min(n, (r + 1) * across)) |i| {
            if (t.view == .tiles) tileCell(self, kit, i, cell) else if (icon <= 16) smallCell(self, kit, i, cell) else iconCell(self, kit, i, cell, icon);
        }
    }
    if (last_row < total_rows) u.empty(.{ .width = .grow, .height = .fixed(@as(f32, @floatFromInt(total_rows - last_row)) * cell[1]) });
}

fn iconCell(self: *Files, kit: *Kit, i: usize, cell: [2]f32, icon: u16) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const e = t.entry(i);
    const id = kit.print("item/{d}", .{i});
    const selected = t.selected.items[i];
    u.open(.{
        .id = id,
        .width = .fixed(cell[0] - 4),
        .height = .fixed(cell[1] - 4),
        .direction = .top_to_bottom,
        .padding = .all(4),
        .gap = 4,
        .align_x = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, selected, u.isPointerOver(id)),
        .border = if (self.ten() and selected) .{ .color = win10Edge(kit), .width = .all(1) } else .{},
    });
    defer u.close();
    if (u.justPressed()) pressed(self, i);
    requests(self, u, id, i);
    u.open(.{ .width = .grow, .height = .fixed(@floatFromInt(icon)), .align_x = .center, .align_y = .bottom });
    icons.forEntry(self, kit, t.path().?, e, icon);
    u.close();
    var style = kit.style(.body, p.text_primary);
    style.alignment = .center;
    style.wrap = .words;
    u.open(.{ .width = .grow, .height = .grow, .clip = .both, .align_x = .center });
    nameOrField(self, kit, i, e, style);
    u.close();
}

fn smallCell(self: *Files, kit: *Kit, i: usize, cell: [2]f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const e = t.entry(i);
    const id = kit.print("item/{d}", .{i});
    const selected = t.selected.items[i];
    u.open(.{
        .id = id,
        .width = .fixed(cell[0] - 4),
        .height = .fixed(cell[1] - 2),
        .padding = .xy(6, 0),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, selected, u.isPointerOver(id)),
        .border = if (self.ten() and selected) .{ .color = win10Edge(kit), .width = .all(1) } else .{},
        .clip = .both,
    });
    defer u.close();
    if (u.justPressed()) pressed(self, i);
    requests(self, u, id, i);
    icons.forEntry(self, kit, t.path().?, e, 16);
    var style = kit.style(.body, p.text_primary);
    style.wrap = .none;
    nameOrField(self, kit, i, e, style);
}

fn tileCell(self: *Files, kit: *Kit, i: usize, cell: [2]f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const e = t.entry(i);
    const id = kit.print("item/{d}", .{i});
    const selected = t.selected.items[i];
    u.open(.{
        .id = id,
        .width = .fixed(cell[0] - 6),
        .height = .fixed(cell[1] - 6),
        .padding = .xy(8, 0),
        .gap = 10,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, selected, u.isPointerOver(id)),
        .border = if (self.ten() and selected) .{ .color = win10Edge(kit), .width = .all(1) } else .{},
        .clip = .both,
    });
    defer u.close();
    if (u.justPressed()) pressed(self, i);
    requests(self, u, id, i);
    icons.forEntry(self, kit, t.path().?, e, 48);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 1, .clip = .both });
    defer u.close();
    var style = kit.style(.body, p.text_primary);
    style.wrap = .none;
    nameOrField(self, kit, i, e, style);
    var small = kit.style(.caption, p.text_secondary);
    small.wrap = .none;
    var type_buffer: [64]u8 = undefined;
    u.text(kit.print("{s}", .{self.mime.describe(e.mime, e.name, &type_buffer)}), small);
    if (!e.isFolder()) {
        var size_buffer: [32]u8 = undefined;
        u.text(kit.print("{s}", .{Folder.sizeText(e.size, &size_buffer)}), small);
    }
}

/// What went wrong last, across the top of the folder, until closed.
fn noticeBar(self: *Files, kit: *Kit) void {
    const text = self.notice() orelse return;
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{
        .id = "notice",
        .width = .grow,
        .padding = .xy(12, 8),
        .gap = 10,
        .align_y = .center,
        .background_color = p.critical_background,
        .border = .{ .color = p.divider, .width = .{ .bottom = 1 } },
    });
    defer u.close();
    kit.icon(.error_circle, 16, p.critical, .filled);
    u.open(.{ .width = .grow });
    var style = kit.style(.body, p.text_primary);
    style.wrap = .words;
    u.text(text, style);
    u.close();
    if (kit.button("notice/close", "", .{ .kind = .subtle, .icon = .dismiss })) self.notice_len = 0;
}

// -------------------------------------------------------------------------
// Home, and This PC
// -------------------------------------------------------------------------

fn section(kit: *Kit, title: []const u8) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .padding = .trbl(16, 8, 8, 8), .gap = 8, .align_y = .center });
    defer u.close();
    kit.icon(.chevron_down, 12, kit.theme.palette.text_secondary, .regular);
    kit.label(title, .body_strong, kit.theme.palette.text_primary);
}

/// A place as a tile: its icon, its name, and a line under it.
fn placeTile(self: *Files, kit: *Kit, id: []const u8, icon_name: []const u8, name: []const u8, line: []const u8, pinned: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const lit = self.page_chosen != null and std.mem.eql(u8, self.page_chosen_buffer[0..self.page_chosen_len], id);
    u.open(.{
        .id = id,
        .width = .fixed(260),
        .height = .fixed(64),
        .padding = .xy(10, 0),
        .gap = 12,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, lit, u.isPointerOver(id)),
    });
    defer u.close();
    icons.themed(self, kit, icon_name, 32);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2, .clip = .both });
    var style = kit.style(.body, p.text_primary);
    style.wrap = .none;
    u.text(name, style);
    var small = kit.style(.caption, p.text_secondary);
    small.wrap = .none;
    u.text(line, small);
    u.close();
    if (pinned and !self.ten()) kit.icon(.pin, 12, p.text_secondary, .regular);
    // A click chooses it, a double click goes there.
    if (u.justPressed()) {
        if (self.window.clickCount() >= 2) return true;
        self.choosePageItem(id);
    }
    return false;
}

fn homePage(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .id = scroll_id, .width = .grow, .height = .grow, .direction = .top_to_bottom, .padding = .xy(12, 4), .clip = scrollClip(kit) });
    defer u.close();
    var to: ?[]const u8 = null;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    section(kit, if (self.ten()) "Frequent folders" else "Quick access");
    {
        u.open(.{ .width = .grow, .wrap = true, .gap = 4, .wrap_gap = 4, .padding = .xy(8, 0) });
        defer u.close();
        for (self.places.user.items, 0..) |f, i| {
            if (placeTile(self, kit, kit.print("home/user/{d}", .{i}), icons.special(f.special), f.name, "Stored locally", true)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch null;
        }
        for (self.places.pinned.items, 0..) |f, i| {
            if (placeTile(self, kit, kit.print("home/pin/{d}", .{i}), "folder", f.name, f.path, true)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch null;
        }
    }
    if (!self.ten()) {
        section(kit, "Favorites");
        emptyNote(kit, "After you've favorited some files, we'll show them here.");
    }
    section(kit, if (self.ten()) "Recent files" else "Recent");
    emptyNote(kit, "After you've opened some files, we'll show the most recent ones here.");
    _ = p;
    if (to) |path| self.goTo(.{ .folder = path });
}

fn emptyNote(kit: *Kit, text: []const u8) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .padding = .trbl(4, 16, 8, 32) });
    defer u.close();
    kit.label(text, .body, kit.theme.palette.text_secondary);
}

fn thisPcPage(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    u.open(.{ .id = scroll_id, .width = .grow, .height = .grow, .direction = .top_to_bottom, .padding = .xy(12, 4), .clip = scrollClip(kit) });
    defer u.close();
    var to: ?[]const u8 = null;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    // Windows 10's This PC has the folders first; Windows 11's leaves them
    // to Home.
    if (self.ten()) {
        section(kit, kit.print("Folders ({d})", .{self.places.user.items.len}));
        u.open(.{ .width = .grow, .wrap = true, .gap = 4, .wrap_gap = 4, .padding = .xy(8, 0) });
        for (self.places.user.items, 0..) |f, i| {
            if (placeTile(self, kit, kit.print("pc/user/{d}", .{i}), icons.special(f.special), f.name, "", false)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch null;
        }
        u.close();
    }
    section(kit, kit.print("Devices and drives ({d})", .{self.places.drives.items.len}));
    u.open(.{ .width = .grow, .wrap = true, .gap = 4, .wrap_gap = 4, .padding = .xy(8, 0) });
    for (self.places.drives.items, 0..) |d, i| {
        if (driveTile(self, kit, kit.print("pc/drive/{d}", .{i}), d)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{d.mount}) catch null;
    }
    u.close();
    if (to) |path| self.goTo(.{ .folder = path });
}

/// A drive: its icon, its name, how full it is as a bar - red past nine
/// tenths, as Windows warns - and "X GB free of Y GB".
fn driveTile(self: *Files, kit: *Kit, id: []const u8, d: Places.Drive) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const lit = self.page_chosen != null and std.mem.eql(u8, self.page_chosen_buffer[0..self.page_chosen_len], id);
    u.open(.{
        .id = id,
        .width = .fixed(300),
        .height = .fixed(72),
        .padding = .xy(10, 0),
        .gap = 12,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, lit, u.isPointerOver(id)),
    });
    defer u.close();
    icons.themed(self, kit, if (d.removable) "drive-removable-media" else "drive-harddisk", 48);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 4, .clip = .both });
    defer u.close();
    var style = kit.style(.body, p.text_primary);
    style.wrap = .none;
    u.text(kit.print("{s} ({s})", .{ d.label, d.mount }), style);
    const used: f32 = if (d.size > 0) @as(f32, @floatFromInt(d.size - d.free)) / @as(f32, @floatFromInt(d.size)) else 0;
    u.open(.{ .width = .grow, .height = .fixed(if (self.ten()) 14 else 6), .corner_radius = .all(if (self.ten()) 0 else 3), .background_color = p.control_alt_secondary, .border = if (self.ten()) .{ .color = p.divider, .width = .all(1) } else .{} });
    u.empty(.{ .width = .percent(used), .height = .grow, .corner_radius = .all(if (self.ten()) 0 else 3), .background_color = if (used > 0.9) p.critical else if (self.ten()) widgets.argb(0xFF26A0DA) else p.accent });
    u.close();
    var free_buffer: [32]u8 = undefined;
    var size_buffer: [32]u8 = undefined;
    var small = kit.style(.caption, p.text_secondary);
    small.wrap = .none;
    u.text(kit.print("{s} free of {s}", .{ Folder.sizeText(d.free, &free_buffer), Folder.sizeText(d.size, &size_buffer) }), small);
    if (u.justPressed()) {
        if (self.window.clickCount() >= 2) return true;
        self.choosePageItem(id);
    }
    return false;
}

test "Details writes sizes in whole kilobytes, thousands apart" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("1 KB", detailsSize(1, &buffer));
    try std.testing.expectEqualStrings("2,048 KB", detailsSize(2048 * 1024, &buffer));
    try std.testing.expectEqualStrings("0 KB", detailsSize(0, &buffer));
}
