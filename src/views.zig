// SPDX-License-Identifier: BSD-2-Clause

//! What a tab shows: Home (Windows 10's Quick access), This PC, or a list -
//! a folder, a search's findings, the Recycle Bin - in one of Windows'
//! eight views: Extra large, Large, Medium and Small icons, List, Details,
//! Tiles, Content; in groups, where it is grouped, each under its heading
//! and folded by it.
//!
//! **Only what is in sight is laid out**: a folder of a hundred thousand
//! files costs what forty do. What is above and below is a spacer each,
//! as tall as it would be.
//!
//! A drag from where there is no item draws a rubber band, and what it
//! touches is chosen; with check boxes on, each item has one to tick.

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
const icons = @import("icons.zig");
const menus = @import("menus.zig");
const actions = @import("actions.zig");
const win10 = @import("win10.zig");
const drag = @import("drag.zig");
const History = @import("History.zig");

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
    renameDue(self);
    drag.follow(self, kit);
    switch (t.location) {
        .home => homePage(self, kit),
        .this_pc => thisPcPage(self, kit),
        .folder, .search, .trash => listView(self, kit),
        .gallery => galleryView(self, kit),
    }
}

fn scrollClip(kit: *Kit) ui.layout.Clip {
    return .{
        .vertical = true,
        .scroll_y = true,
        .no_drag_scroll = true,
        .scrollbar = .{ .width = 6, .corner_radius = if (kit.theme.look.style == .win10) 0 else 3, .thumb_color = kit.theme.palette.text_tertiary, .hide_after_seconds = 1.5 },
    };
}

/// The colour an item is drawn on: chosen, under the pointer, or neither.
fn itemFill(self: *Files, kit: *Kit, selected: bool, hovered: bool) Color {
    const p = &kit.theme.palette;
    if (self.ten()) {
        if (selected) return win10.pressColor(kit);
        if (hovered) return win10.hoverColor(kit);
        return .transparent;
    }
    if (selected) return p.accent.withAlpha(if (p.mode == .dark) 0.32 else 0.18);
    if (hovered) return p.subtle_secondary;
    return .transparent;
}

/// Windows 10's chosen item has an edge a shade deeper than its fill.
fn win10Edge(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF999999) else widgets.argb(0xFF99D1FF);
}

fn itemBorder(self: *Files, kit: *Kit, i: usize, selected: bool, hovered: bool) ui.layout.Border {
    const t = self.tab();
    if (self.ten() and (selected or hovered)) return .{ .color = if (selected) win10Edge(kit) else win10.hoverColor(kit), .width = .all(1) };
    if (t.focus == i and !selected and t.selectedCount() > 0) return .{ .color = kit.theme.palette.focus_outer.withAlpha(0.6), .width = .all(1) };
    return .{};
}

/// A name as shown: without its extension when they are hidden.
fn shownName(self: *Files, e: *const Folder.Entry) []const u8 {
    if (self.show_extensions or e.isFolder()) return e.name;
    const dot = std.mem.lastIndexOfScalar(u8, e.name, '.') orelse return e.name;
    return if (dot == 0) e.name else e.name[0..dot];
}

/// How long the pointer rests on an item before it is chosen by it - in
/// single-click mode - and its description pops up.
const rest_ms = 600;

/// A right click on item `i`: chosen, if it was not, and its menu; a
/// middle click on a folder: it in a new tab. The pointer resting on it,
/// and - in single-click mode - a click opening it.
fn requests(self: *Files, u: *ui.Ui, id: []const u8, i: usize) void {
    const t = self.tab();
    if (u.isPointerOver(id) and !self.window.down) {
        self.hover_seen = true;
        const now = Window.nowMs();
        if (self.hover_item != i) {
            self.hover_item = i;
            self.hover_since = now;
            self.window.wakeAt(now + rest_ms);
        } else if (now - self.hover_since >= rest_ms and self.prefs.single_click and t.selectedCount() <= 1 and !t.selected.items[i]) {
            // Single-click mode: pointed to, it is chosen.
            t.click(i, false, false);
        }
    }
    if (self.prefs.single_click and u.isElementReleased(id) and self.window.clickCount() < 2 and !self.window.modifierHeld("Control") and !self.window.modifierHeld("Shift")) {
        self.open(i, false);
        return;
    }
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
        // Single-click mode: names underlined, as links are - always, or
        // under the pointer - and lit there.
        if (self.prefs.single_click) {
            var buffer: [32]u8 = undefined;
            const hovered = u.isPointerOver(std.fmt.bufPrint(&buffer, "item/{d}", .{i}) catch "");
            if (self.prefs.underline == .always or hovered) {
                var link = style;
                if (hovered) link.color = if (kit.theme.palette.mode == .dark) widgets.argb(0xFF6CB4F2) else widgets.argb(0xFF0066CC);
                u.open(.{ .direction = .top_to_bottom, .align_x = if (style.alignment == .center) .center else .left });
                defer u.close();
                u.text(shownName(self, e), link);
                u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = link.color });
                return;
            }
        }
        // A search's findings: what was searched for lit in each name, as
        // Windows marks it.
        if (self.tab().location == .search) if (matchIn(self.tab().location.search.query, shownName(self, e))) |m| {
            const name = shownName(self, e);
            const dark = kit.theme.palette.mode == .dark;
            u.open(.{ .align_y = .center });
            defer u.close();
            if (m[0] > 0) u.text(name[0..m[0]], style);
            var lit = style;
            if (dark) lit.color = widgets.argb(0xFFFFFFFF);
            u.open(.{ .background_color = if (dark) widgets.argb(0xFF6B5B00) else widgets.argb(0xFFFFE97F) });
            u.text(name[m[0]..m[1]], lit);
            u.close();
            if (m[1] < name.len) u.text(name[m[1]..], style);
            return;
        };
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

/// Where the first of a search's words is in `name`, case aside.
fn matchIn(query: []const u8, name: []const u8) ?[2]usize {
    const q = @import("Search.zig").Query.parse(query);
    for (q.wordList()) |w| {
        if (w.len == 0 or w.len > name.len) continue;
        var i: usize = 0;
        while (i + w.len <= name.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(name[i .. i + w.len], w)) return .{ i, i + w.len };
        }
    }
    return null;
}

/// A click, a Ctrl or Shift click, a double click, on item `i`.
fn pressed(self: *Files, i: usize) void {
    const t = self.tab();
    const w = &self.window;
    const ctrl = w.modifierHeld("Control");
    const shift = w.modifierHeld("Shift");
    // Single-click mode: a click opens - when it comes up.
    if (self.prefs.single_click and !ctrl and !shift) {
        t.click(i, false, false);
        return;
    }
    if (w.clickCount() >= 2 and !ctrl and !shift) {
        self.rename_pending = null;
        if (t.location == .trash) return self.openProperties();
        self.open(i, false);
        return;
    }
    // A click on the one chosen: its name to type anew, as Windows has it
    // - in a moment, unless the click was the first of a double click.
    if (!ctrl and !shift and t.selectedCount() == 1 and t.selected.items[i] and self.renaming == null and t.location != .trash) {
        self.rename_pending = i;
        self.rename_pending_ms = Window.nowMs() + 500;
        w.wakeAt(self.rename_pending_ms);
    }
    t.click(i, ctrl, shift);
}

/// A press on item `i`: on its check box, ticked or not, the rest as they
/// were; elsewhere, a click.
fn pressedOn(self: *Files, u: *ui.Ui, i: usize) void {
    var buffer: [32]u8 = undefined;
    const check = std.fmt.bufPrint(&buffer, "item/{d}/check", .{i}) catch "";
    if (self.check_boxes and u.isPointerOver(check)) {
        self.tab().click(i, true, false);
        return;
    }
    pressed(self, i);
    // Not a double click: perhaps the start of a drag.
    if (self.window.clickCount() < 2) drag.pressed(self, i);
}

/// A name to type anew, asked for by a click on the one chosen, once no
/// second click made it a double one.
fn renameDue(self: *Files) void {
    const i = self.rename_pending orelse return;
    if (Window.nowMs() < self.rename_pending_ms) return;
    self.rename_pending = null;
    const t = self.tab();
    if (i < t.count() and t.selected.items[i] and t.selectedCount() == 1) self.startRename(i);
}

/// A check box on the item: what is chosen, ticked or not.
fn checkBox(self: *Files, kit: *Kit, i: usize, shown: bool) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const id = kit.print("item/{d}/check", .{i});
    const on = t.selected.items[i];
    u.open(.{
        .id = id,
        .width = .fixed(16),
        .height = .fixed(16),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 3),
        .background_color = if (!shown) .transparent else if (on) (if (self.ten()) widgets.argb(0xFF1979CA) else p.accent) else chrome.contentColor(kit),
        .border = if (!shown) .{} else .{ .color = if (on) .transparent else p.control_strong_stroke, .width = .all(1) },
    });
    if (shown and on) kit.icon(.checkmark, 12, p.text_on_accent, .regular);
    u.close();
}

