// SPDX-License-Identifier: BSD-2-Clause

//! The panes on the right of the folder, one at a time, as Windows has
//! them - each as wide as its edge is dragged to, kept for the next window:
//!
//! - **the details pane** (Alt+Shift+P): what is chosen, large, and what it
//!   is - its name and kind, its size, when it was changed and made, and
//!   what the preview learnt of it: a picture's size, a song's artist, a
//!   video's length, a PDF's pages; with nothing chosen, the folder and how
//!   many items it holds;
//! - **the preview pane** (Alt+P): the chosen file itself - see `Preview` -
//!   a picture, text, a PDF's pages to scroll through, a video or a song to
//!   play, what is in a compressed folder, a font's letters - or "No
//!   preview available."
//!
//! Windows 10's are flat, white or black as the folder is; Windows 11's
//! round their pictures and set text on a card.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;
const Color = ui.Color;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const Ops = @import("Ops.zig");
const Window = @import("Window.zig");
const Preview = @import("Preview.zig");
const chrome = @import("chrome.zig");
const icons = @import("icons.zig");
const views = @import("views.zig");
const win10 = @import("win10.zig");

/// The narrowest a pane is dragged to.
pub const least_width = 220;
/// Between the pane's edge and what is in it.
const pad = 12;

/// The pane's width: as it was last dragged to, kept on the window.
pub fn width(self: *Files) f32 {
    const wanted = if (self.pane == .preview) self.prefs.preview_width else self.prefs.details_width;
    return std.math.clamp(wanted, least_width, mostWidth(self));
}

fn mostWidth(self: *Files) f32 {
    const w: f32 = @floatFromInt(self.window.width);
    return @max(least_width, w * 0.6);
}

pub fn pane(self: *Files, kit: *Kit) void {
    if (self.pane == .none) {
        self.player.unload();
        self.preview.clear();
        return;
    }
    const u = kit.ui;
    const p = &kit.theme.palette;
    const w = width(self);
    u.open(.{
        .id = "pane",
        .width = .fixed(w),
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = chrome.contentColor(kit),
        .border = .{ .color = if (self.ten()) win10.edgeColor(kit) else p.divider, .width = .{ .left = 1 } },
    });
    defer u.close();
    grip(self, kit, w);
    // The file chosen, made ready by the preview's thread - for both panes:
    // the details pane lists what it learns.
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (chosenPath(self, &path_buffer)) |one| {
        const box: u32 = @intFromFloat(@max(64, (w - 2 * pad) * self.window.scale));
        self.preview.show(one.path, one.entry.mime, one.entry.mtime, box, self.prefs.preview_handlers);
    } else self.preview.clear();
    switch (self.pane) {
        .none => {},
        .details => details(self, kit, w),
        .preview => preview(self, kit, w),
    }
    // A video or a song plays only while it is shown.
    if (self.pane != .preview or !showsMedia(self)) self.player.unload();
}

/// The pane's left edge: dragged, it makes the pane wider or narrower.
fn grip(self: *Files, kit: *Kit, w: f32) void {
    const u = kit.ui;
    const id = "pane/grip";
    const h = if (self.window.boxOf("pane")) |b| b.height else @as(f32, @floatFromInt(self.window.height));
    u.open(.{
        .id = id,
        .width = .fixed(8),
        .height = .fixed(h),
        .cursor = .resize_ew,
        .floating = .{ .attach = .parent, .offset = .{ .x = -4, .y = 0 }, .z_index = 6 },
    });
    if (u.justPressed()) if (self.window.pointer_at) |at| {
        self.pane_drag = .{ .from_x = at[0], .from_width = w };
    };
    u.close();
    const drag = self.pane_drag orelse return;
    u.setCursor(.resize_ew);
    if (!self.window.down) {
        self.pane_drag = null;
        self.prefs.save(self.io);
        return;
    }
    const at = self.window.pointer_at orelse return;
    const now = std.math.clamp(drag.from_width - (at[0] - drag.from_x), least_width, mostWidth(self));
    if (self.pane == .preview) self.prefs.preview_width = now else self.prefs.details_width = now;
}

/// The full path of the one item chosen, if one is.
fn chosenPath(self: *Files, buffer: []u8) ?struct { path: []const u8, entry: *Folder.Entry } {
    const t = self.tab();
    if (!t.lists() or t.selectedCount() != 1) return null;
    const i = t.current() orelse return null;
    const e = t.entry(i);
    const dir = t.dirOf(e) orelse return null;
    const full = Ops.join(buffer, dir, e.name) catch return null;
    return .{ .path = full, .entry = e };
}

