// SPDX-License-Identifier: BSD-2-Clause

//! Files dragged and dropped, as Windows' file manager has them.
//!
//! **Out:** pressed on an item and moved a few pixels with the button down,
//! what is chosen is dragged - its icon under the pointer, with how many
//! there are - to wherever the pointer lets go: a folder here, another tab
//! (held over it a moment, it comes to the front), another window, the
//! desktop, any app.
//!
//! **In:** what is dropped goes into the folder under the pointer - a
//! folder in the list, one in the navigation pane, a part of the address,
//! a place on Home or This PC - or else into the folder shown; on the
//! Recycle Bin, into it. Within one drive it is moved, between drives
//! copied, as Windows does; Ctrl copies, Shift moves. Dropped where it
//! already is, nothing happens.

const std = @import("std");

const ui = @import("fluxion_ui");
const raster = @import("fluxion_ui_raster");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const Window = @import("Window.zig");
const Ops = @import("Ops.zig");
const actions = @import("actions.zig");
const icons = @import("icons.zig");

const Dnd = Window.Dnd;

/// Moved this far with the button down, a press on an item is a drag.
const drag_distance = 6;

/// Held this long over a tab, the drag brings it to the front.
const tab_hold_ms = 700;

/// The path a drop on the Recycle Bin is answered with.
pub const trash_path = "trash:";

/// A press on item `i`: a drag, if the pointer moves far enough before the
/// button comes up.
pub fn pressed(self: *Files, i: usize) void {
    const at = self.window.pointer_at orelse return;
    self.drag_press = .{ .at = at, .item = i };
}

/// Each drawing: a press moved far enough is a drag of what is chosen.
pub fn follow(self: *Files, kit: *Kit) void {
    const press = self.drag_press orelse return;
    if (!self.window.down or self.renaming != null) {
        self.drag_press = null;
        return;
    }
    const at = self.window.pointer_at orelse return;
    if (@abs(at[0] - press.at[0]) + @abs(at[1] - press.at[1]) < drag_distance) return;
    self.drag_press = null;
    self.rename_pending = null;
    const t = self.tab();
    if (press.item >= t.count()) return;
    if (!t.selected.items[press.item]) t.click(press.item, false, false);

    for (self.dragged.items) |p| self.gpa.free(p);
    self.dragged.clearRetainingCapacity();
    for (t.selected.items, 0..) |chosen, i| {
        if (!chosen) continue;
        const e = t.entry(i);
        const dir = t.dirOf(e) orelse continue;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = Ops.join(&buffer, dir, e.name) catch continue;
        self.dragged.append(self.gpa, self.gpa.dupe(u8, full) catch continue) catch {};
    }
    if (self.dragged.items.len == 0) return;
    const pic = picture(self, kit, press.item, self.dragged.items.len);
    defer if (pic) |p| self.gpa.free(p.pixels);
    var paths: [256][]const u8 = undefined;
    const n = @min(paths.len, self.dragged.items.len);
    for (self.dragged.items[0..n], 0..) |p, i| paths[i] = p;
    self.window.startDrag(paths[0..n], pic);
}

/// What is dragged, as Windows shows it: the first one's icon, large, and
/// how many there are in a badge at its corner.
fn picture(self: *Files, kit: *Kit, item: usize, count: usize) ?raster.Image {
    const size: u32 = 96;
    var layout: ui.Ui = .init(self.gpa);
    defer layout.deinit();
    layout.setMeasurer(self.window.fonts.measurer());
    var drawing: Kit = .init(&layout, kit.theme);
    layout.begin(.{ .size = .init(@floatFromInt(size), @floatFromInt(size)) });
    {
        layout.open(.{ .width = .grow, .height = .grow, .align_x = .center, .align_y = .center, .opacity = 0.9 });
        defer layout.close();
        const t = self.tab();
        const e = t.entry(item);
        icons.forEntry(self, &drawing, t.dirOf(e) orelse "/", e, 64);
        if (count > 1) {
            const p = &kit.theme.palette;
            layout.open(.{
                .padding = .xy(7, 2),
                .corner_radius = .all(10),
                .background_color = p.accent,
                .floating = .{ .attach = .parent, .anchor = .{ .element_x = .right, .element_y = .top, .parent_x = .right, .parent_y = .top }, .offset = .{ .x = -6, .y = 6 } },
            });
            drawing.label(drawing.print("{d}", .{count}), .caption, p.text_on_accent);
            layout.close();
        }
    }
    const commands = layout.end() catch return null;
    const pixels = self.gpa.alloc(u32, size * size) catch return null;
    @memset(pixels, 0);
    self.window.painter.setImages(self.window.icons.images.items);
    self.window.painter.draw(.init(pixels, size, size), commands, .transparent) catch {
        self.gpa.free(pixels);
        return null;
    };
    return .{ .pixels = pixels, .width = size, .height = size };
}

// -------------------------------------------------------------------------
// Where a drop goes
// -------------------------------------------------------------------------

/// Drawing the element `id` - a folder at `path` - with a drag over it:
/// a drop there goes into it.
pub fn answerFolder(self: *Files, u: *ui.Ui, id: []const u8, path: []const u8) void {
    if (!self.window.dragOver() or !u.isPointerOver(id)) return;
    self.window.answerDrop(actionFor(self, path), path);
}

/// The Recycle Bin's own element `id`: a drop there deletes.
pub fn answerTrash(self: *Files, u: *ui.Ui, id: []const u8) void {
    if (!self.window.dragOver() or !u.isPointerOver(id)) return;
    // What is in it already stays.
    for (self.dragged.items) |p| if (self.window.dnd.dragging() and isTrashed(p)) return;
    self.window.answerDrop(.move, trash_path);
}

