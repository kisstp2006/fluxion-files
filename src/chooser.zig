// SPDX-License-Identifier: BSD-2-Clause

//! "Choose another app": which app opens a file, as Windows asks it - from
//! Open with ▸ Choose another app, from Properties' Change..., and when no
//! app opens a kind of file yet.
//!
//! - **Windows 10's** "How do you want to open this file?": the app that
//!   opens it now under "Keep using this app", the others that say they
//!   open its kind under "Other options", "More apps" for the rest, and
//!   "Always use this app to open .png files" over OK.
//! - **Windows 11's** "Select an app to open 'photo.png' file": "Default
//!   app", "Suggested apps", "More options", "Choose an app on your PC" for
//!   the rest - and two buttons, Always and Just once.
//!
//! Always is kept in `fluxion-mimeapps.list`, the desktop's own list,
//! which Files - and every app that follows the specification - reads.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const apps_mod = @import("apps.zig");
const App = apps_mod.App;

pub const Chooser = struct {
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    mime_buffer: [128]u8 = undefined,
    mime_len: usize = 0,
    /// The app chosen in the list, by its desktop entry's id.
    chosen_buffer: [256]u8 = undefined,
    chosen_len: usize = 0,
    /// "More apps" open: every app, not only those of the file's kind.
    more: bool = false,
    /// Windows 10's "Always use this app".
    always: bool = false,

    pub fn path(self: *const Chooser) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    pub fn mime(self: *const Chooser) []const u8 {
        return self.mime_buffer[0..self.mime_len];
    }

    fn chosen(self: *const Chooser) []const u8 {
        return self.chosen_buffer[0..self.chosen_len];
    }

    fn choose(self: *Chooser, id: []const u8) void {
        self.chosen_len = @min(id.len, self.chosen_buffer.len);
        @memcpy(self.chosen_buffer[0..self.chosen_len], id[0..self.chosen_len]);
    }
};

/// Ask which app opens `path`, of kind `mime`.
pub fn open(self: *Files, path: []const u8, mime: []const u8) void {
    self.menu = .none;
    self.context_open = null;
    var c: Chooser = .{};
    c.path_len = @min(path.len, c.path_buffer.len);
    @memcpy(c.path_buffer[0..c.path_len], path[0..c.path_len]);
    c.mime_len = @min(mime.len, c.mime_buffer.len);
    @memcpy(c.mime_buffer[0..c.mime_len], mime[0..c.mime_len]);
    // The app that opens it now chosen, to keep using.
    if (self.installedApps()) |installed| if (self.open_with.defaultFor(installed, mime)) |app| c.choose(app.id);
    self.chooser = c;
    self.window.redraw();
}

/// The one file chosen, asked about.
pub fn openForChosen(self: *Files) void {
    const t = self.tab();
    const i = t.current() orelse return;
    const e = t.entry(i);
    const dir = t.dirOf(e) orelse return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = @import("Ops.zig").join(&buffer, dir, e.name) catch return;
    open(self, full, e.mime);
}

/// The app chosen: the file opened in it - and, Always, its kind from
/// now on.
fn decide(self: *Files, always: bool) void {
    const c = &(self.chooser orelse return);
    const installed = self.installedApps() orelse return;
    const app = installed.find(c.chosen()) orelse return;
    if (always) self.open_with.setDefault(self.io, c.mime(), app.id) catch |err| self.notify("The app could not be made the default", err);
    apps_mod.runWith(self.gpa, self.io, app.name, app.exec, c.path());
    self.chooser = null;
}

/// The extension Windows names: ".png" - or the kind, for a name with none.
fn extensionOf(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return if (dot == 0) "" else name[dot..];
}