fn showsMedia(self: *Files) bool {
    const m = self.preview.current() orelse return false;
    return m.kind == .video or m.kind == .audio;
}

// -------------------------------------------------------------------------
// The details pane
// -------------------------------------------------------------------------

fn details(self: *Files, kit: *Kit, w: f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    const ten = self.ten();
    u.open(.{
        .id = "pane/details",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .all(pad),
        .gap = 10,
        .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
    });
    defer u.close();
    const chosen = if (t.lists()) t.selectedCount() else 0;
    if (chosen == 0) {
        // The folder itself.
        u.open(.{ .width = .grow, .align_x = .center, .padding = .xy(0, 24) });
        icons.themed(self, kit, if (t.location == .trash) "user-trash" else "folder", 96);
        u.close();
        var buffer: [256]u8 = undefined;
        const title = self.titleOf(t, &buffer);
        var style = kit.style(.subtitle, p.text_primary);
        style.wrap = .words;
        style.alignment = if (ten) .left else .center;
        if (t.lists()) {
            if (ten) {
                u.text(title, style);
                kit.label(kit.print("{d} items", .{t.count()}), .caption, p.text_secondary);
            } else u.text(kit.print("{s} ({d} items)", .{ title, t.count() }), style);
        } else u.text(title, style);
        if (!ten) note(kit, "Select a single file to get more information.");
        return;
    }
    if (chosen > 1) {
        u.open(.{ .width = .grow, .align_x = .center, .padding = .xy(0, 24) });
        icons.themed(self, kit, "folder-documents", 96);
        u.close();
        kit.label(kit.print("{d} items selected", .{chosen}), .subtitle, p.text_primary);
        var size_buffer: [32]u8 = undefined;
        if (t.selectedSize() > 0) row(self, kit, "Size", kit.print("{s}", .{Folder.sizeText(t.selectedSize(), &size_buffer)}));
        if (!ten) note(kit, "Select a single file to get more information.");
        return;
    }
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const one = chosenPath(self, &path_buffer) orelse return;
    const e = one.entry;
    // The picture itself, where it is one - a video's frame, a song's cover,
    // a page - and its icon otherwise.
    {
        u.open(.{ .width = .grow, .align_x = .center, .padding = .xy(0, 8) });
        defer u.close();
        if (self.preview.shownPicture()) |picture| {
            pictureFit(self, kit, picture.slot, picture.size, w - 2 * pad, 240);
        } else icons.forEntry(self, kit, t.dirOf(e) orelse "/", e, 96);
    }
    {
        u.open(.{ .width = .grow, .gap = 8, .align_y = .center });
        defer u.close();
        if (!ten) icons.forEntry(self, kit, t.dirOf(e) orelse "/", e, 24);
        var style = kit.style(.subtitle, p.text_primary);
        style.wrap = .words;
        u.open(.{ .width = .grow });
        u.text(e.name, style);
        u.close();
    }
    var type_buffer: [64]u8 = undefined;
    const kind = self.mime.describe(e.mime, e.name, &type_buffer);
    if (ten) kit.label(kit.print("{s}", .{kind}), .caption, p.text_secondary);
    if (!ten) {
        u.empty(.{ .width = .grow, .height = .fixed(4) });
        kit.label("Details", .body_strong, p.text_primary);
        row(self, kit, "Type", kit.print("{s}", .{kind}));
    }
    var size_buffer: [32]u8 = undefined;
    if (!e.isFolder()) row(self, kit, "Size", kit.print("{s}", .{Folder.sizeText(e.size, &size_buffer)}));
    var date_buffer: [32]u8 = undefined;
    row(self, kit, "Date modified", kit.print("{s}", .{views.dateText(e.mtime, &date_buffer)}));
    if (Ops.created(self.io, one.path)) |born| {
        var born_buffer: [32]u8 = undefined;
        row(self, kit, "Date created", kit.print("{s}", .{views.dateText(born, &born_buffer)}));
    }
    // What the preview learnt: a picture's size, a song's artist.
    if (self.preview.current()) |m| for (m.info) |line| row(self, kit, line.name, line.value);
    row(self, kit, if (ten) "Location" else "File location", kit.print("{s}", .{t.dirOf(e) orelse ""}));
    if (!ten) {
        u.empty(.{ .width = .grow, .height = .fixed(4) });
        if (kit.button("pane/properties", "Properties", .{ .icon = .info })) self.openProperties();
    }
}

