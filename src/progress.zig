// SPDX-License-Identifier: BSD-2-Clause

//! The dialogs of what is being done to files, as Windows draws them:
//!
//! - **the progress dialog**: "Copying 911 items from Articles to Copy",
//!   how far along, pause and cancel; with "More details" the speed as a
//!   graph over the part done - Windows 10's green, Windows 11's in the
//!   accent - the name of the file, the time and the items left. More
//!   than one job: one under another, as Windows lists them. It comes
//!   once a job has gone on for a moment - a quick copy shows nothing -
//!   and goes when they are all done; its title bar moves it, and its
//!   minimise button folds it into the status bar.
//! - **"Replace or Skip Files"**: names taken where the files go - replace
//!   them, skip them, or decide for each, file by file, which to keep;
//!   both kept, the new one is numbered.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;

const Files = @import("Files.zig");
const Jobs = @import("Jobs.zig");
const Folder = @import("Folder.zig");
const views = @import("views.zig");
const panes = @import("panes.zig");
const icons = @import("icons.zig");

/// A job is shown once it has run this long.
const shown_after_ms = 600;
const dialog_w = 466;
const graph_h = 64;

/// Windows 10's green, and the paler green of the part done.
fn green(kit: *Kit) Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF16C60C) else widgets.argb(0xFF06B025);
}

fn ink(self: *Files, kit: *Kit) Color {
    return if (self.ten()) green(kit) else kit.theme.palette.accent;
}

/// The dialogs, over the window: the question first, if a job asks one.
pub fn draw(self: *Files, kit: *Kit) void {
    const jobs = &self.jobs;
    jobs.lock();
    defer jobs.unlock();
    const now = Jobs.nowMs();
    var shown: [8]*Jobs.Job = undefined;
    var n: usize = 0;
    var asking: ?*Jobs.Job = null;
    var soonest: i64 = 0;
    for (jobs.list.items) |j| {
        if (j.finished()) continue;
        if (j.state == .asking and !j.answered and asking == null) asking = j;
        if (now - j.started_ms < shown_after_ms and j.state != .asking) {
            const due = j.started_ms + shown_after_ms;
            if (soonest == 0 or due < soonest) soonest = due;
            continue;
        }
        if (n < shown.len) {
            shown[n] = j;
            n += 1;
        }
    }
    if (soonest != 0) self.window.wakeAt(soonest);
    if (n > 0) {
        // Drawn again as the work goes on, for the bar and the time.
        self.window.wakeAt(now + 250);
        if (!self.progress_folded) dialog(self, kit, shown[0..n], now);
    }
    if (asking) |j| {
        if (self.deciding == j.id) decide(self, kit, j) else question(self, kit, j);
    }
}

// -------------------------------------------------------------------------
// The progress dialog
// -------------------------------------------------------------------------