// -------------------------------------------------------------------------
// A list: a folder, a search's findings, the Recycle Bin
// -------------------------------------------------------------------------

/// The columns of Details, for what is shown: a folder's own - those of
/// `Folder.Column` it shows - a search's with where each was found, the
/// Recycle Bin's with where each was and when it went.
pub const Col = enum { name, modified, type, size, created, accessed, attributes, owner, folder, original, deleted };

/// The column a `Folder.Column` is shown as.
pub fn colOfColumn(c: Folder.Column) Col {
    return colOf(c);
}

fn colOf(c: Folder.Column) Col {
    return switch (c) {
        .name => .name,
        .modified => .modified,
        .type => .type,
        .size => .size,
        .created => .created,
        .accessed => .accessed,
        .attributes => .attributes,
        .owner => .owner,
    };
}

/// The `Folder.Column` a column is - what it sorts by, and where its width
/// is kept - if it is one.
fn colSort(c: Col) ?Folder.Column {
    return switch (c) {
        .name => .name,
        .modified => .modified,
        .type => .type,
        .size => .size,
        .created => .created,
        .accessed => .accessed,
        .attributes => .attributes,
        .owner => .owner,
        else => null,
    };
}

pub fn columnsOf(t: *const Tab, buffer: *[12]Col) []const Col {
    if (t.location == .trash) return &.{ .name, .original, .deleted, .size, .type, .modified };
    var n: usize = 0;
    inline for (@typeInfo(Folder.Column).@"enum".fields) |f| {
        const c: Folder.Column = @enumFromInt(f.value);
        if (c == .name or t.columns & (@as(u16, 1) << f.value) != 0) {
            buffer[n] = colOf(c);
            n += 1;
        }
    }
    if (t.location == .search) {
        buffer[n] = .folder;
        n += 1;
    }
    return buffer[0..n];
}

pub fn colName(c: Col) []const u8 {
    return switch (c) {
        .name => "Name",
        .modified => "Date modified",
        .type => "Type",
        .size => "Size",
        .created => "Date created",
        .accessed => "Date accessed",
        .attributes => "Attributes",
        .owner => "Owner",
        .folder => "Folder",
        .original => "Original Location",
        .deleted => "Date Deleted",
    };
}

/// A column's own width; Name's is what is left.
fn colWidth(c: Col) ?f32 {
    return switch (c) {
        .name => null,
        .modified, .deleted, .created, .accessed => 150,
        .type => 150,
        .size => 90,
        .attributes => 80,
        .owner => 110,
        .folder, .original => 220,
    };
}

/// A column's width: as wide as it was dragged to; else Name takes what is
/// left, never less than a name needs, and the others give way down to
/// about half, as a narrow window squeezes them.
fn colSizing(t: *const Tab, c: Col) ui.layout.Sizing {
    if (colSort(c)) |s| {
        const w = t.widths[@intFromEnum(s)];
        if (w > 0) return .fixed(@floatFromInt(w));
    }
    const w = colWidth(c) orelse return .growWith(.{ .min = 160 });
    return .fixedDownTo(w, w * 0.55);
}

fn listView(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    if (self.fit_columns) {
        self.fit_columns = false;
        fitAllColumns(self, kit);
    }
    noticeBar(self, kit);
    if (t.view == .details) detailsHeader(self, kit);
    u.open(.{
        .id = scroll_id,
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .trbl(if (t.view == .details) 0 else 6, if (self.ten()) 0 else 8, 8, if (self.ten()) 0 else 8),
        .clip = scrollClip(kit),
    });
    defer u.close();
    defer if (self.context_at) |at| if (u.isPointerOver(scroll_id)) {
        // On nothing: the folder's own menu, and nothing chosen.
        t.selectNone();
        menus.openAt(self, at, false);
        self.context_at = null;
    };
    // A press on nothing chooses nothing - and starts a rubber band.
    if (u.justPressed() and !overAnItem(self, u)) {
        if (!self.window.modifierHeld("Control")) t.selectNone();
        self.band_from = self.window.pointer_at;
        self.band_base.clearRetainingCapacity();
        self.band_base.appendSlice(self.gpa, t.selected.items) catch {};
    }
    if (t.count() == 0) {
        u.open(.{ .width = .grow, .padding = .all(24), .align_x = .center });
        const empty_text = switch (t.location) {
            .search => if (self.searching()) "Searching…" else "No items match your search.",
            else => if (t.folder != null and t.folder.?.failure != null) "This folder could not be read." else "This folder is empty.",
        };
        kit.label(empty_text, .caption, p.text_secondary);
        u.close();
        return;
    }
    const ten = self.ten();
    const row_h: f32 = if (ten) 22 else if (self.compact) 26 else 32;
    switch (t.view) {
        .details => lines(self, kit, .{ 0, row_h }, false),
        .content => lines(self, kit, .{ 0, 64 }, false),
        .extra_large => lines(self, kit, .{ 232, 264 }, true),
        .large => lines(self, kit, .{ 120, 140 }, true),
        .medium => lines(self, kit, .{ 96, 96 }, true),
        .small, .list => lines(self, kit, .{ 240, row_h }, true),
        .tiles => lines(self, kit, .{ 280, 68 }, true),
    }
    rubberBand(self, kit);
    answerDrop(self, u);
    infotip(self, kit);
}

/// Folder Options' "Show pop-up description": the item the pointer rests
/// on, said in a tip beside it - a file's kind, size and date; a folder's
/// date, size and what is in it.
fn infotip(self: *Files, kit: *Kit) void {
    if (!self.hover_seen) self.hover_item = null;
    self.hover_seen = false;
    const i = self.hover_item orelse return;
    if (!self.prefs.infotips or self.window.down or self.menu != .none or self.context_open != null or self.window.dragOver()) return;
    if (Window.nowMs() - self.hover_since < rest_ms) return;
    const t = self.tab();
    if (i >= t.count()) return;
    const at = self.window.pointer_at orelse return;
    if (self.tip_item != i) {
        self.tip_item = i;
        self.tip_len = describe(self, t, i).len;
    }
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    u.open(.{
        .id = "infotip",
        .direction = .top_to_bottom,
        .padding = .xy(8, 5),
        .gap = 1,
        .background_color = if (ten) (if (p.mode == .dark) widgets.argb(0xFF2B2B2B) else widgets.argb(0xFFFFFFFF)) else p.flyout,
        .border = .{ .color = if (ten) (if (p.mode == .dark) widgets.argb(0xFF767676) else widgets.argb(0xFF767676)) else p.surface_stroke_flyout, .width = .all(1) },
        .corner_radius = .all(if (ten) 0 else 4),
        .shadow = kit.elevation(.tooltip),
        .floating = .{ .attach = .root, .offset = .{ .x = at[0] + 12, .y = at[1] + 20 }, .z_index = 115, .keep_on_screen = true },
        .passthrough = true,
    });
    defer u.close();
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    var said = std.mem.splitScalar(u8, self.tip_buffer[0..self.tip_len], '\n');
    while (said.next()) |line| u.text(line, style);
}

/// What the tip says of item `i`, into the window's buffer for it.
fn describe(self: *Files, t: *Tab, i: usize) []const u8 {
    const e = t.entry(i);
    var w: std.Io.Writer = .fixed(&self.tip_buffer);
    var date_buffer: [32]u8 = undefined;
    var size_buffer: [32]u8 = undefined;
    if (!e.isFolder()) {
        var type_buffer: [64]u8 = undefined;
        w.print("Type: {s}\nSize: {s}\nDate modified: {s}", .{ self.mime.describe(e.mime, e.name, &type_buffer), Folder.sizeText(e.size, &size_buffer), dateText(e.mtime, &date_buffer) }) catch {};
        return w.buffered();
    }
    w.print("Date created: {s}", .{dateText(if (e.created != 0) e.created else e.mtime, &date_buffer)}) catch {};
    // What is in it, at the first level: its folders and files by name.
    const dir = t.dirOf(e) orelse return w.buffered();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = @import("Ops.zig").join(&path_buffer, dir, e.name) catch return w.buffered();
    var folder = std.Io.Dir.cwd().openDir(self.io, full, .{ .iterate = true }) catch return w.buffered();
    defer folder.close(self.io);
    var folders: [4][]const u8 = undefined;
    var files: [4][]const u8 = undefined;
    var names_buffer: [8][128]u8 = undefined;
    var nf: usize = 0;
    var nd: usize = 0;
    var more_folders = false;
    var more_files = false;
    var bytes: u64 = 0;
    var all_files = true;
    var seen: usize = 0;
    var it = folder.iterate();
    while (it.next(self.io) catch null) |entry| {
        if (entry.name[0] == '.' and !self.show_hidden) continue;
        seen += 1;
        if (seen > 2000) break;
        if (entry.kind == .directory) {
            all_files = false;
            if (nd < folders.len) {
                const n = @min(entry.name.len, 127);
                @memcpy(names_buffer[nd][0..n], entry.name[0..n]);
                folders[nd] = names_buffer[nd][0..n];
                nd += 1;
            } else more_folders = true;
        } else {
            if (self.prefs.folder_size_tips) if (folder.statFile(self.io, entry.name, .{})) |st| {
                bytes += st.size;
            } else |_| {};
            if (nf < files.len) {
                const n = @min(entry.name.len, 127);
                @memcpy(names_buffer[4 + nf][0..n], entry.name[0..n]);
                files[nf] = names_buffer[4 + nf][0..n];
                nf += 1;
            } else more_files = true;
        }
    }
    if (seen == 0) {
        w.writeAll("\nEmpty folder") catch {};
        return w.buffered();
    }
    // Its size, where only files are in it: the rest would take a while.
    if (self.prefs.folder_size_tips and all_files) w.print("\nSize: {s}", .{Folder.sizeText(bytes, &size_buffer)}) catch {};
    if (nd > 0) {
        w.writeAll("\nFolders: ") catch {};
        for (folders[0..nd], 0..) |f, k| w.print("{s}{s}", .{ if (k > 0) ", " else "", f }) catch {};
        if (more_folders) w.writeAll(", ...") catch {};
    }
    if (nf > 0) {
        w.writeAll("\nFiles: ") catch {};
        for (files[0..nf], 0..) |f, k| w.print("{s}{s}", .{ if (k > 0) ", " else "", f }) catch {};
        if (more_files) w.writeAll(", ...") catch {};
    }
    return w.buffered();
}