/// A property: Windows 10's name to the left of what it is, right-aligned
/// and grey; Windows 11's name at the left, what it is at the right.
fn row(self: *Files, kit: *Kit, name: []const u8, value: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .gap = 10 });
    defer u.close();
    var label_style = kit.style(.caption, p.text_secondary);
    label_style.wrap = .words;
    var value_style = kit.style(.caption, p.text_primary);
    value_style.wrap = .words;
    if (self.ten()) {
        label_style.alignment = .right;
        u.open(.{ .width = .fixed(96) });
        u.text(kit.print("{s}:", .{name}), label_style);
        u.close();
        u.open(.{ .width = .grow });
        u.text(value, value_style);
        u.close();
        return;
    }
    u.open(.{ .width = .percent(0.42) });
    u.text(name, label_style);
    u.close();
    value_style.alignment = .right;
    u.open(.{ .width = .grow });
    u.text(value, value_style);
    u.close();
}

/// Windows 11's hint at the foot of the pane, on a card.
fn note(kit: *Kit, text: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.empty(.{ .width = .grow, .height = .grow });
    u.open(.{ .width = .grow, .padding = .all(12), .gap = 10, .corner_radius = .all(6), .background_color = p.card, .border = .{ .color = p.card_stroke, .width = .all(1) } });
    defer u.close();
    kit.icon(.info, 16, p.text_secondary, .regular);
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .words;
    u.open(.{ .width = .grow });
    u.text(text, style);
    u.close();
}

/// A picture made `size` pixels, shown in `w` by at most `h` - its shape
/// kept - Windows 10's square, Windows 11's rounded with a fine edge.
fn pictureFit(self: *Files, kit: *Kit, slot: u32, size: [2]u32, w: f32, h: f32) void {
    const s = self.window.scale;
    var pw = @as(f32, @floatFromInt(size[0])) / s;
    var ph = @as(f32, @floatFromInt(size[1])) / s;
    const k = @min(1, @min(w / @max(1, pw), h / @max(1, ph)));
    pw *= k;
    ph *= k;
    kit.ui.empty(.{
        .width = .fixed(@round(pw)),
        .height = .fixed(@round(ph)),
        .image = .{ .texture = slot },
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .border = if (self.ten()) .{} else .{ .color = kit.theme.palette.card_stroke, .width = .all(1) },
    });
}

// -------------------------------------------------------------------------
// The preview pane
// -------------------------------------------------------------------------

fn preview(self: *Files, kit: *Kit, w: f32) void {
    const t = self.tab();
    if (!t.lists() or t.selectedCount() == 0) return message(kit, "Select a file to preview.");
    if (t.selectedCount() > 1) return message(kit, "Select a single file to preview.");
    const m = self.preview.current() orelse {
        // Being made: a moment of nothing, then a word.
        if (Window.nowMs() - self.preview.asked_ms > 400) return message(kit, "Loading preview\u{2026}");
        self.window.wakeAt(self.preview.asked_ms + 401);
        return;
    };
    switch (m.kind) {
        .nothing, .loading => {},
        .picture, .document => pictureView(self, kit, w),
        .font => fontView(self, kit),
        .text => textView(self, kit, m),
        .pdf => pdfView(self, kit, m, w),
        .video, .audio => mediaView(self, kit, m, w),
        .archive => archiveView(self, kit, m),
        .folder, .none => message(kit, "No preview available."),
    }
}

fn message(kit: *Kit, text: []const u8) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .height = .grow, .padding = .all(pad), .align_x = .center, .align_y = .center });
    defer u.close();
    var style = kit.style(.caption, kit.theme.palette.text_secondary);
    style.alignment = .center;
    style.wrap = .words;
    u.text(text, style);
}

fn pictureView(self: *Files, kit: *Kit, w: f32) void {
    const u = kit.ui;
    const picture = self.preview.shownPicture() orelse return message(kit, "No preview available.");
    const h = if (self.window.boxOf("pane")) |b| b.height - 2 * pad else 400;
    u.open(.{ .width = .grow, .height = .grow, .padding = .all(pad), .align_x = .center, .align_y = .center });
    defer u.close();
    pictureFit(self, kit, picture.slot, picture.size, w - 2 * pad, h);
}