fn dialog(self: *Files, kit: *Kit, shown: []const *Jobs.Job, now: i64) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const w: f32 = @floatFromInt(self.window.width);
    const h: f32 = @floatFromInt(self.window.height);
    const box = self.window.boxOf("progress");
    const bw = if (box) |b| b.width else dialog_w;
    const bh = if (box) |b| b.height else 260;
    // Where it was moved to, kept on the window; centred at first.
    var at = self.progress_at orelse .{ (w - bw) / 2, (h - bh) / 2 };
    at[0] = std.math.clamp(at[0], 0, @max(0, w - bw));
    at[1] = std.math.clamp(at[1], 0, @max(0, h - bh));
    u.open(.{
        .id = "progress",
        .width = .fixed(dialog_w),
        .direction = .top_to_bottom,
        .corner_radius = .all(if (ten) 0 else 8),
        .background_color = p.solid_base,
        .border = .{ .color = if (ten) green(kit) else p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .floating = .{ .attach = .root, .offset = .{ .x = at[0], .y = at[1] }, .z_index = 92 },
        .clip = .both,
    });
    defer u.close();
    // Its title bar: what it is, and minimise and close.
    {
        const title_id = "progress/title";
        u.open(.{ .id = title_id, .width = .grow, .height = .fixed(32), .padding = .trbl(0, 0, 0, 12), .gap = 8, .align_y = .center });
        defer u.close();
        kit.icon(.copy, 14, if (ten) green(kit) else p.accent, .regular);
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .none;
        u.open(.{ .width = .grow, .clip = .both });
        if (shown.len == 1) {
            u.text(kit.print("{d}% complete", .{percent(shown[0])}), style);
        } else u.text(kit.print("{d} Items running", .{shown.len}), style);
        u.close();
        // Dragged by its title, it moves.
        if (u.justPressed() and !u.isPointerOver("progress/min") and !u.isPointerOver("progress/close")) if (self.window.pointer_at) |ptr| {
            self.progress_drag = .{ ptr[0] - at[0], ptr[1] - at[1] };
        };
        if (captionButton(self, kit, "progress/min", .subtract, false)) self.progress_folded = true;
        if (captionButton(self, kit, "progress/close", .dismiss, true)) for (shown) |j| Jobs.cancel(j);
    }
    if (self.progress_drag) |grab| {
        if (!self.window.down) self.progress_drag = null else if (self.window.pointer_at) |ptr| {
            self.progress_at = .{ ptr[0] - grab[0], ptr[1] - grab[1] };
        }
    }
    for (shown, 0..) |j, k| {
        if (k > 0) u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = p.divider });
        operation(self, kit, j, now);
    }
    // More or fewer details.
    {
        u.open(.{
            .width = .grow,
            .padding = .xy(16, 10),
            .background_color = if (ten) (if (p.mode == .dark) widgets.argb(0xFF2B2B2B) else widgets.argb(0xFFF0F0F0)) else p.solid_secondary,
            .border = .{ .color = p.divider, .width = .{ .top = 1 } },
        });
        defer u.close();
        const id = "progress/details";
        u.open(.{ .id = id, .gap = 8, .align_y = .center, .padding = .xy(2, 2) });
        defer u.close();
        u.open(.{ .width = .fixed(20), .height = .fixed(20), .corner_radius = .all(10), .align_x = .center, .align_y = .center, .border = .{ .color = if (u.isPointerOver(id)) p.accent else p.text_secondary, .width = .all(1) } });
        kit.icon(if (self.progress_more) .chevron_up else .chevron_down, 10, p.text_primary, .regular);
        u.close();
        kit.label(if (self.progress_more) "Fewer details" else "More details", .caption, p.text_primary);
        if (u.justReleased()) self.progress_more = !self.progress_more;
    }
}

fn percent(j: *const Jobs.Job) u32 {
    return @intFromFloat(@floor(j.fraction() * 100));
}

/// A button of the dialog's title bar: minimise, or close - red under the
/// pointer, as a window's is.
fn captionButton(self: *Files, kit: *Kit, id: []const u8, glyph: widgets.icons.Name, close: bool) bool {
    _ = self;
    const u = kit.ui;
    const p = &kit.theme.palette;
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .fixed(46),
        .height = .grow,
        .align_x = .center,
        .align_y = .center,
        .background_color = if (hovered) (if (close) p.close_hover else p.subtle_secondary) else .transparent,
    });
    kit.icon(glyph, 10, if (hovered and close) widgets.argb(0xFFFFFFFF) else p.text_primary, .regular);
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

