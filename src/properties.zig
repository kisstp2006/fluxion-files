// SPDX-License-Identifier: BSD-2-Clause

//! Properties (Alt+Enter): what a file or a folder is, as Windows' property
//! sheet shows it - which Windows 11 kept as Windows 10 had it.
//!
//! - **General**: its icon and name; its kind and what opens it; where it
//!   is, its size and the disk it takes - a folder's counted all the way
//!   down; when it was made, changed and opened; Read-only and Hidden.
//! - **Security**: its owner and group, and what each - and everyone else -
//!   may do with it: read, write, run. Changed with Apply or OK.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const Folder = @import("Folder.zig");
const Ops = @import("Ops.zig");
const Mime = @import("Mime.zig");
const icons = @import("icons.zig");
const views = @import("views.zig");

pub const Page = enum { general, security };

/// The sheet open: for which file, on which page, what it found, what has
/// been changed and not yet applied.
pub const Sheet = struct {
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    folder: bool = false,
    mime: []const u8 = Mime.unknown,
    page: Page = .general,
    info: Ops.Info = .{},
    usage: ?Ops.Usage = null,
    /// The mode as it is to be: changed by the boxes, set by Apply.
    mode: u32 = 0,
    /// Hidden - listed in its folder's `.hidden` - as it is, and as it is
    /// to be.
    hidden: bool = false,
    hidden_was: bool = false,

    pub fn path(self: *const Sheet) []const u8 {
        return self.path_buffer[0..self.path_len];
    }
};

pub fn open(self: *Files, path: []const u8, folder: bool, mime: []const u8) void {
    var sheet: Sheet = .{ .folder = folder, .mime = mime };
    sheet.path_len = @min(path.len, sheet.path_buffer.len);
    @memcpy(sheet.path_buffer[0..sheet.path_len], path[0..sheet.path_len]);
    sheet.info = Ops.info(path) orelse .{};
    sheet.mode = sheet.info.mode;
    sheet.hidden = listedHidden(self, path);
    sheet.hidden_was = sheet.hidden;
    if (folder) sheet.usage = Ops.usage(self.io, path);
    self.properties = sheet;
    self.window.redraw();
}

/// Whether `path` is named in its folder's `.hidden`.
fn listedHidden(self: *Files, path: []const u8) bool {
    const dir = std.fs.path.dirname(path) orelse return false;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file = Ops.join(&buffer, dir, ".hidden") catch return false;
    var text_buffer: [16384]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(self.io, file, &text_buffer) catch return false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |listed| if (std.mem.eql(u8, std.mem.trimEnd(u8, listed, "\r"), std.fs.path.basename(path))) return true;
    return false;
}

fn apply(self: *Files) void {
    const sheet = &(self.properties orelse return);
    if (sheet.hidden != sheet.hidden_was) {
        const dir = std.fs.path.dirname(sheet.path()) orelse "/";
        Ops.setHidden(self.io, self.gpa, dir, &.{std.fs.path.basename(sheet.path())}, sheet.hidden) catch |err| self.notify("The item could not be hidden", err);
        sheet.hidden_was = sheet.hidden;
        self.refreshAll();
    }
    if (sheet.mode & 0o7777 != sheet.info.mode & 0o7777) {
        Ops.setMode(sheet.path(), sheet.mode) catch |err| self.notify("The permissions could not be changed", err);
        sheet.info = Ops.info(sheet.path()) orelse sheet.info;
        sheet.mode = sheet.info.mode;
    }
}