/// A font's letters: as tall as they are, scrolled through.
fn fontView(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const picture = self.preview.shownPicture() orelse return message(kit, "No preview available.");
    u.open(.{
        .id = "preview/font",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .all(pad),
        .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
    });
    defer u.close();
    const s = self.window.scale;
    u.empty(.{
        .width = .fixed(@as(f32, @floatFromInt(picture.size[0])) / s),
        .height = .fixed(@as(f32, @floatFromInt(picture.size[1])) / s),
        .image = .{ .texture = picture.slot },
        .corner_radius = .all(if (self.ten()) 0 else 4),
        .border = .{ .color = kit.theme.palette.card_stroke, .width = .all(1) },
    });
}

/// A scroll container's clip, both ways, with the look's bars.
fn bothWays(kit: *Kit) ui.layout.Clip {
    return .{
        .vertical = true,
        .horizontal = true,
        .scroll_x = true,
        .scroll_y = true,
        .no_drag_scroll = true,
        .scrollbar = .{ .width = 6, .corner_radius = if (kit.theme.look.style == .win10) 0 else 3, .thumb_color = kit.theme.palette.text_tertiary, .hide_after_seconds = 1.5 },
    };
}

/// Text, a line a row, only those in sight laid out: a file of thousands
/// of lines costs what a screenful does. Code in the monospaced face.
fn textView(self: *Files, kit: *Kit, m: *const Preview.Made) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const id = "preview/text";
    const line_h: f32 = 18;
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    style.line_height = 18;
    if (m.code) style.font = widgets.Fonts.Slot.mono;
    const s = self.window.scale;
    const scroll = u.scrollOf(id);
    const top = if (scroll) |sc| sc.position.y / s else 0;
    const view_h = if (scroll) |sc| (if (sc.viewport.height > 0) sc.viewport.height / s else 600) else 600;
    // Windows 11 sets the text on a card; Windows 10 leaves it on the pane.
    u.open(.{ .width = .grow, .height = .grow, .padding = .all(if (ten) 0 else 8) });
    defer u.close();
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .xy(10, 8),
        .corner_radius = .all(if (ten) 0 else 6),
        .background_color = if (ten) .transparent else p.card,
        .border = if (ten) .{} else .{ .color = p.card_stroke, .width = .all(1) },
        .clip = bothWays(kit),
    });
    defer u.close();
    const n = m.lines.len;
    const first: usize = @min(n, @as(usize, @intFromFloat(@max(0, top / line_h))) -| 20);
    const last: usize = @min(n, first + @as(usize, @intFromFloat(view_h / line_h)) + 40);
    if (first > 0) u.empty(.{ .width = .fixed(1), .height = .fixed(@as(f32, @floatFromInt(first)) * line_h) });
    for (m.lines[first..last]) |line| {
        u.open(.{ .height = .fixed(line_h), .align_y = .center });
        defer u.close();
        if (line.len > 0) u.text(line, style);
    }
    if (last < n) u.empty(.{ .width = .fixed(1), .height = .fixed(@as(f32, @floatFromInt(n - last)) * line_h) });
    if (m.truncated) {
        var more = style;
        more.color = p.text_secondary;
        u.open(.{ .height = .fixed(line_h), .align_y = .center });
        u.text("\u{2026}", more);
        u.close();
    }
}