/// What one job says: what it does, from where to where; how far; its
/// pause and cancel; the graph or the bar; and, with more details, the
/// file, the time and the items left.
fn operation(self: *Files, kit: *Kit, j: *Jobs.Job, now: i64) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .trbl(10, 20, 14, 20), .gap = 6 });
    defer u.close();
    {
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .none;
        u.open(.{ .width = .grow, .gap = 4, .clip = .both });
        defer u.close();
        const items = j.total_items;
        const verb = switch (j.kind) {
            .copy => "Copying",
            .move => "Moving",
            .trash => "Moving",
            .delete => "Deleting",
            .extract => "Extracting",
            .compress => "Compressing",
        };
        const from = folderName(j.sources[0]);
        const to = if (j.kind == .trash) "Recycle Bin" else if (j.kind == .compress) std.fs.path.basename(j.dest) else std.fs.path.basename(j.dest);
        u.text(kit.print("{s} {d} item{s} from", .{ verb, items, if (items == 1) "" else "s" }), style);
        var link = style;
        link.color = if (p.mode == .dark) widgets.argb(0xFF6CB4F2) else widgets.argb(0xFF0066CC);
        u.text(kit.print("{s}", .{from}), link);
        if (j.kind != .delete) {
            u.text("to", style);
            u.text(kit.print("{s}", .{to}), link);
        }
    }
    {
        u.open(.{ .width = .grow, .gap = 4, .align_y = .center });
        defer u.close();
        var big = kit.style(.subtitle, p.text_primary);
        big.wrap = .none;
        u.open(.{ .width = .grow });
        if (j.state == .planning) {
            u.text("Discovering items\u{2026}", big);
        } else if (j.paused()) {
            u.text(kit.print("Paused - {d}% complete", .{percent(j)}), big);
        } else u.text(kit.print("{d}% complete", .{percent(j)}), big);
        u.close();
        const pause_id = kit.print("progress/{d}/pause", .{j.id});
        if (glyphButton(kit, pause_id, if (j.paused()) .play else .pause, if (j.paused()) "Resume" else "Pause")) {
            // Under the lock already: the dialog is drawn with it held.
            const t = Jobs.nowMs();
            if (j.pause.load(.acquire)) {
                j.paused_ms += t - j.paused_since;
                j.pause.store(false, .release);
            } else {
                j.paused_since = t;
                j.pause.store(true, .release);
            }
        }
        if (glyphButton(kit, kit.print("progress/{d}/cancel", .{j.id}), .dismiss, "Cancel")) Jobs.cancel(j);
    }
    if (self.progress_more) graph(self, kit, j) else bar(self, kit, j);
    if (!self.progress_more) return;
    var name_buffer: [256]u8 = undefined;
    infoLine(kit, "Name:", std.fmt.bufPrint(&name_buffer, "{s}", .{j.current()}) catch "");
    var time_buffer: [64]u8 = undefined;
    infoLine(kit, "Time remaining:", if (j.paused()) "Paused" else Jobs.remainingText(j.remainingMs(now), &time_buffer));
    var size_buffer: [32]u8 = undefined;
    const left_items = j.total_items -| j.done_items;
    const left_bytes = j.total_bytes -| j.done_bytes;
    infoLine(kit, "Items remaining:", kit.print("{d} ({s})", .{ left_items, Folder.sizeText(left_bytes, &size_buffer) }));
}

fn folderName(path: []const u8) []const u8 {
    const dir = std.fs.path.dirname(path) orelse return "/";
    const name = std.fs.path.basename(dir);
    return if (name.len == 0) "/" else name;
}

fn infoLine(kit: *Kit, name: []const u8, value: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .gap = 4, .clip = .both });
    defer u.close();
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.text(name, style);
    u.text(value, style);
}

fn glyphButton(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, tip: []const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = kit.theme.look.style == .win10;
    u.open(.{
        .id = id,
        .width = .fixed(28),
        .height = .fixed(28),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (u.isElementPressed(id)) p.subtle_tertiary else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
    });
    kit.icon(glyph, 12, p.text_primary, if (glyph == .play or glyph == .pause) .filled else .regular);
    const clicked = u.justReleased();
    u.close();
    kit.tooltip(id, tip);
    return clicked;
}

/// Fewer details: a bar, Windows 10's green.
fn bar(self: *Files, kit: *Kit, j: *const Jobs.Job) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const f = j.fraction();
    u.open(.{
        .width = .grow,
        .height = .fixed(if (ten) 16 else 4),
        .corner_radius = .all(if (ten) 0 else 2),
        .background_color = if (ten) (if (p.mode == .dark) widgets.argb(0xFF3C3C3C) else widgets.argb(0xFFE6E6E6)) else p.control_strong.withAlpha(0.35),
        .border = if (ten) .{ .color = if (p.mode == .dark) widgets.argb(0xFF5A5A5A) else widgets.argb(0xFFBCBCBC), .width = .all(1) } else .{},
    });
    defer u.close();
    u.empty(.{ .width = .percent(f), .height = .grow, .corner_radius = .all(if (ten) 0 else 2), .background_color = if (j.paused()) widgets.argb(0xFFD8B400) else ink(self, kit) });
}

