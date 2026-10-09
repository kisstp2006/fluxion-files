// SPDX-License-Identifier: BSD-2-Clause

//! The pictures of files and places, from the icon theme the desktop uses:
//! a kind's own icon ("image-png"), its generic one ("image-x-generic"),
//! then by its media - and the desktop's own glyph where the theme has none.

const std = @import("std");

const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const Folder = @import("Folder.zig");
const Places = @import("Places.zig");
const Mime = @import("Mime.zig");

/// The icon theme's name for a person's folder.
pub fn special(which: ?Places.Special) []const u8 {
    const s = which orelse return "folder";
    return switch (s) {
        .desktop => "user-desktop",
        .downloads => "folder-download",
        .documents => "folder-documents",
        .pictures => "folder-pictures",
        .music => "folder-music",
        .videos => "folder-videos",
        .templates => "folder-templates",
        .public => "folder-publicshare",
    };
}

/// The theme's icon `name`, `size` across; the desktop's own glyph if the
/// theme has none.
pub fn themed(self: *Files, kit: *Kit, name: []const u8, size: u16) void {
    if (self.window.icons.lookup(name, size)) |texture| {
        kit.ui.empty(.{ .width = .fixed(@floatFromInt(size)), .height = .fixed(@floatFromInt(size)), .image = .{ .texture = texture } });
        return;
    }
    const glyph: widgets.icons.Name = if (std.mem.startsWith(u8, name, "user-trash")) .delete else if (std.mem.startsWith(u8, name, "folder") or std.mem.startsWith(u8, name, "user-")) .folder else if (std.mem.startsWith(u8, name, "drive")) .hard_drive else .document;
    kit.icon(glyph, size, if (glyph == .folder) widgets.argb(0xFFE8B428) else kit.theme.palette.text_secondary, .filled);
}

/// An entry's picture: a folder's - a person's folder its own - or its
/// kind's.
pub fn forEntry(self: *Files, kit: *Kit, folder_path: []const u8, e: *const Folder.Entry, size: u16) void {
    if (e.isFolder()) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ if (std.mem.eql(u8, folder_path, "/")) "" else folder_path, e.name }) catch "";
        return themed(self, kit, special(self.places.specialOf(full)), size);
    }
    var names_buffer: [3][128]u8 = undefined;
    const names = self.mime.iconNames(e.mime, &names_buffer);
    for (names) |n| {
        if (n.len == 0) continue;
        if (self.window.icons.lookup(n, size)) |texture| {
            kit.ui.empty(.{ .width = .fixed(@floatFromInt(size)), .height = .fixed(@floatFromInt(size)), .image = .{ .texture = texture } });
            return;
        }
    }
    kit.icon(if (std.mem.startsWith(u8, e.mime, "image/")) .image else if (std.mem.startsWith(u8, e.mime, "video/")) .video else if (std.mem.startsWith(u8, e.mime, "audio/")) .music_note_2 else .document, size, kit.theme.palette.text_secondary, .regular);
}