/// A PDF's pages, one under another on grey, each made as it comes into
/// sight; and which page is in sight, at the foot.
fn pdfView(self: *Files, kit: *Kit, m: *const Preview.Made, w: f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const id = "preview/pdf";
    const gap: f32 = 10;
    const page_w = @max(40, w - 2 * pad - 8);
    const page_h = page_w * m.page_aspect;
    const s = self.window.scale;
    const scroll = u.scrollOf(id);
    const top = if (scroll) |sc| sc.position.y / s else 0;
    const view_h = if (scroll) |sc| (if (sc.viewport.height > 0) sc.viewport.height / s else 600) else 600;
    const step = page_h + gap;
    const first: u32 = @intFromFloat(@max(0, (top - pad) / step));
    const in_sight: u32 = @intFromFloat(@ceil(view_h / step));
    const last = @min(m.pages, first + in_sight + Preview.pages_ahead);
    const dark = p.mode == .dark;
    {
        u.open(.{
            .id = id,
            .width = .grow,
            .height = .grow,
            .direction = .top_to_bottom,
            .align_x = .center,
            .padding = .all(pad),
            .gap = @intFromFloat(gap),
            .background_color = if (ten) (if (dark) widgets.argb(0xFF2B2B2B) else widgets.argb(0xFFE6E6E6)) else p.subtle_secondary,
            .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
        });
        defer u.close();
        if (first > 0) u.empty(.{ .width = .fixed(1), .height = .fixed(@as(f32, @floatFromInt(first)) * step - gap) });
        var n = first + 1;
        while (n <= last) : (n += 1) {
            const made = self.preview.page(n);
            u.open(.{
                .width = .fixed(page_w),
                .height = .fixed(page_h),
                .align_x = .center,
                .align_y = .center,
                .background_color = widgets.argb(0xFFFFFFFF),
                .corner_radius = .all(if (ten) 0 else 2),
                .border = if (ten) .{ .color = widgets.argb(0xFFBDBDBD), .width = .all(1) } else .{},
                .shadow = if (ten) null else kit.elevation(.card),
                .clip = .both,
            });
            defer u.close();
            if (made) |pg| {
                if (pg.slot) |slot| {
                    u.empty(.{ .width = .fixed(page_w), .height = .fixed(@min(page_h, page_w * @as(f32, @floatFromInt(pg.size[1])) / @max(1, @as(f32, @floatFromInt(pg.size[0]))))), .image = .{ .texture = slot } });
                } else if (pg.failed) kit.label("This page could not be shown.", .caption, widgets.argb(0xFF6E6E6E));
            }
        }
        if (last < m.pages) u.empty(.{ .width = .fixed(1), .height = .fixed(@as(f32, @floatFromInt(m.pages - last)) * step) });
    }
    // Which page is in sight: a chip at the foot.
    const middle = @min(m.pages, @as(u32, @intFromFloat(@max(0, (top + view_h / 2 - pad) / step))) + 1);
    u.open(.{
        .padding = .xy(10, 4),
        .corner_radius = .all(if (ten) 0 else 12),
        .background_color = p.solid_base.withAlpha(0.92),
        .border = .{ .color = p.surface_stroke_flyout, .width = .all(1) },
        .floating = .{ .attach = .parent, .fractions = .{ .element_x = 0.5, .element_y = 1, .target_x = 0.5, .target_y = 1 }, .offset = .{ .x = 0, .y = -12 }, .z_index = 4 },
        .passthrough = true,
    });
    kit.label(kit.print("Page {d} of {d}", .{ @max(1, middle), m.pages }), .caption, p.text_primary);
    u.close();
}