/// A drag over the list: into the folder under the pointer, or else into
/// the folder shown - or, over the Recycle Bin, into it.
fn answerDrop(self: *Files, u: *ui.Ui) void {
    if (!self.window.dragOver() or !u.isPointerOver(scroll_id)) return;
    const t = self.tab();
    // Nothing is put into a compressed folder.
    if (t.inArchive()) return;
    var buffer: [32]u8 = undefined;
    for (0..t.count()) |i| {
        const id = std.fmt.bufPrint(&buffer, "item/{d}", .{i}) catch continue;
        if (!u.isPointerOver(id)) continue;
        const e = t.entry(i);
        if (!e.isFolder()) break;
        const dir = t.dirOf(e) orelse break;
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = @import("Ops.zig").join(&path_buffer, dir, e.name) catch break;
        return drag.answerFolder(self, u, id, full);
    }
    switch (t.location) {
        .folder => |here| drag.answerFolder(self, u, scroll_id, here),
        .trash => drag.answerTrash(self, u, scroll_id),
        else => {},
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
    // A group's heading is something too.
    for (0..t.groups.items.len) |g| {
        const id = std.fmt.bufPrint(&buffer, "group/{d}", .{g}) catch continue;
        if (u.isPointerOver(id)) return true;
    }
    return false;
}

/// Where in the scrolled list the view is, in the window's pixels.
fn scrolled(self: *Files, u: *ui.Ui) struct { top: f32, height: f32, width: f32 } {
    const s = self.window.scale;
    const scroll = u.scrollOf(scroll_id) orelse return .{ .top = 0, .height = @floatFromInt(self.window.height), .width = @floatFromInt(self.window.width) };
    return .{
        .top = scroll.position.y / s,
        .height = if (scroll.viewport.height > 0) scroll.viewport.height / s else @floatFromInt(self.window.height),
        .width = if (scroll.viewport.width > 0) scroll.viewport.width / s else @floatFromInt(self.window.width),
    };
}

/// What the list is made of, line by line: a group's heading, a row, or a
/// row of cells.
const Line = struct { group: ?usize = null, first: usize = 0, end: usize = 0, h: f32 };

/// The list drawn as lines - one item each, or `cell` wide cells - in
/// groups where it is grouped, only the lines in sight.
fn lines(self: *Files, kit: *Kit, cell: [2]f32, grid: bool) void {
    const u = kit.ui;
    const t = self.tab();
    const view = scrolled(self, u);
    const across: usize = if (grid) @max(1, @as(usize, @intFromFloat(@floor((view.width - 16) / cell[0])))) else 1;
    self.grid_columns = across;
    const header_h: f32 = if (self.ten()) 30 else 40;

    // The lines, top to bottom, as the groups have them.
    var all: std.ArrayList(Line) = .empty;
    defer all.deinit(self.gpa);
    const n = t.count();
    if (t.groups.items.len == 0) {
        var i: usize = 0;
        while (i < n) : (i += across) all.append(self.gpa, .{ .first = i, .end = @min(n, i + across), .h = cell[1] }) catch return;
    } else for (t.groups.items, 0..) |g, gi| {
        all.append(self.gpa, .{ .group = gi, .h = header_h }) catch return;
        if (g.folded) continue;
        var i = g.first;
        while (i < g.first + g.count) : (i += across) all.append(self.gpa, .{ .first = i, .end = @min(g.first + g.count, i + across), .h = cell[1] }) catch return;
    }

    // The keyboard moved: the line it is on brought into sight.
    if (t.reveal) if (t.focus) |f| {
        var y: f32 = 0;
        for (all.items) |l| {
            if (l.group == null and f >= l.first and f < l.end) {
                const s = self.window.scale;
                if (y < view.top) u.scrollTo(scroll_id, 0, y * s) else if (y + l.h > view.top + view.height) u.scrollTo(scroll_id, 0, (y + l.h - view.height) * s);
                break;
            }
            y += l.h;
        }
        t.reveal = false;
        self.window.redraw();
    };

    var y: f32 = 0;
    var above: f32 = 0;
    var below: f32 = 0;
    for (all.items) |l| {
        const in_sight = y + l.h >= view.top - 200 and y <= view.top + view.height + 200;
        if (!in_sight) {
            if (y < view.top) above += l.h else below += l.h;
            y += l.h;
            continue;
        }
        if (above > 0) {
            u.empty(.{ .width = .grow, .height = .fixed(above) });
            above = 0;
        }
        if (l.group) |gi| {
            groupHeading(self, kit, gi, l.h);
        } else if (!grid) {
            for (l.first..l.end) |i| if (t.view == .content) contentRow(self, kit, i, l.h) else detailsRow(self, kit, i, l.h);
        } else {
            u.open(.{ .width = .grow, .height = .fixed(l.h) });
            defer u.close();
            for (l.first..l.end) |i| switch (t.view) {
                .tiles => tileCell(self, kit, i, cell),
                .small, .list => smallCell(self, kit, i, cell),
                .extra_large => iconCell(self, kit, i, cell, 192),
                .large => iconCell(self, kit, i, cell, 96),
                else => iconCell(self, kit, i, cell, 48),
            };
        }
        y += l.h;
    }
    if (below > 0) u.empty(.{ .width = .grow, .height = .fixed(below) });
}

/// A group's heading: its name and how many are in it - Windows 11's with
/// a chevron, Windows 10's in blue with a line after it. A click folds it.
fn groupHeading(self: *Files, kit: *Kit, gi: usize, h: f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const g = &t.groups.items[gi];
    const id = kit.print("group/{d}", .{gi});
    const hovered = u.isPointerOver(id);
    const ten = self.ten();
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(h),
        .padding = .trbl(if (ten) 6 else 10, 8, 0, if (ten) 4 else 8),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (hovered) (if (ten) win10.hoverColor(kit) else p.subtle_secondary) else .transparent,
    });
    defer u.close();
    if (!ten) kit.icon(if (g.folded) .chevron_right else .chevron_down, 12, p.text_secondary, .regular);
    const blue = if (p.mode == .dark) widgets.argb(0xFF6CB4F2) else widgets.argb(0xFF1E3287);
    var style = kit.style(if (ten) .body else .body_strong, if (ten) blue else p.text_primary);
    style.wrap = .none;
    u.text(kit.print("{s} ({d})", .{ g.name(), g.count }), style);
    if (ten) {
        u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = if (p.mode == .dark) widgets.argb(0xFF3C3C3C) else widgets.argb(0xFFE2E2E2) });
        if (hovered) kit.icon(if (g.folded) .chevron_down else .chevron_up, 10, blue, .regular);
    }
    if (u.justReleased()) g.folded = !g.folded;
}

// -- Details --