pub fn draw(self: *Files, kit: *Kit) void {
    const c = &(self.chooser orelse return);
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const installed = self.installedApps() orelse return;
    u.open(.{ .id = "chooser/smoke", .width = .grow, .height = .grow, .align_x = .center, .align_y = .center, .background_color = p.smoke.withAlpha(0.2), .floating = .{ .attach = .root, .z_index = 93 } });
    defer u.close();
    // A press beside it: asked no more, as Windows' goes.
    if (u.justPressed() and !u.isPointerOver("chooser")) {
        self.chooser = null;
        return;
    }
    u.open(.{
        .id = "chooser",
        .width = .fixed(if (ten) 400 else 440),
        .direction = .top_to_bottom,
        .corner_radius = .all(if (ten) 0 else 8),
        .background_color = if (ten) p.solid_base else p.solid_base,
        .border = .{ .color = if (ten) (if (p.mode == .dark) widgets.argb(0xFF4A4A4A) else widgets.argb(0xFFBDBDBD)) else p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .clip = .both,
    });
    defer u.close();
    {
        u.open(.{ .width = .grow, .padding = .trbl(20, 20, 10, 20) });
        defer u.close();
        var style = kit.style(if (ten) .subtitle else .body_strong, p.text_primary);
        style.wrap = .words;
        if (!ten) style.font_size = 20;
        u.text(if (ten) "How do you want to open this file?" else kit.print("Select an app to open \u{2018}{s}\u{2019} file", .{std.fs.path.basename(c.path())}), style);
    }
    // The apps: the default, those that say they open this kind, the rest.
    var suggested: [16]*const App = undefined;
    const found = self.open_with.appsFor(installed, c.mime(), &suggested);
    const current = self.open_with.defaultFor(installed, c.mime());
    {
        u.open(.{
            .id = "chooser/list",
            .width = .grow,
            .height = .{ .kind = .fit, .max = 380 },
            .direction = .top_to_bottom,
            .padding = .xy(if (ten) 0 else 8, 0),
            .gap = if (ten) 0 else 2,
            .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
        });
        defer u.close();
        if (current) |app| {
            heading(self, kit, if (ten) "Keep using this app" else "Default app");
            appRow(self, kit, c, app, true);
        }
        var others: usize = 0;
        for (found) |app| if (current != app) {
            others += 1;
        };
        if (others > 0) {
            heading(self, kit, if (ten) "Other options" else "Suggested apps");
            for (found) |app| if (current != app) appRow(self, kit, c, app, ten);
        }
        if (c.more) {
            if (!ten) heading(self, kit, "More options");
            for (installed.list) |*app| {
                if (app.terminal or app.exec.len == 0) continue;
                const listed = for (found) |f| {
                    if (f == app) break true;
                } else false;
                if (listed) continue;
                appRow(self, kit, c, app, ten);
            }
        }
    }
    // "More apps", or "Choose an app on your PC": every app.
    if (!c.more) {
        const id = "chooser/more";
        u.open(.{ .id = id, .width = .grow, .padding = .xy(20, 8), .gap = 6, .align_y = .center });
        defer u.close();
        const blue = if (p.mode == .dark) widgets.argb(0xFF6CB4F2) else widgets.argb(0xFF0066CC);
        var style = kit.style(.caption, if (u.isPointerOver(id)) p.text_primary else if (ten) blue else p.accent_text);
        style.wrap = .none;
        u.text(if (ten) "More apps" else "Choose an app on your PC", style);
        if (ten) kit.icon(.chevron_down, 10, blue, .regular);
        if (u.justReleased()) c.more = true;
    }
    if (ten) {
        {
            u.open(.{ .width = .grow, .padding = .xy(20, 6) });
            defer u.close();
            const ext = extensionOf(c.path());
            _ = kit.checkbox("chooser/always", &c.always, if (ext.len > 0) kit.print("Always use this app to open {s} files", .{ext}) else "Always use this app to open files of this kind", .{});
        }
        u.open(.{ .width = .grow, .padding = .trbl(10, 20, 20, 20), .align_x = .right });
        defer u.close();
        if (kit.button("chooser/ok", "OK", .{ .width = .fixed(150), .disabled = c.chosen_len == 0 })) decide(self, c.always);
        return;
    }
    u.open(.{ .width = .grow, .padding = .all(16), .gap = 8, .background_color = p.solid_secondary, .border = .{ .color = p.divider, .width = .{ .top = 1 } } });
    defer u.close();
    if (kit.button("chooser/always", "Always", .{ .width = .grow, .disabled = c.chosen_len == 0 })) return decide(self, true);
    if (kit.button("chooser/once", "Just once", .{ .kind = .accent, .width = .grow, .disabled = c.chosen_len == 0 })) decide(self, false);
}

fn heading(self: *Files, kit: *Kit, text: []const u8) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .padding = .trbl(10, if (self.ten()) 20 else 10, 4, if (self.ten()) 20 else 10) });
    defer u.close();
    kit.label(text, .caption, kit.theme.palette.text_secondary);
}

/// An app of the list: its icon and name - and, where `described`, what
/// its entry says of it. Chosen, Windows 10's is the accent, Windows 11's
/// lit with the accent's bar at its left.
fn appRow(self: *Files, kit: *Kit, c: *Chooser, app: *const App, described: bool) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const id = kit.print("chooser/app/{s}", .{app.id});
    const chosen = std.mem.eql(u8, c.chosen(), app.id);
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .grow,
        .padding = .xy(if (ten) 20 else 12, if (described and app.comment.len > 0) 8 else 6),
        .gap = 12,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (chosen) (if (ten) p.accent else p.subtle_secondary) else if (hovered) (if (ten) (if (p.mode == .dark) widgets.argb(0xFF3E3E3E) else widgets.argb(0xFFE5E5E5)) else p.subtle_secondary) else .transparent,
    });
    defer u.close();
    if (!ten and chosen) u.empty(.{ .width = .fixed(3), .height = .fixed(16), .corner_radius = .all(2), .background_color = p.accent, .floating = .{ .attach = .parent, .fractions = .{ .element_x = 0, .element_y = 0.5, .target_x = 0, .target_y = 0.5 } } });
    const size: u16 = if (ten) 32 else 24;
    if (self.window.icons.lookup(app.icon, size)) |texture| {
        u.empty(.{ .width = .fixed(@floatFromInt(size)), .height = .fixed(@floatFromInt(size)), .image = .{ .texture = texture } });
    } else kit.icon(.apps, size, p.text_secondary, .regular);
    const ink = if (chosen and ten) p.text_on_accent else p.text_primary;
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2 });
    var style = kit.style(.body, ink);
    style.wrap = .none;
    u.text(app.name, style);
    if (described and app.comment.len > 0) {
        var small = kit.style(.caption, if (chosen and ten) p.text_on_accent else p.text_secondary);
        small.wrap = .words;
        u.text(app.comment, small);
    }
    u.close();
    if (u.justPressed()) {
        c.choose(app.id);
        // A double click: that one, as OK - or Just once - would.
        if (self.window.clickCount() >= 2) decide(self, ten and c.always);
    }
}