/// A video, or a song with its cover, and what plays it: Windows' media
/// controls - play and pause, where it is, the bar to go along, the sound.
fn mediaView(self: *Files, kit: *Kit, m: *const Preview.Made, w: f32) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const media = m.media;
    const inner = w - 2 * pad;
    const video = m.kind == .video and media.width > 0 and media.height > 0;
    const s = self.window.scale;
    const aspect: f32 = if (video) @as(f32, @floatFromInt(media.height)) / @as(f32, @floatFromInt(media.width)) else 1;
    const area_h = @min(inner * aspect, if (self.window.boxOf("pane")) |b| b.height * 0.6 else 400);
    const area_w = if (video) area_h / aspect else area_h;
    const frame_w: u32 = @intFromFloat(@round(area_w * s));
    const frame_h: u32 = @intFromFloat(@round(area_h * s));
    self.player.load(self.preview.shownPath(), media.duration_ms, media.has_video and m.kind == .video, media.has_audio, frame_w, frame_h);
    u.open(.{ .width = .grow, .height = .grow, .direction = .top_to_bottom, .padding = .all(pad), .gap = 10, .align_x = .center, .align_y = .center });
    defer u.close();
    {
        u.open(.{
            .id = "preview/media",
            .width = .fixed(if (video) inner else area_w),
            .height = .fixed(area_h),
            .align_x = .center,
            .align_y = .center,
            .corner_radius = .all(if (ten) 0 else 6),
            .background_color = if (video) widgets.argb(0xFF000000) else if (m.has_picture) .transparent else p.subtle_secondary,
            .clip = .both,
        });
        defer u.close();
        if (self.player.frame()) |slot| {
            pictureFitPlain(self, kit, slot, .{ self.player.frame_w, self.player.frame_h }, area_w, area_h);
        } else if (self.preview.shownPicture()) |pic| {
            pictureFitPlain(self, kit, pic.slot, pic.size, area_w, area_h);
        } else if (!video) kit.icon(.music_note_2, 64, p.text_secondary, .regular);
        // Not playing: the large play button over it, as Windows' has.
        if (!self.player.playing()) {
            u.open(.{
                .width = .fixed(56),
                .height = .fixed(56),
                .align_x = .center,
                .align_y = .center,
                .corner_radius = .all(28),
                .background_color = if (ten) widgets.argb(0xB0000000) else p.solid_base.withAlpha(0.85),
                .border = if (ten) .{ .color = widgets.argb(0xFFFFFFFF), .width = .all(2) } else .{ .color = p.surface_stroke_flyout, .width = .all(1) },
                .floating = .{ .attach = .parent, .fractions = .{ .element_x = 0.5, .element_y = 0.5, .target_x = 0.5, .target_y = 0.5 } },
                .passthrough = true,
            });
            kit.icon(.play, 24, if (ten) widgets.argb(0xFFFFFFFF) else p.text_primary, .filled);
            u.close();
        }
        if (u.justReleased()) self.player.toggle();
    }
    // A song: its title, its artist and album.
    if (m.kind == .audio) {
        var title_style = kit.style(.body_strong, p.text_primary);
        title_style.alignment = .center;
        title_style.wrap = .words;
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2, .align_x = .center });
        defer u.close();
        u.text(if (media.title.len > 0) media.title else std.fs.path.stem(self.preview.shownPath()), title_style);
        var small = kit.style(.caption, p.text_secondary);
        small.alignment = .center;
        small.wrap = .words;
        if (media.artist.len > 0) u.text(media.artist, small);
        if (media.album.len > 0) u.text(media.album, small);
    }
    controls(self, kit, media);
}

/// The picture as it is, made to fit: a video's frame, a cover.
fn pictureFitPlain(self: *Files, kit: *Kit, slot: u32, size: [2]u32, w: f32, h: f32) void {
    const s = self.window.scale;
    var pw = @as(f32, @floatFromInt(size[0])) / s;
    var ph = @as(f32, @floatFromInt(size[1])) / s;
    const k = @min(w / @max(1, pw), h / @max(1, ph));
    pw *= k;
    ph *= k;
    kit.ui.empty(.{ .width = .fixed(@round(pw)), .height = .fixed(@round(ph)), .image = .{ .texture = slot }, .corner_radius = .all(if (self.ten()) 0 else 6) });
}

/// Play and pause, the time, the bar, the sound: Windows 10's flat on a
/// grey band, Windows 11's on a card.
fn controls(self: *Files, kit: *Kit, media: Preview.Media) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const player = &self.player;
    const playing = player.playing();
    // Drawn again as it plays, for the time and the bar.
    if (playing) self.window.wakeAt(Window.nowMs() + 250);
    u.open(.{
        .width = .grow,
        .padding = .xy(6, 4),
        .gap = 6,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 6),
        .background_color = if (ten) (if (p.mode == .dark) widgets.argb(0xFF2B2B2B) else widgets.argb(0xFFF0F0F0)) else p.card,
        .border = if (ten) .{} else .{ .color = p.card_stroke, .width = .all(1) },
    });
    defer u.close();
    if (mediaButton(kit, "preview/play", if (playing) .pause else .play, if (playing) "Pause" else "Play")) player.toggle();
    // Where it is: dragged, gone to where it is let go of.
    const id = "preview/seek";
    const pressed = u.isElementPressed(id);
    var at: f32 = if (self.seek_value) |v| v else @floatFromInt(player.position());
    const total: f32 = @floatFromInt(@max(1, media.duration_ms));
    var now_buffer: [16]u8 = undefined;
    var total_buffer: [16]u8 = undefined;
    var style = kit.style(.caption, p.text_secondary);
    style.wrap = .none;
    u.text(kit.print("{s} / {s}", .{ Preview.clockText(@intFromFloat(at), &now_buffer, false), Preview.clockText(media.duration_ms, &total_buffer, false) }), style);
    if (kit.slider(id, &at, .{ .min = 0, .max = total, .step = 0, .width = .grow })) self.seek_value = at;
    if (!pressed) if (self.seek_value) |v| {
        player.seek(@intFromFloat(v));
        self.seek_value = null;
    };
    if (media.has_audio) {
        if (mediaButton(kit, "preview/mute", if (player.muted) .speaker_mute else .speaker_2, if (player.muted) "Unmute" else "Mute")) player.toggleMute();
    }
}