fn detailsHeader(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const ten = self.ten();
    const header_id = "details/header";
    u.open(.{
        .id = header_id,
        .width = .grow,
        .height = .fixed(if (ten) 25 else 32),
        .padding = .trbl(0, if (ten) 0 else 16, 0, if (ten) 0 else 16),
        .align_y = .center,
        .border = if (ten) .{ .color = win10.edgeColor(kit), .width = .{ .bottom = 1 } } else .{},
    });
    defer u.close();
    if (self.check_boxes) u.empty(.{ .width = .fixed(24) });
    var buffer: [12]Col = undefined;
    for (columnsOf(t, &buffer)) |c| {
        const id = kit.print("details/column/{t}", .{c});
        const hovered = u.isPointerOver(id);
        u.open(.{
            .id = id,
            .width = colSizing(t, c),
            .height = .grow,
            .padding = .xy(if (ten) 6 else 8, 0),
            .gap = 4,
            .align_y = .center,
            .align_x = if (c == .size) .right else .left,
            .background_color = if (hovered) (if (ten) win10.hoverColor(kit) else p.subtle_secondary) else .transparent,
            .border = if (ten) .{ .color = win10.edgeColor(kit), .width = .{ .right = 1 } } else .{},
            .clip = .both,
        });
        // Windows 10's headings are a muted blue.
        var style = kit.style(.caption, if (ten) (if (p.mode == .dark) widgets.argb(0xFFB0B0B0) else widgets.argb(0xFF4C607A)) else p.text_secondary);
        style.wrap = .none;
        u.text(colName(c), style);
        // The column sorted by: a small chevron over its name's middle, as
        // Windows marks it.
        if (colSort(c)) |s| if (t.sort_by == s) {
            u.open(.{ .floating = .{ .attach = .parent, .fractions = .{ .element_x = 0.5, .element_y = 0, .target_x = 0.5, .target_y = 0 }, .offset = .{ .x = 0, .y = if (ten) -1 else 1 } }, .passthrough = true });
            kit.icon(if (t.ascending) .chevron_up else .chevron_down, 8, p.text_secondary, .regular);
            u.close();
        };
        if (u.justReleased() and self.col_drag == null) if (colSort(c)) |s| self.sortBy(s);
        columnGrip(self, kit, t, c, id);
        u.close();
    }
    // A right click on the heads: which columns, and their widths.
    if (self.context_at) |at| if (u.isPointerOver(header_id) or u.isPointerWithin(header_id)) {
        self.menu = .columns;
        self.columns_at = at;
        self.columns_col = null;
        for (columnsOf(t, &buffer)) |c| if (u.isPointerWithin(kit.print("details/column/{t}", .{c}))) {
            self.columns_col = colSort(c);
        };
        self.context_at = null;
    };
    // Dragged: the column as wide as the pointer says, kept once let go.
    if (self.col_drag) |drag_state| {
        u.setCursor(.resize_ew);
        if (!self.window.down) {
            self.col_drag = null;
            self.folder_views.remember(self.io, t);
        } else if (self.window.pointer_at) |ptr| {
            t.widths[drag_state.col] = @intFromFloat(@max(40, drag_state.from_width + ptr[0] - drag_state.from_x));
        }
    }
}

/// The edge at a column head's right: dragged, the column wider or
/// narrower; double-clicked, as wide as what is in it.
fn columnGrip(self: *Files, kit: *Kit, t: *Tab, c: Col, cell_id: []const u8) void {
    const u = kit.ui;
    const s = colSort(c) orelse return;
    const id = kit.print("details/grip/{t}", .{c});
    u.open(.{
        .id = id,
        .width = .fixed(8),
        .height = .grow,
        .cursor = .resize_ew,
        .floating = .{ .attach = .parent, .fractions = .{ .element_x = 0.5, .element_y = 0, .target_x = 1, .target_y = 0 }, .z_index = 3 },
    });
    defer u.close();
    if (!u.justPressed()) return;
    if (self.window.clickCount() >= 2) {
        self.col_drag = null;
        fitColumn(self, kit, t, c);
        self.folder_views.remember(self.io, t);
        return;
    }
    const box = self.window.boxOf(cell_id) orelse return;
    const at = self.window.pointer_at orelse return;
    self.col_drag = .{ .col = @intFromEnum(s), .from_x = at[0], .from_width = box.width };
}

/// A column as wide as the widest thing in it - and its name.
pub fn fitColumn(self: *Files, kit: *Kit, t: *Tab, c: Col) void {
    const s = colSort(c) orelse return;
    const m = kit.ui.measurer orelse return;
    const style = kit.style(.caption, kit.theme.palette.text_primary);
    var widest = m.measure(colName(c), style).width + 24;
    const n = @min(t.count(), 4000);
    for (0..n) |i| {
        var buffer: [256]u8 = undefined;
        const e = t.entry(i);
        const text = cellText(self, e, c, &buffer);
        var w = m.measure(text, style).width + 20;
        if (c == .name) w += 16 + 8 + 4;
        widest = @max(widest, w);
    }
    t.widths[@intFromEnum(s)] = @intFromFloat(@min(800, @ceil(widest)));
}

/// "Size all columns to fit" (Ctrl+Numpad +).
pub fn fitAllColumns(self: *Files, kit: *Kit) void {
    const t = self.tab();
    var buffer: [12]Col = undefined;
    for (columnsOf(t, &buffer)) |c| fitColumn(self, kit, t, c);
    self.folder_views.remember(self.io, t);
}

/// The heads' menu - and Windows 10's Add columns: the columns, ticked
/// where shown; sized to fit, one or all; More... for the dialog.
pub fn columnsMenu(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    if (self.window.down and !u.isPointerOver("menu/columns") and !u.isPointerOver("ribbon/columns")) {
        self.menu = .none;
        return;
    }
    const t = self.tab();
    const floating: ui.layout.Floating = if (self.columns_at) |at|
        .{ .attach = .root, .offset = .{ .x = at[0], .y = at[1] }, .z_index = 80, .keep_on_screen = true }
    else
        .{ .attach = .id, .to = "ribbon/columns", .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 }, .z_index = 80 };
    menus.begin(self, kit, "menu/columns", floating);
    defer menus.end(kit);
    if (self.columns_col) |col| {
        if (menus.row(self, kit, "menu/columns/fit", "Size column to fit", .{})) {
            self.menu = .none;
            fitColumn(self, kit, t, colOf(col));
            return self.folder_views.remember(self.io, t);
        }
    }
    if (menus.row(self, kit, "menu/columns/fit-all", "Size all columns to fit", .{ .shortcut = if (self.ten()) null else "Ctrl+Num +" })) {
        self.menu = .none;
        return fitAllColumns(self, kit);
    }
    menus.separator(self, kit);
    inline for (@typeInfo(Folder.Column).@"enum".fields) |f| {
        const c: Folder.Column = @enumFromInt(f.value);
        const bit = @as(u16, 1) << f.value;
        const on = c == .name or t.columns & bit != 0;
        if (menus.row(self, kit, "menu/columns/" ++ f.name, colName(colOf(c)), .{ .marked = on, .ticked = true, .disabled = c == .name })) {
            t.columns ^= bit;
            self.menu = .none;
            return self.folder_views.remember(self.io, t);
        }
    }
    menus.separator(self, kit);
    if (menus.row(self, kit, "menu/columns/more", "More...", .{})) {
        self.menu = .none;
        self.choose_details = .{ .columns = t.columns, .widths = t.widths };
    }
}