pub fn draw(self: *Files, kit: *Kit) void {
    const sheet = &(self.properties orelse return);
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    // The sheet's own grey, as a property sheet's dialog has, and its page
    // white.
    const dialog_fill = if (p.mode == .dark) widgets.argb(0xFF2B2B2B) else widgets.argb(0xFFF0F0F0);
    const page_fill = if (p.mode == .dark) widgets.argb(0xFF202020) else widgets.argb(0xFFFFFFFF);
    const edge = if (p.mode == .dark) widgets.argb(0xFF4A4A4A) else widgets.argb(0xFFD9D9D9);
    u.open(.{ .id = "properties/smoke", .width = .grow, .height = .grow, .align_x = .center, .align_y = .center, .background_color = p.smoke.withAlpha(0.15), .floating = .{ .attach = .root, .z_index = 95 } });
    defer u.close();
    u.open(.{
        .id = "properties",
        .width = .fixed(380),
        .direction = .top_to_bottom,
        .corner_radius = .all(if (ten) 0 else 8),
        .background_color = dialog_fill,
        .border = .{ .color = if (ten) widgets.argb(0xFF1979CA) else p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .clip = .both,
    });
    defer u.close();
    const name = std.fs.path.basename(sheet.path());
    // Its title bar: the name, and the close button.
    {
        u.open(.{ .width = .grow, .height = .fixed(32), .padding = .trbl(0, 0, 0, 12), .align_y = .center, .background_color = page_fill });
        defer u.close();
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .none;
        u.open(.{ .width = .grow, .clip = .both });
        u.text(kit.print("{s} Properties", .{name}), style);
        u.close();
        const close_id = "properties/close";
        u.open(.{ .id = close_id, .width = .fixed(46), .height = .grow, .align_x = .center, .align_y = .center, .background_color = if (u.isPointerOver(close_id)) p.close_hover else .transparent });
        kit.icon(.dismiss, 12, if (u.isPointerOver(close_id)) widgets.argb(0xFFFFFFFF) else p.text_primary, .regular);
        if (u.justReleased()) self.properties = null;
        u.close();
    }
    if (self.properties == null) return;
    // The page tabs.
    {
        u.open(.{ .width = .grow, .padding = .trbl(8, 8, 0, 8), .gap = 0 });
        defer u.close();
        for ([_]Page{ .general, .security }) |page| {
            const id = kit.print("properties/tab/{t}", .{page});
            const front = sheet.page == page;
            u.open(.{
                .id = id,
                .padding = .xy(10, 4),
                .background_color = if (front) page_fill else if (u.isPointerOver(id)) p.subtle_secondary else .transparent,
                .border = .{ .color = edge, .width = if (front) .{ .left = 1, .right = 1, .top = 1 } else .{ .bottom = 1 } },
            });
            kit.label(if (page == .general) "General" else "Security", .caption, p.text_primary);
            if (u.justReleased()) sheet.page = page;
            u.close();
        }
        u.empty(.{ .width = .grow, .height = .fixed(1) });
    }
    {
        u.open(.{ .width = .grow, .padding = .trbl(0, 8, 0, 8) });
        defer u.close();
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .all(14), .gap = 10, .background_color = page_fill, .border = .{ .color = edge, .width = .{ .left = 1, .right = 1, .bottom = 1 } } });
        defer u.close();
        switch (sheet.page) {
            .general => general(self, kit, sheet, edge),
            .security => security(self, kit, sheet, edge),
        }
    }
    // OK, Cancel, Apply.
    {
        u.open(.{ .width = .grow, .padding = .all(10), .gap = 8, .align_x = .right });
        defer u.close();
        if (kit.button("properties/ok", "OK", .{ .width = .fixed(80) })) {
            apply(self);
            self.properties = null;
            return;
        }
        if (kit.button("properties/cancel", "Cancel", .{ .width = .fixed(80) })) {
            self.properties = null;
            return;
        }
        if (kit.button("properties/apply", "Apply", .{ .width = .fixed(80), .disabled = sheet.mode & 0o7777 == sheet.info.mode & 0o7777 and sheet.hidden == sheet.hidden_was })) apply(self);
    }
}

fn rule(kit: *Kit, edge: ui.Color) void {
    kit.ui.empty(.{ .width = .grow, .height = .fixed(1), .background_color = edge });
}

/// A line of the sheet: its name at the left, what it is beside it.
fn line(kit: *Kit, name: []const u8, value: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .gap = 8 });
    defer u.close();
    u.open(.{ .width = .fixed(100) });
    kit.label(name, .caption, p.text_primary);
    u.close();
    u.open(.{ .width = .grow, .clip = .both });
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .words;
    u.text(value, style);
    u.close();
}