/// A drag held over tab `index`: in front, once it has been a moment.
pub fn overTab(self: *Files, u: *ui.Ui, id: []const u8, index: usize) void {
    if (!self.window.dragOver() or !u.isPointerOver(id)) {
        if (self.drag_tab == index) self.drag_tab = null;
        return;
    }
    if (index == self.active) return;
    const now = Window.nowMs();
    if (self.drag_tab != index) {
        self.drag_tab = index;
        self.drag_tab_since = now;
        self.window.wakeAt(now + tab_hold_ms);
        return;
    }
    if (now - self.drag_tab_since >= tab_hold_ms) {
        self.drag_tab = null;
        self.switchTab(index);
    }
}

fn isTrashed(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "/.local/share/Trash/") != null or std.mem.indexOf(u8, path, "/.Trash-") != null;
}

/// What a drop into `to` does with what is dragged: Windows' rule - moved
/// within a drive, copied between drives - unless Ctrl or Shift says; and
/// nothing where it already is, or into itself.
pub fn actionFor(self: *Files, to: []const u8) Dnd.Action {
    const ctrl = self.window.modifierHeld("Control");
    const shift = self.window.modifierHeld("Shift");
    // From another program: what it dragged, once it has been read; until
    // then, copied unless Shift says move.
    const dragged: []const []const u8 = if (self.window.dnd.dragging()) @ptrCast(self.dragged.items) else self.window.dnd.paths() orelse return if (shift) .move else .copy;
    if (dragged.len == 0) return .none;
    var all_here = true;
    for (dragged) |p| {
        if (Ops.isInside(to, p)) return .none;
        if (!std.mem.eql(u8, std.fs.path.dirname(p) orelse "/", to)) all_here = false;
    }
    if (all_here) return if (ctrl) .copy else .none;
    if (ctrl) return .copy;
    if (shift) return .move;
    const from_device = Ops.deviceOf(dragged[0]);
    const to_device = Ops.deviceOf(to);
    if (from_device != null and to_device != null and from_device.? == to_device.?) return .move;
    return .copy;
}

/// Beside the pointer, while a drag is over the window: what a drop there
/// would do - "Move to Projects", "Copy to Pictures" - as Windows says it.
pub fn tip(self: *Files, kit: *Kit) void {
    if (!self.window.dragOver()) return;
    const at = self.window.pointer_at orelse return;
    const answer = &self.window.dnd.answer;
    if (answer.action == .none) return;
    const u = kit.ui;
    const p = &kit.theme.palette;
    const to = answer.path();
    const name = if (std.mem.eql(u8, to, trash_path)) "Recycle Bin" else if (std.mem.eql(u8, to, "/")) self.places.rootName() else std.fs.path.basename(to);
    const verb = if (std.mem.eql(u8, to, trash_path)) "Move to" else if (answer.action == .move) "Move to" else "Copy to";
    u.open(.{
        .padding = .xy(6, 3),
        .gap = 4,
        .align_y = .center,
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .background_color = p.solid_base,
        .border = .{ .color = p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.tooltip),
        .floating = .{ .attach = .root, .offset = .{ .x = at[0] + 18, .y = at[1] + 22 }, .z_index = 120 },
        .passthrough = true,
    });
    defer u.close();
    kit.icon(if (answer.action == .copy) .add else .arrow_right, 12, if (self.ten()) widgets.argb(0xFF1979CA) else p.accent, .regular);
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.text(kit.print("{s} {s}", .{ verb, name }), style);
}

// -------------------------------------------------------------------------
// The drop
// -------------------------------------------------------------------------

/// Files dropped on the window, where and as it answered.
pub fn dropped(context: *anyopaque, window: *Window, paths: []const []const u8, answer: Dnd.Answer) void {
    _ = window;
    const self: *Files = @ptrCast(@alignCast(context));
    const to = answer.path();
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| self.gpa.free(n);
        names.deinit(self.gpa);
    }
    var failed: ?anyerror = null;
    for (paths) |p| {
        if (std.mem.eql(u8, to, trash_path)) {
            Ops.trash(self.io, p) catch |err| {
                failed = err;
            };
            continue;
        }
        // Into itself, or moved where it is: nothing.
        if (Ops.isInside(to, p)) continue;
        const here = std.mem.eql(u8, std.fs.path.dirname(p) orelse "/", to);
        if (here and answer.action == .move) continue;
        var buffer: [512]u8 = undefined;
        const name = (if (answer.action == .move) Ops.moveInto(self.io, p, to, &buffer) else Ops.copyInto(self.io, p, to, &buffer)) catch |err| {
            failed = err;
            continue;
        };
        names.append(self.gpa, self.gpa.dupe(u8, name) catch continue) catch {};
    }
    if (failed) |err| self.notify(if (answer.action == .move) "Some items could not be moved" else "Some items could not be copied", err);
    self.refreshAll();
    // Dropped into the folder shown: what came, chosen.
    if (self.tab().path()) |shown| if (std.mem.eql(u8, shown, to)) {
        var just: [256][]const u8 = undefined;
        const n = @min(just.len, names.items.len);
        for (names.items[0..n], 0..) |name, i| just[i] = name;
        actions.choose(self, just[0..n]);
    };
}

test "a drop where things already are does nothing, into themselves nothing either" {
    try std.testing.expect(Ops.isInside("/a/b/c", "/a/b"));
    try std.testing.expect(!Ops.isInside("/a/bc", "/a/b"));
    try std.testing.expect(isTrashed("/home/p/.local/share/Trash/files/x"));
}