/// "Choose Details": the columns ticked or not, and the width of the one
/// chosen - Windows' dialog.
pub fn chooseDetails(self: *Files, kit: *Kit) void {
    const d = &(self.choose_details orelse return);
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const t = self.tab();
    u.open(.{ .id = "details/smoke", .width = .grow, .height = .grow, .align_x = .center, .align_y = .center, .background_color = p.smoke.withAlpha(0.15), .floating = .{ .attach = .root, .z_index = 95 } });
    defer u.close();
    u.open(.{
        .id = "choose-details",
        .width = .fixed(400),
        .direction = .top_to_bottom,
        .corner_radius = .all(if (ten) 0 else 8),
        .background_color = if (p.mode == .dark) widgets.argb(0xFF2B2B2B) else widgets.argb(0xFFF0F0F0),
        .border = .{ .color = if (ten) widgets.argb(0xFF1979CA) else p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .clip = .both,
    });
    defer u.close();
    {
        u.open(.{ .width = .grow, .height = .fixed(32), .padding = .trbl(0, 0, 0, 12), .align_y = .center });
        defer u.close();
        u.open(.{ .width = .grow });
        kit.label("Choose Details", .caption, p.text_primary);
        u.close();
    }
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .all(14), .gap = 8 });
    {
        defer u.close();
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .words;
        u.text("Select the details you want to display for the files in this folder.", style);
        kit.label("Details:", .caption, p.text_primary);
        u.open(.{ .width = .grow, .gap = 10 });
        defer u.close();
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .all(4), .background_color = if (p.mode == .dark) widgets.argb(0xFF202020) else widgets.argb(0xFFFFFFFF), .border = .{ .color = p.divider, .width = .all(1) } });
        inline for (@typeInfo(Folder.Column).@"enum".fields) |f| {
            const c: Folder.Column = @enumFromInt(f.value);
            const bit = @as(u16, 1) << f.value;
            const id = "choose-details/" ++ f.name;
            const lit = d.chosen == f.value;
            u.open(.{ .id = id, .width = .grow, .height = .fixed(20), .gap = 6, .padding = .xy(4, 0), .align_y = .center, .background_color = if (lit) p.accent.withAlpha(0.25) else if (u.isPointerOver(id)) p.subtle_secondary else .transparent });
            var on = c == .name or d.columns & bit != 0;
            u.open(.{ .width = .fixed(13), .height = .fixed(13), .align_x = .center, .align_y = .center, .background_color = if (on) p.accent else p.solid_base, .border = if (on) .{} else .{ .color = p.text_secondary, .width = .all(1) } });
            if (on) kit.icon(.checkmark, 10, p.text_on_accent, .regular);
            u.close();
            kit.label(colName(colOf(c)), .caption, p.text_primary);
            if (u.justReleased()) {
                d.chosen = f.value;
                // A click on the box ticks it; Name stays.
                const px = if (self.window.pointer_at) |ptr| ptr[0] else 0;
                if (c != .name and px < (if (self.window.boxOf(id)) |b| b.x + 24 else 0)) {
                    on = !on;
                    d.columns ^= bit;
                }
            }
            u.close();
        }
        u.close();
        u.open(.{ .direction = .top_to_bottom, .gap = 6 });
        defer u.close();
        const chosen_col: Folder.Column = @enumFromInt(d.chosen);
        const bit = @as(u16, 1) << @intCast(d.chosen);
        const shown = chosen_col == .name or d.columns & bit != 0;
        if (kit.button("choose-details/show", "Show", .{ .width = .fixed(90), .disabled = shown })) d.columns |= bit;
        if (kit.button("choose-details/hide", "Hide", .{ .width = .fixed(90), .disabled = !shown or chosen_col == .name })) d.columns &= ~bit;
    }
    {
        u.open(.{ .width = .grow, .padding = .trbl(0, 14, 0, 14), .gap = 8, .align_y = .center });
        defer u.close();
        const chosen_col: Folder.Column = @enumFromInt(d.chosen);
        const w = d.widths[d.chosen];
        kit.label(kit.print("Width of selected column (in pixels): {d}", .{if (w > 0) w else @as(u16, @intFromFloat(colWidth(colOf(chosen_col)) orelse 240))}), .caption, p.text_primary);
        if (kit.button("choose-details/narrower", "", .{ .icon = .subtract })) d.widths[d.chosen] = @max(40, (if (w > 0) w else @as(u16, @intFromFloat(colWidth(colOf(chosen_col)) orelse 240))) -| 10);
        if (kit.button("choose-details/wider", "", .{ .icon = .add })) d.widths[d.chosen] = (if (w > 0) w else @as(u16, @intFromFloat(colWidth(colOf(chosen_col)) orelse 240))) + 10;
    }
    u.open(.{ .width = .grow, .padding = .all(12), .gap = 8, .align_x = .right });
    defer u.close();
    if (kit.button("choose-details/ok", "OK", .{ .width = .fixed(80) })) {
        t.columns = d.columns;
        t.widths = d.widths;
        self.folder_views.remember(self.io, t);
        self.choose_details = null;
        return;
    }
    if (kit.button("choose-details/cancel", "Cancel", .{ .width = .fixed(80) })) self.choose_details = null;
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
        .border = itemBorder(self, kit, i, selected, hovered),
    });
    defer u.close();
    if (self.check_boxes) {
        u.open(.{ .width = .fixed(24), .align_x = .center });
        checkBox(self, kit, i, hovered or selected);
        u.close();
    }
    if (u.justPressed()) pressedOn(self, u, i);
    requests(self, u, id, i);
    const ink = if (e.hidden) p.text_secondary else p.text_primary;
    var secondary = kit.style(.caption, p.text_secondary);
    secondary.wrap = .none;
    var columns_buffer: [12]Col = undefined;
    for (columnsOf(t, &columns_buffer)) |c| {
        if (c == .name) {
            u.open(.{ .width = colSizing(t, c), .height = .grow, .padding = .xy(if (ten) 6 else 8, 0), .gap = 8, .align_y = .center, .clip = .both });
            defer u.close();
            u.open(.{ .width = .fixed(16), .height = .fixed(16), .opacity = if (e.hidden) 0.55 else 1 });
            icons.forEntry(self, kit, t.dirOf(e) orelse "/", e, 16);
            u.close();
            var style = kit.style(.caption, ink);
            style.wrap = .none;
            nameOrField(self, kit, i, e, style);
            continue;
        }
        u.open(.{ .width = colSizing(t, c), .padding = .xy(8, 0), .align_x = if (c == .size) .right else .left, .clip = .both });
        defer u.close();
        var buffer: [256]u8 = undefined;
        u.text(kit.print("{s}", .{cellText(self, e, c, &buffer)}), secondary);
    }
}

/// What a column says of an entry.
fn cellText(self: *Files, e: *const Folder.Entry, c: Col, buffer: []u8) []const u8 {
    return switch (c) {
        .name => e.name,
        .modified => dateText(e.mtime, buffer),
        .deleted => dateText(e.deleted, buffer),
        .type => self.mime.describe(e.mime, e.name, buffer),
        .size => if (e.isFolder()) "" else detailsSize(e.size, buffer),
        .created => dateText(e.created, buffer),
        .accessed => dateText(e.accessed, buffer),
        .attributes => e.attributes(buffer),
        .owner => @import("Ops.zig").userName(e.uid, buffer),
        .folder, .original => e.dir orelse "",
    };
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
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(row_h),
        .padding = .xy(12, 0),
        .gap = 12,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, selected, hovered),
        .border = if (self.ten() and selected) itemBorder(self, kit, i, selected, hovered) else .{ .color = kit.theme.palette.divider, .width = .{ .bottom = 1 } },
    });
    defer u.close();
    if (self.check_boxes) checkBox(self, kit, i, hovered or selected);
    if (u.justPressed()) pressedOn(self, u, i);
    requests(self, u, id, i);
    icons.forEntry(self, kit, t.dirOf(e) orelse "/", e, 32);
    {
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2, .clip = .both });
        defer u.close();
        var style = kit.style(.caption, p.text_primary);
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

fn iconCell(self: *Files, kit: *Kit, i: usize, cell: [2]f32, icon: u16) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const e = t.entry(i);
    const id = kit.print("item/{d}", .{i});
    const selected = t.selected.items[i];
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(cell[0] - 4),
        .height = .fixed(cell[1] - 4),
        .direction = .top_to_bottom,
        .padding = .all(4),
        .gap = 4,
        .align_x = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, selected, hovered),
        .border = itemBorder(self, kit, i, selected, hovered),
    });
    defer u.close();
    if (u.justPressed()) pressedOn(self, u, i);
    requests(self, u, id, i);
    if (self.check_boxes) {
        u.open(.{ .floating = .{ .attach = .parent, .offset = .{ .x = 4, .y = 4 }, .z_index = 2, .clip = .like_children } });
        checkBox(self, kit, i, hovered or selected);
        u.close();
    }
    u.open(.{ .width = .grow, .height = .fixed(@floatFromInt(icon)), .align_x = .center, .align_y = .bottom });
    // A picture as itself, made small, in the large views.
    if (!thumbnail(self, kit, i, icon)) icons.forEntry(self, kit, t.dirOf(e) orelse "/", e, icon);
    u.close();
    var style = kit.style(.caption, p.text_primary);
    style.alignment = .center;
    style.wrap = .words;
    u.open(.{ .width = .grow, .height = .grow, .clip = .both, .align_x = .center });
    nameOrField(self, kit, i, e, style);
    u.close();
}

/// A picture's own thumbnail where the system's cache has one: the
/// freedesktop thumbnail spec's, made by any app that showed it.
fn thumbnail(self: *Files, kit: *Kit, i: usize, size: u16) bool {
    if (size < 48 or self.prefs.always_icons) return false;
    const t = self.tab();
    const e = t.entry(i);
    if (!std.mem.startsWith(u8, e.mime, "image/") and !std.mem.startsWith(u8, e.mime, "video/")) return false;
    const dir = t.dirOf(e) orelse return false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, e.name }) catch return false;
    const s = self.window.scale;
    const box: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(size)) * s));
    const made = self.gallery.picture(full, box) orelse return false;
    kit.ui.empty(.{
        .width = .fixed(@as(f32, @floatFromInt(made.size[0])) / s),
        .height = .fixed(@as(f32, @floatFromInt(made.size[1])) / s),
        .image = .{ .texture = made.slot },
        // Windows 10 frames a photo with a thin line; 11 rounds it.
        .border = if (self.ten()) .{ .color = kit.theme.palette.divider, .width = .all(1) } else .{},
        .corner_radius = .all(if (self.ten()) 0 else 4),
    });
    return true;
}

fn smallCell(self: *Files, kit: *Kit, i: usize, cell: [2]f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const e = t.entry(i);
    const id = kit.print("item/{d}", .{i});
    const selected = t.selected.items[i];
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(cell[0] - 4),
        .height = .fixed(cell[1] - 2),
        .padding = .xy(6, 0),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, selected, hovered),
        .border = itemBorder(self, kit, i, selected, hovered),
        .clip = .both,
    });
    defer u.close();
    if (self.check_boxes) checkBox(self, kit, i, hovered or selected);
    if (u.justPressed()) pressedOn(self, u, i);
    requests(self, u, id, i);
    icons.forEntry(self, kit, t.dirOf(e) orelse "/", e, 16);
    var style = kit.style(.caption, p.text_primary);
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
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(cell[0] - 6),
        .height = .fixed(cell[1] - 6),
        .padding = .xy(8, 0),
        .gap = 10,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = itemFill(self, kit, selected, hovered),
        .border = itemBorder(self, kit, i, selected, hovered),
        .clip = .both,
    });
    defer u.close();
    if (self.check_boxes) checkBox(self, kit, i, hovered or selected);
    if (u.justPressed()) pressedOn(self, u, i);
    requests(self, u, id, i);
    if (!thumbnail(self, kit, i, 48)) icons.forEntry(self, kit, t.dirOf(e) orelse "/", e, 48);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 1, .clip = .both });
    defer u.close();
    var style = kit.style(.caption, p.text_primary);
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