fn general(self: *Files, kit: *Kit, sheet: *Sheet, edge: ui.Color) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const name = std.fs.path.basename(sheet.path());
    {
        u.open(.{ .width = .grow, .gap = 14, .align_y = .center });
        defer u.close();
        if (sheet.folder) icons.themed(self, kit, "folder", 32) else {
            var names_buffer: [3][128]u8 = undefined;
            const names = self.mime.iconNames(sheet.mime, &names_buffer);
            var drawn = false;
            for (names) |n| if (!drawn and n.len > 0) if (self.window.icons.lookup(n, 32)) |texture| {
                u.empty(.{ .width = .fixed(32), .height = .fixed(32), .image = .{ .texture = texture } });
                drawn = true;
            };
            if (!drawn) kit.icon(.document, 32, p.text_secondary, .regular);
        }
        u.open(.{ .width = .grow, .padding = .xy(6, 4), .border = .{ .color = edge, .width = .all(1) }, .clip = .both });
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .none;
        u.text(name, style);
        u.close();
    }
    rule(kit, edge);
    var type_buffer: [64]u8 = undefined;
    const kind = self.mime.describe(sheet.mime, name, &type_buffer);
    line(kit, if (sheet.folder) "Type:" else "Type of file:", kit.print("{s}", .{kind}));
    if (!sheet.folder) if (self.installedApps()) |apps| {
        const app = self.open_with.defaultFor(apps, sheet.mime);
        // Its app, and Change... to choose another, as Windows has them.
        const row_ui = kit.ui;
        row_ui.open(.{ .width = .grow, .gap = 8, .align_y = .center });
        defer row_ui.close();
        row_ui.open(.{ .width = .fixed(100) });
        kit.label("Opens with:", .caption, p.text_primary);
        row_ui.close();
        if (app) |a| if (self.window.icons.lookup(a.icon, 16)) |texture| row_ui.empty(.{ .width = .fixed(16), .height = .fixed(16), .image = .{ .texture = texture } });
        row_ui.open(.{ .width = .grow, .clip = .both });
        kit.label(if (app) |a| kit.print("{s}", .{a.name}) else "Pick an app", .caption, p.text_primary);
        row_ui.close();
        if (kit.button("properties/change", "Change...", .{})) {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buffer, "{s}", .{sheet.path()}) catch return;
            const mime = sheet.mime;
            self.properties = null;
            return @import("chooser.zig").open(self, path, mime);
        }
    };
    rule(kit, edge);
    line(kit, "Location:", kit.print("{s}", .{std.fs.path.dirname(sheet.path()) orelse "/"}));
    var size_buffer: [32]u8 = undefined;
    var disk_buffer: [32]u8 = undefined;
    if (sheet.usage) |use| {
        line(kit, "Size:", kit.print("{s} ({d} bytes){s}", .{ Folder.sizeText(use.bytes, &size_buffer), use.bytes, if (use.partial) " or more" else "" }));
        line(kit, "Size on disk:", kit.print("{s}", .{Folder.sizeText(use.on_disk, &disk_buffer)}));
        line(kit, "Contains:", kit.print("{d} Files, {d} Folders", .{ use.files, use.folders }));
    } else {
        line(kit, "Size:", kit.print("{s} ({d} bytes)", .{ Folder.sizeText(sheet.info.size, &size_buffer), sheet.info.size }));
        line(kit, "Size on disk:", kit.print("{s}", .{Folder.sizeText(sheet.info.on_disk, &disk_buffer)}));
    }
    rule(kit, edge);
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    var c: [32]u8 = undefined;
    if (sheet.info.created) |born| line(kit, "Created:", kit.print("{s}", .{views.dateText(born, &a)}));
    line(kit, "Modified:", kit.print("{s}", .{views.dateText(sheet.info.modified, &b)}));
    line(kit, "Accessed:", kit.print("{s}", .{views.dateText(sheet.info.accessed, &c)}));
    rule(kit, edge);
    // Read-only: no one may write it; Hidden: its name starts with a dot.
    {
        u.open(.{ .width = .grow, .gap = 16, .align_y = .center });
        defer u.close();
        u.open(.{ .width = .fixed(100) });
        kit.label("Attributes:", .caption, p.text_primary);
        u.close();
        var read_only = sheet.mode & 0o222 == 0;
        if (kit.checkbox("properties/read-only", &read_only, "Read-only", .{})) {
            sheet.mode = if (read_only) sheet.mode & ~@as(u32, 0o222) else sheet.mode | 0o200;
        }
        // Hidden: by a dot in front of its name - which only a new name
        // changes - or listed in its folder's .hidden.
        if (name.len > 0 and name[0] == '.') {
            var dotted = true;
            _ = kit.checkbox("properties/hidden", &dotted, "Hidden", .{ .disabled = true });
        } else _ = kit.checkbox("properties/hidden", &sheet.hidden, "Hidden", .{});
    }
}

fn security(self: *Files, kit: *Kit, sheet: *Sheet, edge: ui.Color) void {
    _ = self;
    const u = kit.ui;
    const p = &kit.theme.palette;
    var user_buffer: [64]u8 = undefined;
    var group_buffer: [64]u8 = undefined;
    line(kit, "Object name:", kit.print("{s}", .{sheet.path()}));
    line(kit, "Owner:", kit.print("{s}", .{Ops.userName(sheet.info.uid, &user_buffer)}));
    line(kit, "Group:", kit.print("{s}", .{Ops.groupName(sheet.info.gid, &group_buffer)}));
    rule(kit, edge);
    kit.label("Permissions", .caption, p.text_primary);
    // A table: who, and read / write / run.
    {
        u.open(.{ .width = .grow, .gap = 0 });
        defer u.close();
        u.open(.{ .width = .grow });
        u.close();
        for ([_][]const u8{ "Read", "Write", if (sheet.folder) "Open" else "Run" }) |h| {
            u.open(.{ .width = .fixed(56), .align_x = .center });
            kit.label(h, .caption, p.text_secondary);
            u.close();
        }
    }
    const who = [_]struct { name: []const u8, shift: u5 }{
        .{ .name = "Owner", .shift = 6 },
        .{ .name = "Group", .shift = 3 },
        .{ .name = "Everyone else", .shift = 0 },
    };
    for (who) |w| {
        u.open(.{ .width = .grow, .height = .fixed(26), .align_y = .center, .border = .{ .color = edge, .width = .{ .top = 1 } } });
        defer u.close();
        u.open(.{ .width = .grow });
        kit.label(w.name, .caption, p.text_primary);
        u.close();
        for (0..3) |k| {
            const bit: u32 = @as(u32, 4) >> @intCast(k);
            const mask = bit << w.shift;
            var on = sheet.mode & mask != 0;
            u.open(.{ .width = .fixed(56), .align_x = .center });
            if (kit.checkbox(kit.print("properties/perm/{d}/{d}", .{ w.shift, k }), &on, "", .{})) {
                sheet.mode = if (on) sheet.mode | mask else sheet.mode & ~mask;
            }
            u.close();
        }
    }
}
