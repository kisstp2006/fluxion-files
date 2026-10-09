// SPDX-License-Identifier: BSD-2-Clause

//! The panes on the right of the folder, one at a time, as Windows has
//! them:
//!
//! - **the details pane** (Alt+Shift+P): what is chosen, large, and what it
//!   is - its name and kind, its size, when it was changed and made, a
//!   picture's size in pixels; with nothing chosen, the folder and how
//!   many items it holds;
//! - **the preview pane** (Alt+P): the chosen file itself - a picture
//!   shown, a text's first lines - or "No preview available."

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const Ops = @import("Ops.zig");
const chrome = @import("chrome.zig");
const icons = @import("icons.zig");
const views = @import("views.zig");
const win10 = @import("win10.zig");

pub const width = 300;

pub fn pane(self: *Files, kit: *Kit) void {
    if (self.pane == .none) return;
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{
        .id = "pane",
        .width = .fixed(width),
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .all(16),
        .gap = 12,
        .background_color = chrome.contentColor(kit),
        .border = .{ .color = if (self.ten()) win10.edgeColor(kit) else p.divider, .width = .{ .left = 1 } },
        .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
    });
    defer u.close();
    switch (self.pane) {
        .none => {},
        .details => details(self, kit),
        .preview => preview(self, kit),
    }
}

/// The full path of the one item chosen, if one is.
fn chosenPath(self: *Files, buffer: []u8) ?struct { path: []const u8, entry: *Folder.Entry } {
    const t = self.tab();
    if (t.selectedCount() != 1) return null;
    const i = t.current() orelse return null;
    const e = t.entry(i);
    const dir = t.dirOf(e) orelse return null;
    const full = Ops.join(buffer, dir, e.name) catch return null;
    return .{ .path = full, .entry = e };
}

fn details(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const t = self.tab();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const chosen = t.selectedCount();
    if (chosen == 0 or !t.lists()) {
        // The folder itself.
        u.open(.{ .width = .grow, .align_x = .center, .padding = .xy(0, 24) });
        icons.themed(self, kit, "folder", 96);
        u.close();
        var buffer: [256]u8 = undefined;
        kit.label(self.titleOf(t, &buffer), .subtitle, p.text_primary);
        if (t.lists()) kit.label(kit.print("{d} items", .{t.count()}), .caption, p.text_secondary);
        return;
    }
    if (chosen > 1) {
        u.open(.{ .width = .grow, .align_x = .center, .padding = .xy(0, 24) });
        icons.themed(self, kit, "folder-documents", 96);
        u.close();
        kit.label(kit.print("{d} items selected", .{chosen}), .subtitle, p.text_primary);
        var size_buffer: [32]u8 = undefined;
        property(kit, "Size", Folder.sizeText(t.selectedSize(), &size_buffer));
        return;
    }
    const one = chosenPath(self, &path_buffer) orelse return;
    const e = one.entry;
    // The picture itself, where it is one; its icon otherwise.
    u.open(.{ .width = .grow, .align_x = .center, .padding = .xy(0, 12) });
    if (self.thumbs.picture(&self.window.icons, one.path, width - 32, 220)) |texture| {
        const s = self.thumbs.size;
        const scale = self.window.scale;
        u.empty(.{ .width = .fixed(@as(f32, @floatFromInt(s[0])) / scale), .height = .fixed(@as(f32, @floatFromInt(s[1])) / scale), .image = .{ .texture = texture }, .corner_radius = .all(if (self.ten()) 0 else 4) });
    } else {
        icons.forEntry(self, kit, t.dirOf(e) orelse "/", e, 96);
    }
    u.close();
    {
        var style = kit.style(.subtitle, p.text_primary);
        style.wrap = .words;
        u.text(e.name, style);
    }
    var type_buffer: [64]u8 = undefined;
    kit.label(kit.print("{s}", .{self.mime.describe(e.mime, e.name, &type_buffer)}), .caption, p.text_secondary);
    u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = p.divider });
    kit.label("Properties", .body_strong, p.text_primary);
    var size_buffer: [32]u8 = undefined;
    if (!e.isFolder()) property(kit, "Size", kit.print("{s}", .{Folder.sizeText(e.size, &size_buffer)}));
    var date_buffer: [32]u8 = undefined;
    property(kit, "Date modified", kit.print("{s}", .{views.dateText(e.mtime, &date_buffer)}));
    if (Ops.created(self.io, one.path)) |born| {
        var born_buffer: [32]u8 = undefined;
        property(kit, "Date created", kit.print("{s}", .{views.dateText(born, &born_buffer)}));
    }
    if (std.mem.startsWith(u8, e.mime, "image/") and self.thumbs.source_size[0] > 0 and !self.thumbs.failed) {
        property(kit, "Dimensions", kit.print("{d} x {d}", .{ self.thumbs.source_size[0], self.thumbs.source_size[1] }));
    }
    property(kit, "Location", kit.print("{s}", .{t.dirOf(e) orelse ""}));
}

/// A property: its name over what it is.
fn property(kit: *Kit, name: []const u8, value: []const u8) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .gap = 2 });
    defer u.close();
    kit.label(name, .caption, p.text_secondary);
    var style = kit.style(.caption, p.text_primary);
    style.wrap = .words;
    u.text(value, style);
}

fn preview(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const one = chosenPath(self, &path_buffer) orelse {
        centred(kit, "Select a file to preview.");
        return;
    };
    const e = one.entry;
    if (self.thumbs.picture(&self.window.icons, one.path, width - 32, 600)) |texture| {
        const s = self.thumbs.size;
        const scale = self.window.scale;
        u.open(.{ .width = .grow, .align_x = .center });
        u.empty(.{ .width = .fixed(@as(f32, @floatFromInt(s[0])) / scale), .height = .fixed(@as(f32, @floatFromInt(s[1])) / scale), .image = .{ .texture = texture } });
        u.close();
        return;
    }
    if (!e.isFolder() and isText(e.mime) and e.size > 0) {
        var buffer: [4096]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(self.io, one.path, &buffer) catch "";
        // Only what is UTF-8, to the last whole character.
        var end = text.len;
        while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
        var style = kit.style(.caption, p.text_primary);
        style.wrap = .words;
        u.text(kit.print("{s}", .{text[0..end]}), style);
        return;
    }
    centred(kit, "No preview available.");
}

fn isText(mime: []const u8) bool {
    if (std.mem.startsWith(u8, mime, "text/")) return true;
    const texts = [_][]const u8{ "application/json", "application/xml", "application/x-shellscript", "application/javascript", "application/x-yaml", "application/toml" };
    for (texts) |t| if (std.mem.eql(u8, mime, t)) return true;
    return false;
}

fn centred(kit: *Kit, text: []const u8) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .height = .grow, .align_x = .center, .align_y = .center });
    defer u.close();
    kit.label(text, .caption, kit.theme.palette.text_secondary);
}