// -------------------------------------------------------------------------
// Windows 11's Gallery
// -------------------------------------------------------------------------

/// A row of the Gallery: its photos, how tall, where it starts.
const PhotoRow = struct { first: usize, end: usize, h: f32, y: f32 };

const gallery_row = 180;
const gallery_gap = 4;
const timeline_w = 56;

/// A photo's width for its height, by what its first bytes said - or as
/// most photos are, until it is known.
fn aspectOf(e: *const Folder.Entry) f32 {
    if (e.pixels[0] == 0 or e.pixels[1] == 0) return 1.5;
    return std.math.clamp(@as(f32, @floatFromInt(e.pixels[0])) / @as(f32, @floatFromInt(e.pixels[1])), 0.25, 4);
}

/// The photos in rows as wide as the room, each row as tall as its photos'
/// shapes make it - Windows 11's Gallery's justified rows; the last row
/// left at its own height.
fn photoRows(t: *const Tab, width: f32, out: *std.ArrayList(PhotoRow), gpa: std.mem.Allocator) void {
    const n = t.count();
    var i: usize = 0;
    var y: f32 = 0;
    while (i < n) {
        var sum: f32 = 0;
        var j = i;
        while (j < n) : (j += 1) {
            sum += aspectOf(t.entry(j));
            const gaps: f32 = @floatFromInt((j - i) * gallery_gap);
            if (sum * gallery_row + gaps >= width) {
                j += 1;
                break;
            }
        }
        const gaps: f32 = @floatFromInt((j - i -| 1) * gallery_gap);
        const full = sum * gallery_row + gaps >= width;
        const h = if (full) (width - gaps) / sum else gallery_row;
        out.append(gpa, .{ .first = i, .end = j, .h = h, .y = y }) catch return;
        y += h + gallery_gap;
        i = j;
    }
}

fn monthOf(ns: i128, buffer: []u8) []const u8 {
    if (ns <= 0) return "";
    const seconds: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));
    var tm: Tm = undefined;
    if (localtime_r(&seconds, &tm) == null) return "";
    const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    return std.fmt.bufPrint(buffer, "{s} {d}", .{ months[@intCast(tm.mon)], @as(u32, @intCast(tm.year + 1900)) }) catch "";
}

fn yearOf(ns: i128) i32 {
    if (ns <= 0) return 0;
    const seconds: i64 = @intCast(@divFloor(ns, std.time.ns_per_s));
    var tm: Tm = undefined;
    if (localtime_r(&seconds, &tm) == null) return 0;
    return tm.year + 1900;
}

fn galleryView(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const id = "gallery/scroll";
    const View = struct { top: f32, height: f32, width: f32 };
    const view: View = blk: {
        const s = self.window.scale;
        const scroll = u.scrollOf(id) orelse break :blk .{ .top = 0, .height = @floatFromInt(self.window.height), .width = @as(f32, @floatFromInt(self.window.width)) - 300 };
        break :blk .{
            .top = scroll.position.y / s,
            .height = if (scroll.viewport.height > 0) scroll.viewport.height / s else @floatFromInt(self.window.height),
            .width = if (scroll.viewport.width > 0) scroll.viewport.width / s else @as(f32, @floatFromInt(self.window.width)) - 300,
        };
    };
    var rows: std.ArrayList(PhotoRow) = .empty;
    defer rows.deinit(self.gpa);
    photoRows(t, @max(200, view.width - 24), &rows, self.gpa);
    // What is in sight: its months, as the Gallery's head says them.
    var first_seen: ?usize = null;
    var last_seen: ?usize = null;
    for (rows.items) |r| if (r.y + r.h >= view.top and r.y <= view.top + view.height) {
        if (first_seen == null) first_seen = r.first;
        last_seen = r.end - 1;
    };
    {
        u.open(.{ .width = .grow, .height = .fixed(40), .padding = .trbl(10, 20, 6, 20), .align_y = .center });
        defer u.close();
        var style = kit.style(.body_strong, p.text_primary);
        style.wrap = .none;
        if (t.count() == 0) {
            u.text(if (self.searching()) "Gathering your photos\u{2026}" else "No photos here yet", style);
        } else if (first_seen) |f| {
            var a: [32]u8 = undefined;
            var b: [32]u8 = undefined;
            const from = monthOf(t.entry(f).mtime, &a);
            const to = monthOf(t.entry(last_seen.?).mtime, &b);
            if (std.mem.eql(u8, from, to)) u.text(kit.print("{s}", .{from}), style) else u.text(kit.print("{s} - {s}", .{ from, to }), style);
        }
    }
    u.open(.{ .width = .grow, .height = .grow });
    defer u.close();
    {
        u.open(.{
            .id = id,
            .width = .grow,
            .height = .grow,
            .direction = .top_to_bottom,
            .padding = .trbl(0, 4, 12, 20),
            .gap = gallery_gap,
            .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
        });
        defer u.close();
        defer if (self.context_at) |at| if (u.isPointerOver(id)) {
            t.selectNone();
            menus.openAt(self, at, false);
            self.context_at = null;
        };
        if (u.justPressed() and !overAnItem(self, u)) {
            if (!self.window.modifierHeld("Control")) t.selectNone();
        }
        var above: f32 = 0;
        var below: f32 = 0;
        for (rows.items) |r| {
            const in_sight = r.y + r.h >= view.top - 400 and r.y <= view.top + view.height + 400;
            if (!in_sight) {
                if (r.y < view.top) above += r.h + gallery_gap else below += r.h + gallery_gap;
                continue;
            }
            if (above > 0) {
                u.empty(.{ .width = .grow, .height = .fixed(above - gallery_gap) });
                above = 0;
            }
            u.open(.{ .height = .fixed(r.h), .gap = gallery_gap });
            defer u.close();
            for (r.first..r.end) |i| photoCell(self, kit, i, aspectOf(t.entry(i)) * r.h, r.h);
        }
        if (below > 0) u.empty(.{ .width = .grow, .height = .fixed(below) });
    }
    timeline(self, kit, t, rows.items, view.top, view.height);
}

/// A thumbnail's size, to the next of a few: a row a pixel taller or
/// shorter asks for the picture it has.
fn bucket(box: u32) u32 {
    for ([_]u32{ 128, 192, 256, 384 }) |b| if (box <= b) return b;
    return 512;
}

/// A photo of the Gallery: itself, or grey until it is made; chosen, the
/// accent around it and a tick at its corner.
fn photoCell(self: *Files, kit: *Kit, i: usize, w: f32, h: f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const e = t.entry(i);
    const id = kit.print("item/{d}", .{i});
    const selected = t.selected.items[i];
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(@floor(w)),
        .height = .fixed(h),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(4),
        .background_color = p.subtle_secondary,
        .border = if (selected) .{ .color = p.accent, .width = .all(3) } else if (hovered) .{ .color = p.text_primary.withAlpha(0.35), .width = .all(1) } else .{},
        .clip = .both,
    });
    defer u.close();
    if (u.justPressed()) pressedOn(self, u, i);
    requests(self, u, id, i);
    const dir = t.dirOf(e) orelse "/";
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = @import("Ops.zig").join(&buffer, dir, e.name) catch return;
    const s = self.window.scale;
    const box: u32 = @intFromFloat(@round(@max(w, h) * s));
    if (std.mem.startsWith(u8, e.mime, "image/")) {
        if (self.gallery.picture(full, bucket(box))) |made| {
            u.empty(.{ .width = .fixed(@floor(w)), .height = .fixed(h), .image = .{ .texture = made.slot }, .corner_radius = .all(4) });
        }
    } else {
        // A video: its kind's icon, and a play mark over it.
        icons.forEntry(self, kit, dir, e, 48);
    }
    if (selected or hovered) {
        u.open(.{
            .width = .fixed(20),
            .height = .fixed(20),
            .align_x = .center,
            .align_y = .center,
            .corner_radius = .all(10),
            .background_color = if (selected) p.accent else p.solid_base.withAlpha(0.8),
            .border = .{ .color = if (selected) p.accent else p.text_secondary, .width = .all(1) },
            .floating = .{ .attach = .parent, .offset = .{ .x = 8, .y = 8 }, .z_index = 2 },
            .passthrough = true,
        });
        if (selected) kit.icon(.checkmark, 12, p.text_on_accent, .regular);
        u.close();
    }
}