fn mediaButton(kit: *Kit, id: []const u8, glyph: widgets.icons.Name, tip: []const u8) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = kit.theme.look.style == .win10;
    u.open(.{
        .id = id,
        .width = .fixed(32),
        .height = .fixed(32),
        .align_x = .center,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (u.isElementPressed(id)) p.subtle_tertiary else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
    });
    kit.icon(glyph, 16, p.text_primary, if (glyph == .play or glyph == .pause) .filled else .regular);
    const clicked = u.justReleased();
    u.close();
    kit.tooltip(id, tip);
    return clicked;
}

/// What a compressed folder holds: its folders and files, a row each.
fn archiveView(self: *Files, kit: *Kit, m: *const Preview.Made) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    {
        u.open(.{ .width = .grow, .padding = .trbl(pad, pad, 6, pad), .gap = 10, .align_y = .center });
        defer u.close();
        icons.themed(self, kit, "package-x-generic", 32);
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2 });
        defer u.close();
        kit.label(kit.print("{d} files, {d} folders", .{ m.files, m.folders }), .body_strong, p.text_primary);
        var size_buffer: [32]u8 = undefined;
        kit.label(kit.print("{s} when extracted", .{Folder.sizeText(m.unpacked, &size_buffer)}), .caption, p.text_secondary);
    }
    if (m.entries.len == 0) return message(kit, "This folder is empty.");
    const id = "preview/archive";
    const row_h: f32 = 24;
    const s = self.window.scale;
    const scroll = u.scrollOf(id);
    const top = if (scroll) |sc| sc.position.y / s else 0;
    const view_h = if (scroll) |sc| (if (sc.viewport.height > 0) sc.viewport.height / s else 600) else 600;
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .xy(if (ten) 4 else 8, 4),
        .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
    });
    defer u.close();
    const n = m.entries.len;
    const first: usize = @min(n, @as(usize, @intFromFloat(@max(0, top / row_h))) -| 10);
    const last: usize = @min(n, first + @as(usize, @intFromFloat(view_h / row_h)) + 20);
    if (first > 0) u.empty(.{ .width = .fixed(1), .height = .fixed(@as(f32, @floatFromInt(first)) * row_h) });
    var small = kit.style(.caption, p.text_secondary);
    small.wrap = .none;
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .none;
    for (m.entries[first..last]) |e| {
        u.open(.{ .width = .grow, .height = .fixed(row_h), .gap = 6, .align_y = .center, .clip = .both });
        defer u.close();
        // Its depth, as an indent; its icon, by its kind.
        const depth = std.mem.count(u8, e.path, "/");
        u.empty(.{ .width = .fixed(@floatFromInt(@min(depth, 8) * 12)) });
        if (e.kind == .folder) icons.themed(self, kit, "folder", 16) else fileIcon(self, kit, std.fs.path.basename(e.path), 16);
        u.open(.{ .width = .grow, .clip = .both });
        u.text(std.fs.path.basename(e.path), style);
        u.close();
        if (e.kind != .folder) {
            var size_buffer: [32]u8 = undefined;
            u.text(kit.print("{s}", .{Folder.sizeText(e.size, &size_buffer)}), small);
        }
    }
    if (last < n) u.empty(.{ .width = .fixed(1), .height = .fixed(@as(f32, @floatFromInt(n - last)) * row_h) });
}

/// The icon of a file by its name alone: what its kind's icon is.
pub fn fileIcon(self: *Files, kit: *Kit, name: []const u8, size: u16) void {
    const mime = self.mime.byName(name) orelse "application/octet-stream";
    var names_buffer: [3][128]u8 = undefined;
    const names = self.mime.iconNames(mime, &names_buffer);
    for (names) |n| if (n.len > 0) if (self.window.icons.lookup(n, size)) |texture| {
        kit.ui.empty(.{ .width = .fixed(@floatFromInt(size)), .height = .fixed(@floatFromInt(size)), .image = .{ .texture = texture } });
        return;
    };
    kit.icon(.document, size, kit.theme.palette.text_secondary, .regular);
}