/// More details: the speed over time, as Windows draws it - the part done
/// pale, the speed at each moment a column over it, a line at the speed
/// now, and the speed written over the line.
fn graph(self: *Files, kit: *Kit, j: *const Jobs.Job) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const colour = if (j.paused()) widgets.argb(0xFFD8B400) else ink(self, kit);
    const graph_w: f32 = dialog_w - 40;
    const f = j.fraction();
    u.open(.{
        .width = .fixed(graph_w),
        .height = .fixed(graph_h),
        .align_y = .bottom,
        .corner_radius = .all(if (ten) 0 else 4),
        .border = .{ .color = if (ten) widgets.argb(0xFFBCBCBC) else p.card_stroke, .width = .all(1) },
        .clip = .both,
    });
    defer u.close();
    // The grid behind: a line every tenth across, every quarter up.
    for (1..10) |k| u.empty(.{ .width = .fixed(1), .height = .grow, .background_color = p.divider, .floating = .{ .attach = .parent, .offset = .{ .x = graph_w * @as(f32, @floatFromInt(k)) / 10, .y = 0 } }, .passthrough = true });
    for (1..4) |k| u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = p.divider, .floating = .{ .attach = .parent, .offset = .{ .x = 0, .y = graph_h * @as(f32, @floatFromInt(k)) / 4 } }, .passthrough = true });
    // The part done, pale.
    u.empty(.{ .width = .fixed(graph_w * f), .height = .grow, .background_color = colour.withAlpha(0.28), .floating = .{ .attach = .parent, .offset = .{ .x = 0, .y = 0 } }, .passthrough = true });
    // The speed, each moment a column - as many as fit what is done.
    const count = @min(j.sample_count, j.samples.len);
    if (count > 0) {
        var top: f32 = 1;
        for (0..count) |k| top = @max(top, j.samples[(j.sample_count - count + k) % j.samples.len]);
        top *= 1.25;
        const done_w = graph_w * f;
        const step = done_w / @as(f32, @floatFromInt(count));
        for (0..count) |k| {
            const s = j.samples[(j.sample_count - count + k) % j.samples.len];
            const column = graph_h * s / top;
            u.empty(.{
                .width = .fixed(@max(1, @ceil(step))),
                .height = .fixed(column),
                .background_color = colour,
                .floating = .{ .attach = .parent, .offset = .{ .x = step * @as(f32, @floatFromInt(k)), .y = graph_h - column } },
                .passthrough = true,
            });
        }
        // The speed now: a line across, and what it is.
        const now_y = graph_h - graph_h * j.speed() / top;
        u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = p.text_primary.withAlpha(0.7), .floating = .{ .attach = .parent, .offset = .{ .x = 0, .y = now_y } }, .passthrough = true });
        var speed_buffer: [32]u8 = undefined;
        u.open(.{ .padding = .xy(4, 0), .floating = .{ .attach = .parent, .fractions = .{ .element_x = 1, .element_y = 1, .target_x = 1, .target_y = 0 }, .offset = .{ .x = -2, .y = @max(14, now_y - 1) } }, .passthrough = true });
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .none;
        u.text(kit.print("Speed: {s}/s", .{Folder.sizeText(@intFromFloat(j.speed()), &speed_buffer)}), style);
        u.close();
    }
}

/// Folded into the status bar: how far it is - a click opens it again.
pub fn chip(self: *Files, kit: *Kit) void {
    if (!self.progress_folded) return;
    const u = kit.ui;
    const p = &kit.theme.palette;
    const jobs = &self.jobs;
    jobs.lock();
    var first: ?*Jobs.Job = null;
    var count: usize = 0;
    for (jobs.list.items) |j| if (!j.finished()) {
        if (first == null) first = j;
        count += 1;
    };
    const f = if (first) |j| j.fraction() else 0;
    jobs.unlock();
    if (first == null) {
        self.progress_folded = false;
        return;
    }
    const id = "status/progress";
    u.open(.{ .id = id, .height = .fixed(18), .padding = .xy(6, 0), .gap = 6, .align_y = .center, .corner_radius = .all(if (self.ten()) 0 else 3), .background_color = if (u.isPointerOver(id)) p.subtle_secondary else .transparent });
    defer u.close();
    kit.icon(.copy, 12, ink(self, kit), .regular);
    u.open(.{ .width = .fixed(80), .height = .fixed(4), .background_color = p.control_strong.withAlpha(0.35), .corner_radius = .all(2) });
    u.empty(.{ .width = .percent(f), .height = .grow, .background_color = ink(self, kit), .corner_radius = .all(2) });
    u.close();
    var style = kit.style(.caption, p.text_secondary);
    style.wrap = .none;
    u.text(kit.print("{d}%{s}", .{ @as(u32, @intFromFloat(f * 100)), if (count > 1) " (more running)" else "" }), style);
    if (u.justReleased()) self.progress_folded = false;
}

// -------------------------------------------------------------------------
// Replace or Skip Files
// -------------------------------------------------------------------------