/// The timeline down the right, as the Gallery's: each year where its
/// photos begin, a tick each month; the pointer on it says which month,
/// and a click goes there.
fn timeline(self: *Files, kit: *Kit, t: *const Tab, rows: []const PhotoRow, top: f32, view_h: f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    if (rows.len == 0) return;
    const total = rows[rows.len - 1].y + rows[rows.len - 1].h;
    const id = "gallery/timeline";
    u.open(.{ .id = id, .width = .fixed(timeline_w), .height = .grow, .padding = .xy(0, 12) });
    defer u.close();
    const box = self.window.boxOf(id) orelse return;
    const usable = @max(1, box.height - 24);
    // Where the view is: a bar along it.
    u.empty(.{
        .width = .fixed(3),
        .height = .fixed(@max(12, usable * @min(1, view_h / @max(1, total)))),
        .corner_radius = .all(2),
        .background_color = p.accent,
        .floating = .{ .attach = .parent, .offset = .{ .x = timeline_w - 8, .y = 12 + usable * (top / @max(1, total)) } },
        .passthrough = true,
    });
    var last_year: i32 = 0;
    var last_month: [32]u8 = undefined;
    var last_month_len: usize = 0;
    for (rows) |r| {
        const e = t.entry(r.first);
        const y = 12 + usable * (r.y / total);
        const year = yearOf(e.mtime);
        if (year != last_year and year != 0) {
            last_year = year;
            u.open(.{ .floating = .{ .attach = .parent, .offset = .{ .x = 4, .y = y - 6 } }, .passthrough = true });
            kit.label(kit.print("{d}", .{year}), .caption, p.text_secondary);
            u.close();
        }
        var buffer: [32]u8 = undefined;
        const month = monthOf(e.mtime, &buffer);
        if (!std.mem.eql(u8, month, last_month[0..last_month_len])) {
            last_month_len = @min(month.len, last_month.len);
            @memcpy(last_month[0..last_month_len], month[0..last_month_len]);
            u.empty(.{ .width = .fixed(4), .height = .fixed(4), .corner_radius = .all(2), .background_color = p.text_tertiary, .floating = .{ .attach = .parent, .offset = .{ .x = timeline_w - 8, .y = y } }, .passthrough = true });
        }
    }
    // The pointer on it: which month that is, and a click goes there.
    if (!u.isPointerOver(id)) return;
    const at = self.window.pointer_at orelse return;
    const fraction = std.math.clamp((at[1] - box.y - 12) / usable, 0, 1);
    const want = fraction * total;
    var row = rows[0];
    for (rows) |r| if (r.y <= want) {
        row = r;
    };
    var buffer: [32]u8 = undefined;
    const month = monthOf(t.entry(row.first).mtime, &buffer);
    u.open(.{
        .padding = .xy(8, 4),
        .corner_radius = .all(4),
        .background_color = p.flyout,
        .border = .{ .color = p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.tooltip),
        .floating = .{ .attach = .root, .offset = .{ .x = box.x - 120, .y = at[1] - 12 }, .z_index = 60 },
        .passthrough = true,
    });
    kit.label(kit.print("{s}", .{month}), .caption, p.text_primary);
    u.close();
    if (u.justPressed()) u.scrollTo("gallery/scroll", 0, row.y * self.window.scale);
}

// -------------------------------------------------------------------------
// The rubber band
// -------------------------------------------------------------------------

/// Dragged from where there was no item: everything it touches chosen -
/// added to what was, with Ctrl - and the band drawn over the list.
fn rubberBand(self: *Files, kit: *Kit) void {
    const from = self.band_from orelse return;
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    if (!self.window.down) {
        self.band_from = null;
        return;
    }
    const at = self.window.pointer_at orelse return;
    const x0 = @min(from[0], at[0]);
    const y0 = @min(from[1], at[1]);
    const x1 = @max(from[0], at[0]);
    const y1 = @max(from[1], at[1]);
    // A drag of a few pixels is still a click.
    if (x1 - x0 < 4 and y1 - y0 < 4) return;
    var buffer: [32]u8 = undefined;
    for (0..t.count()) |i| {
        const base = if (i < self.band_base.items.len) self.band_base.items[i] else false;
        const id = std.fmt.bufPrint(&buffer, "item/{d}", .{i}) catch continue;
        const box = self.window.boxOf(id) orelse {
            t.selected.items[i] = base;
            continue;
        };
        const touches = box.x < x1 and box.x + box.width > x0 and box.y < y1 and box.y + box.height > y0;
        t.selected.items[i] = base or touches;
    }
    const ten = self.ten();
    const edge = if (ten) widgets.argb(0xFF3399FF) else p.accent;
    u.empty(.{
        .width = .fixed(x1 - x0),
        .height = .fixed(y1 - y0),
        .background_color = edge.withAlpha(0.25),
        .border = .{ .color = edge, .width = .all(1) },
        .corner_radius = .all(if (ten) 0 else 2),
        .floating = .{ .attach = .root, .offset = .{ .x = x0, .y = y0 }, .z_index = 40 },
        .passthrough = true,
    });
}

// -------------------------------------------------------------------------
// What went wrong
// -------------------------------------------------------------------------

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
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .words;
    u.text(text, style);
    u.close();
    if (kit.button("notice/close", "", .{ .kind = .subtle, .icon = .dismiss })) self.notice_len = 0;
}

// -------------------------------------------------------------------------
// Home, and This PC
// -------------------------------------------------------------------------

/// A section's heading, as a group's: Windows 11's with a chevron,
/// Windows 10's blue with a line after it.
fn section(self: *Files, kit: *Kit, title: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    u.open(.{ .width = .grow, .padding = .trbl(if (ten) 10 else 16, 8, if (ten) 6 else 8, 8), .gap = 8, .align_y = .center });
    defer u.close();
    if (!ten) kit.icon(.chevron_down, 12, p.text_secondary, .regular);
    const blue = if (p.mode == .dark) widgets.argb(0xFF6CB4F2) else widgets.argb(0xFF1E3287);
    var style = kit.style(if (ten) .body else .body_strong, if (ten) blue else p.text_primary);
    style.wrap = .none;
    u.text(title, style);
    if (ten) u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = if (p.mode == .dark) widgets.argb(0xFF3C3C3C) else widgets.argb(0xFFE2E2E2) });
}

/// A place as a tile: its icon, its name, and a line under it.
fn placeTile(self: *Files, kit: *Kit, id: []const u8, icon_name: []const u8, name: []const u8, line: []const u8, pinned: bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const lit = self.page_chosen != null and std.mem.eql(u8, self.page_chosen_buffer[0..self.page_chosen_len], id);
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(if (ten) 250 else 260),
        .height = .fixed(if (ten) 56 else 64),
        .padding = .xy(10, 0),
        .gap = 12,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = itemFill(self, kit, lit, hovered),
        .border = if (ten and (lit or hovered)) .{ .color = if (lit) win10Edge(kit) else win10.hoverColor(kit), .width = .all(1) } else .{},
    });
    defer u.close();
    icons.themed(self, kit, icon_name, if (ten) 48 else 32);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2, .clip = .both });
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.text(name, style);
    var small = kit.style(.caption, p.text_secondary);
    small.wrap = .none;
    u.text(line, small);
    if (ten and pinned) kit.icon(.pin, 10, p.text_secondary, .regular);
    u.close();
    if (pinned and !ten) kit.icon(.pin, 12, p.text_secondary, .regular);
    // A click chooses it, a double click goes there.
    if (u.justPressed()) {
        if (self.window.clickCount() >= 2) return true;
        self.choosePageItem(id);
    }
    return false;
}

fn homePage(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const ten = self.ten();
    self.history.refresh(self.io);
    u.open(.{ .id = scroll_id, .width = .grow, .height = .grow, .direction = .top_to_bottom, .padding = .xy(12, 4), .clip = scrollClip(kit) });
    defer u.close();
    var to: ?[]const u8 = null;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    // Gone to often, and not shown already: the frequent folders.
    var frequent_buffer: [History.most_frequent]History.Frequent = undefined;
    const frequent = if (self.prefs.show_frequent) self.history.topFolders(&frequent_buffer, shownAlready, self) else &.{};
    const tiles = self.places.user.items.len + self.places.pinned.items.len + frequent.len;
    if (ten) section(self, kit, kit.print("Frequent folders ({d})", .{tiles})) else section(self, kit, "Quick access");
    {
        u.open(.{ .width = .grow, .wrap = true, .gap = 4, .wrap_gap = 4, .padding = .xy(8, 0) });
        defer u.close();
        for (self.places.user.items, 0..) |f, i| {
            if (placeTile(self, kit, kit.print("home/user/{d}", .{i}), icons.special(f.special), f.name, if (ten) "This PC" else "Stored locally", true)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch null;
            drag.answerFolder(self, u, kit.print("home/user/{d}", .{i}), f.path);
        }
        for (self.places.pinned.items, 0..) |f, i| {
            if (placeTile(self, kit, kit.print("home/pin/{d}", .{i}), "folder", f.name, std.fs.path.dirname(f.path) orelse "/", true)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch null;
            drag.answerFolder(self, u, kit.print("home/pin/{d}", .{i}), f.path);
        }
        for (frequent, 0..) |f, i| {
            const id = kit.print("home/frequent/{d}", .{i});
            if (placeTile(self, kit, id, "folder", std.fs.path.basename(f.path), std.fs.path.dirname(f.path) orelse "/", false)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch null;
            drag.answerFolder(self, u, id, f.path);
            homeMenuOn(self, u, id, f.path, .frequent);
        }
    }
    if (!ten and self.prefs.show_favorites) {
        section(self, kit, "Favorites");
        if (self.history.favorites.items.len == 0) {
            emptyNote(kit, "After you've favorited some files, we'll show them here.");
        } else {
            fileHeader(self, kit);
            for (self.history.favorites.items, 0..) |path, i| {
                const mime = self.mime.byName(std.fs.path.basename(path)) orelse "application/octet-stream";
                fileRow(self, kit, kit.print("home/favorite/{d}", .{i}), path, mime, .favorite);
            }
        }
    }
    if (self.prefs.show_recent) {
        const recent = self.history.recent;
        section(self, kit, if (ten) kit.print("Recent files ({d})", .{recent.len}) else "Recent");
        if (recent.len == 0) {
            emptyNote(kit, "After you've opened some files, we'll show the most recent ones here.");
        } else {
            if (!ten) fileHeader(self, kit);
            for (recent, 0..) |f, i| {
                const mime = if (f.mime.len > 0) f.mime else self.mime.byName(f.name) orelse "application/octet-stream";
                fileRow(self, kit, kit.print("home/recent/{d}", .{i}), f.path, mime, .recent);
            }
        }
    }
    if (to) |path| self.goTo(.{ .folder = path });
}

/// A folder Home shows as a tile already: one of the person's, or pinned.
fn shownAlready(context: *const anyopaque, path: []const u8) bool {
    const self: *const Files = @ptrCast(@alignCast(context));
    for (self.places.user.items) |f| if (std.mem.eql(u8, f.path, path)) return true;
    if (self.places.isPinned(path)) return true;
    return std.mem.eql(u8, path, self.places.home);
}

/// Windows 11's heads over Home's lists: Name, Date modified, File location.
fn fileHeader(self: *Files, kit: *Kit) void {
    _ = self;
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .height = .fixed(28), .padding = .xy(16, 0), .align_y = .center });
    defer u.close();
    var style = kit.style(.caption, p.text_secondary);
    style.wrap = .none;
    u.open(.{ .width = .growWith(.{ .min = 160 }) });
    u.text("Name", style);
    u.close();
    u.open(.{ .width = .fixedDownTo(150, 90) });
    u.text("Date modified", style);
    u.close();
    u.open(.{ .width = .fixedDownTo(280, 120), .clip = .both });
    u.text("File location", style);
    u.close();
}

/// A file of Home's lists: its icon, its name, when it changed, where it is
/// - Windows 10's with only where, grey, at the right. A click chooses it,
/// a double click opens it, a right click has its menu.
fn fileRow(self: *Files, kit: *Kit, id: []const u8, path: []const u8, mime: []const u8, kind: Files.HomeKind) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const lit = self.page_chosen != null and std.mem.eql(u8, self.page_chosen_buffer[0..self.page_chosen_len], id);
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(if (ten) 24 else 32),
        .padding = .xy(if (ten) 8 else 16, 0),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = itemFill(self, kit, lit, hovered),
        .border = if (ten and (lit or hovered)) .{ .color = if (lit) win10Edge(kit) else win10.hoverColor(kit), .width = .all(1) } else .{},
    });
    defer u.close();
    var name_style = kit.style(.caption, p.text_primary);
    name_style.wrap = .none;
    var small = kit.style(.caption, p.text_secondary);
    small.wrap = .none;
    const dir = std.fs.path.dirname(path) orelse "/";
    {
        u.open(.{ .width = .growWith(.{ .min = 160 }), .gap = 8, .align_y = .center, .clip = .both });
        defer u.close();
        @import("panes.zig").fileIcon(self, kit, std.fs.path.basename(path), 16);
        u.text(std.fs.path.basename(path), name_style);
        if (!ten and kind == .favorite) kit.icon(.star, 12, p.accent, .filled);
    }
    if (!ten) {
        var date_buffer: [32]u8 = undefined;
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch null;
        u.open(.{ .width = .fixedDownTo(150, 90), .clip = .both });
        u.text(kit.print("{s}", .{if (stat) |st| dateText(st.mtime.nanoseconds, &date_buffer) else ""}), small);
        u.close();
    }
    u.open(.{ .width = .fixedDownTo(280, 120), .clip = .both });
    u.text(kit.print("{s}", .{dir}), small);
    u.close();
    if (u.justPressed()) {
        if (self.window.clickCount() >= 2) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const copy = std.fmt.bufPrint(&buffer, "{s}", .{path}) catch return;
            self.openFile(copy, mime);
        } else self.choosePageItem(id);
    }
    homeMenuOn(self, u, id, path, kind);
}

/// A right click on a thing of Home's: its own menu - open, go to where it
/// is, star it, take it off the list.
fn homeMenuOn(self: *Files, u: *ui.Ui, id: []const u8, path: []const u8, kind: Files.HomeKind) void {
    const at = self.context_at orelse return;
    if (!u.isPointerOver(id)) return;
    self.choosePageItem(id);
    self.home_target_len = @min(path.len, self.home_target_buffer.len);
    @memcpy(self.home_target_buffer[0..self.home_target_len], path[0..self.home_target_len]);
    self.home_kind = kind;
    menus.openAt(self, at, true);
    self.context_at = null;
}

fn emptyNote(kit: *Kit, text: []const u8) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .padding = .trbl(4, 16, 8, 32) });
    defer u.close();
    kit.label(text, .caption, kit.theme.palette.text_secondary);
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
        section(self, kit, kit.print("Folders ({d})", .{self.places.user.items.len}));
        u.open(.{ .width = .grow, .wrap = true, .gap = 4, .wrap_gap = 4, .padding = .xy(8, 0) });
        for (self.places.user.items, 0..) |f, i| {
            if (placeTile(self, kit, kit.print("pc/user/{d}", .{i}), icons.special(f.special), f.name, "", false)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch null;
            drag.answerFolder(self, u, kit.print("pc/user/{d}", .{i}), f.path);
        }
        u.close();
    }
    section(self, kit, kit.print("Devices and drives ({d})", .{self.places.drives.items.len}));
    u.open(.{ .width = .grow, .wrap = true, .gap = 4, .wrap_gap = 4, .padding = .xy(8, 0) });
    for (self.places.drives.items, 0..) |d, i| {
        // Folder Options' "Hide empty drives": a drive with nothing in it.
        if (self.prefs.hide_empty_drives and d.size == 0) continue;
        if (driveTile(self, kit, kit.print("pc/drive/{d}", .{i}), d)) to = std.fmt.bufPrint(&to_buffer, "{s}", .{d.mount}) catch null;
        drag.answerFolder(self, u, kit.print("pc/drive/{d}", .{i}), d.mount);
    }
    u.close();
    if (to) |path| self.goTo(.{ .folder = path });
}

/// A drive: its icon, its name, how full it is as a bar - red past nine
/// tenths, as Windows warns - and "X GB free of Y GB".
fn driveTile(self: *Files, kit: *Kit, id: []const u8, d: Places.Drive) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const lit = self.page_chosen != null and std.mem.eql(u8, self.page_chosen_buffer[0..self.page_chosen_len], id);
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(300),
        .height = .fixed(if (ten) 64 else 72),
        .padding = .xy(10, 0),
        .gap = 12,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = itemFill(self, kit, lit, hovered),
        .border = if (ten and (lit or hovered)) .{ .color = if (lit) win10Edge(kit) else win10.hoverColor(kit), .width = .all(1) } else .{},
    });
    defer u.close();
    icons.themed(self, kit, if (d.removable) "drive-removable-media" else "drive-harddisk", 48);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 4, .clip = .both });
    defer u.close();
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.text(kit.print("{s} ({s})", .{ d.label, d.mount }), style);
    const used: f32 = if (d.size > 0) @as(f32, @floatFromInt(d.size - d.free)) / @as(f32, @floatFromInt(d.size)) else 0;
    // Windows 10's bar is a framed light grey, filled blue; Windows 11's a
    // thin rounded one in the accent.
    u.open(.{ .width = .grow, .height = .fixed(if (ten) 14 else 6), .corner_radius = .all(if (ten) 0 else 3), .background_color = if (ten) (if (p.mode == .dark) widgets.argb(0xFF3C3C3C) else widgets.argb(0xFFE6E6E6)) else p.control_alt_secondary, .border = if (ten) .{ .color = if (p.mode == .dark) widgets.argb(0xFF5A5A5A) else widgets.argb(0xFFBCBCBC), .width = .all(1) } else .{} });
    u.empty(.{ .width = .percent(used), .height = .grow, .corner_radius = .all(if (ten) 0 else 3), .background_color = if (used > 0.9) (if (ten) widgets.argb(0xFFDA2626) else p.critical) else if (ten) widgets.argb(0xFF26A0DA) else p.accent });
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