/// The question over the window: what to do with the names taken.
fn question(self: *Files, kit: *Kit, j: *Jobs.Job) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const n = j.conflicts.items.len;
    smokeBegin(kit);
    defer u.close();
    dialogBegin(self, kit, "conflict", 460);
    defer u.close();
    titleRow(self, kit, "Replace or Skip Files", j);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .trbl(4, 24, 12, 24), .gap = 6 });
    {
        defer u.close();
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .words;
        const total = j.total_items;
        u.text(kit.print("{s} {d} item{s} from {s} to {s}", .{ if (j.kind == .move) "Moving" else "Copying", total, if (total == 1) "" else "s", folderName(j.sources[0]), std.fs.path.basename(j.dest) }), style);
        // Windows 10's heading is a dark blue.
        var heading = kit.style(.body_large, if (ten) (if (p.mode == .dark) widgets.argb(0xFF6CB4F2) else widgets.argb(0xFF1E3287)) else p.text_primary);
        heading.wrap = .words;
        if (n == 1) {
            const step = j.steps.items[j.conflicts.items[0]];
            u.text(kit.print("The destination already has a file named \u{201C}{s}\u{201D}", .{std.fs.path.basename(step.to)}), heading);
        } else u.text(kit.print("The destination has {d} files with the same names", .{n}), heading);
    }
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .trbl(0, 16, 16, 16), .gap = 2 });
    defer u.close();
    if (commandLink(self, kit, "conflict/replace", .checkmark, if (n == 1) "Replace the file in the destination" else "Replace the files in the destination", null)) self.jobs.answerLocked(j, .replace);
    if (commandLink(self, kit, "conflict/skip", .arrow_reply, if (n == 1) "Skip this file" else "Skip these files", null)) self.jobs.answerLocked(j, .skip);
    if (commandLink(self, kit, "conflict/decide", .copy, if (n == 1) "Compare info for both files" else "Let me decide for each file", null)) {
        self.deciding = j.id;
        self.decide_source.clearRetainingCapacity();
        self.decide_dest.clearRetainingCapacity();
        for (j.conflicts.items) |_| {
            self.decide_source.append(self.gpa, true) catch {};
            self.decide_dest.append(self.gpa, false) catch {};
        }
    }
}

/// Windows' command link: a glyph, words in its own blue, lit under the
/// pointer.
fn commandLink(self: *Files, kit: *Kit, id: []const u8, glyph: widgets.icons.Name, text: []const u8, note: ?[]const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const hovered = u.isPointerOver(id);
    const blue = if (p.mode == .dark) widgets.argb(0xFF6CB4F2) else widgets.argb(0xFF1E3287);
    u.open(.{
        .id = id,
        .width = .grow,
        .padding = .xy(10, 8),
        .gap = 10,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (hovered) (if (ten) (if (p.mode == .dark) widgets.argb(0xFF3E3E3E) else widgets.argb(0xFFE5F3FF)) else p.subtle_secondary) else .transparent,
        .border = if (hovered and ten) .{ .color = if (p.mode == .dark) widgets.argb(0xFF5A5A5A) else widgets.argb(0xFFCCE8FF), .width = .all(1) } else .{},
    });
    kit.icon(glyph, 16, if (ten) widgets.argb(0xFF1979CA) else p.accent, .regular);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2 });
    var style = kit.style(.body, if (ten) blue else p.text_primary);
    style.wrap = .words;
    u.text(text, style);
    if (note) |line| kit.label(line, .caption, p.text_secondary);
    u.close();
    const clicked = u.justReleased();
    u.close();
    return clicked;
}

/// "Let me decide": each name taken, the file coming and the one there
/// side by side - when it was changed, how big - a box each to keep it.
fn decide(self: *Files, kit: *Kit, j: *Jobs.Job) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const n = j.conflicts.items.len;
    if (self.decide_source.items.len != n) {
        self.deciding = null;
        return;
    }
    smokeBegin(kit);
    defer u.close();
    dialogBegin(self, kit, "decide", 560);
    defer u.close();
    titleRow(self, kit, kit.print("{d} File Conflict{s}", .{ n, if (n == 1) "" else "s" }), j);
    {
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .trbl(4, 20, 8, 20), .gap = 4 });
        defer u.close();
        kit.label("Which files do you want to keep?", .body_large, p.text_primary);
        var style = kit.style(.caption, p.text_secondary);
        style.wrap = .words;
        u.text("If you select both versions, the copied file will have a number added to its name.", style);
    }
    // The two columns' heads: every file of each side at once.
    {
        u.open(.{ .width = .grow, .padding = .xy(20, 4), .gap = 12 });
        defer u.close();
        var all_source = std.mem.allEqual(bool, self.decide_source.items, true);
        var all_dest = std.mem.allEqual(bool, self.decide_dest.items, true);
        u.open(.{ .width = .grow });
        if (kit.checkbox("decide/all-source", &all_source, kit.print("Files from {s}", .{folderName(j.sources[0])}), .{})) @memset(self.decide_source.items, all_source);
        u.close();
        u.open(.{ .width = .grow });
        if (kit.checkbox("decide/all-dest", &all_dest, kit.print("Files already in {s}", .{std.fs.path.basename(j.dest)}), .{})) @memset(self.decide_dest.items, all_dest);
        u.close();
    }
    {
        u.open(.{
            .id = "decide/list",
            .width = .grow,
            .height = .{ .kind = .fit, .max = 300 },
            .direction = .top_to_bottom,
            .padding = .xy(20, 4),
            .gap = 6,
            .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
        });
        defer u.close();
        for (j.conflicts.items, 0..) |index, k| {
            const step = j.steps.items[index];
            var name_style = kit.style(.caption, p.text_primary);
            name_style.wrap = .none;
            u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2, .border = .{ .color = p.divider, .width = .{ .bottom = 1 } }, .padding = .trbl(0, 0, 6, 0) });
            defer u.close();
            u.text(std.fs.path.basename(step.to), name_style);
            u.open(.{ .width = .grow, .gap = 12 });
            defer u.close();
            side(self, kit, kit.print("decide/{d}/source", .{k}), step.from, &self.decide_source.items[k]);
            side(self, kit, kit.print("decide/{d}/dest", .{k}), step.to, &self.decide_dest.items[k]);
        }
    }
    u.open(.{ .width = .grow, .padding = .all(16), .gap = 8, .align_x = .right, .background_color = p.solid_secondary, .border = .{ .color = p.divider, .width = .{ .top = 1 } } });
    defer u.close();
    if (kit.button("decide/continue", "Continue", .{ .kind = .accent, .width = .fixed(100) })) {
        for (j.conflicts.items, 0..) |index, k| {
            const source = self.decide_source.items[k];
            const dest = self.decide_dest.items[k];
            j.steps.items[index].answer = if (source and dest) .keep_both else if (source) .replace else .skip;
        }
        j.answered = true;
        self.deciding = null;
    }
    if (kit.button("decide/cancel", "Cancel", .{ .width = .fixed(100) })) {
        Jobs.cancel(j);
        self.deciding = null;
    }
}

/// One side of a name taken: a box to keep it, its icon, when it was
/// changed and how big it is.
fn side(self: *Files, kit: *Kit, id: []const u8, path: []const u8, keep: *bool) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .gap = 8, .align_y = .center });
    defer u.close();
    _ = kit.checkbox(id, keep, "", .{});
    panes.fileIcon(self, kit, std.fs.path.basename(path), 32);
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 1 });
    defer u.close();
    const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch return;
    var date_buffer: [32]u8 = undefined;
    var size_buffer: [32]u8 = undefined;
    kit.label(kit.print("{s}", .{views.dateText(stat.mtime.nanoseconds, &date_buffer)}), .caption, p.text_secondary);
    kit.label(kit.print("{s}", .{Folder.sizeText(stat.size, &size_buffer)}), .caption, p.text_secondary);
}

fn smokeBegin(kit: *Kit) void {
    kit.ui.open(.{ .id = "conflict/smoke", .width = .grow, .height = .grow, .align_x = .center, .align_y = .center, .background_color = kit.theme.palette.smoke.withAlpha(0.2), .floating = .{ .attach = .root, .z_index = 96 } });
}

fn dialogBegin(self: *Files, kit: *Kit, id: []const u8, w: f32) void {
    const p = &kit.theme.palette;
    const ten = self.ten();
    kit.ui.open(.{
        .id = id,
        .width = .fixed(w),
        .direction = .top_to_bottom,
        .corner_radius = .all(if (ten) 0 else 8),
        .background_color = p.solid_base,
        .border = .{ .color = if (ten) widgets.argb(0xFF1979CA) else p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .clip = .both,
    });
}

/// A dialog's title bar: its icon, its title, the close button - which
/// cancels the job.
fn titleRow(self: *Files, kit: *Kit, title: []const u8, j: *Jobs.Job) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .height = .fixed(32), .padding = .trbl(0, 0, 0, 12), .gap = 8, .align_y = .center });
    defer u.close();
    kit.icon(.copy, 14, if (self.ten()) widgets.argb(0xFF1979CA) else p.accent, .regular);
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    u.open(.{ .width = .grow, .clip = .both });
    u.text(title, style);
    u.close();
    if (captionButton(self, kit, "conflict/close", .dismiss, true)) {
        Jobs.cancel(j);
        self.deciding = null;
    }
}
