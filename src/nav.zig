// SPDX-License-Identifier: BSD-2-Clause

//! The navigation pane down the left:
//! - Home (Windows 10's: Quick access), then the person's folders and the
//!   ones pinned, each with a pin;
//! - This PC, opening to its drives;
//! - Network.
//!
//! The place shown is lit, as Windows lights it.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Places = @import("Places.zig");
const chrome = @import("chrome.zig");
const icons = @import("icons.zig");

pub fn pane(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    u.open(.{
        .id = "nav",
        .width = .fixed(self.nav_width),
        .height = .grow,
        .direction = .top_to_bottom,
        .padding = .trbl(if (ten) 2 else 4, if (ten) 0 else 4, 4, if (ten) 0 else 4),
        .gap = 0,
        .background_color = chrome.contentColor(kit),
        .border = .{ .color = p.divider, .width = .{ .right = 1 } },
        .clip = .{ .vertical = true, .scroll_y = true, .no_drag_scroll = true },
    });
    defer u.close();
    var to: ?Tab.Location = null;
    var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const t = self.tab();
    const here = t.location;

    if (item(self, kit, "nav/home", 0, if (ten) .star else .home, null, if (ten) "Quick access" else "Home", here == .home, null)) to = .home;
    if (!ten) separator(kit);
    // The person's folders, pinned as Windows pins them by default, and
    // GTK's bookmarks after them.
    for (self.places.user.items, 0..) |f, i| {
        const lit = here == .folder and std.mem.eql(u8, here.folder, f.path);
        if (item(self, kit, kit.print("nav/user/{d}", .{i}), if (ten) 1 else 0, null, icons.special(f.special), f.name, lit, true)) to = .{ .folder = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch f.path };
    }
    for (self.places.pinned.items, 0..) |f, i| {
        const lit = here == .folder and std.mem.eql(u8, here.folder, f.path);
        if (item(self, kit, kit.print("nav/pin/{d}", .{i}), if (ten) 1 else 0, null, "folder", f.name, lit, true)) to = .{ .folder = std.fmt.bufPrint(&to_buffer, "{s}", .{f.path}) catch f.path };
    }
    if (!ten) separator(kit);
    {
        const lit = here == .this_pc;
        if (expandable(self, kit, "nav/pc", .desktop, "This PC", lit, &self.this_pc_open)) to = .this_pc;
        if (self.this_pc_open) {
            for (self.places.drives.items, 0..) |d, i| {
                const is_here = here == .folder and std.mem.eql(u8, here.folder, d.mount);
                var name_buffer: [256]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buffer, "{s} ({s})", .{ d.label, d.mount }) catch d.label;
                if (item(self, kit, kit.print("nav/drive/{d}", .{i}), 1, null, if (d.removable) "drive-removable-media" else "drive-harddisk", name, is_here, null)) to = .{ .folder = std.fmt.bufPrint(&to_buffer, "{s}", .{d.mount}) catch d.mount };
            }
        }
    }
    _ = item(self, kit, "nav/network", 0, .globe, null, "Network", false, null);
    if (to) |where| self.goTo(where);
}

fn separator(kit: *Kit) void {
    const u = kit.ui;
    u.open(.{ .width = .grow, .padding = .xy(8, 6) });
    u.empty(.{ .width = .grow, .height = .fixed(1), .background_color = kit.theme.palette.divider });
    u.close();
}

/// A row: a glyph or a themed icon, the name; lit where it is shown. A
/// pinned one has the pin at its end, as Windows 11's has. True when
/// clicked.
fn item(self: *Files, kit: *Kit, id: []const u8, depth: u8, glyph: ?widgets.icons.Name, icon_name: ?[]const u8, name: []const u8, lit: bool, pinned: ?bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(if (ten) 24 else 32),
        .padding = .trbl(0, 8, 0, 8 + 16 * @as(u16, depth)),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (lit)
            (if (ten) win10Selection(kit) else p.subtle_secondary)
        else if (u.isElementPressed(id))
            p.subtle_tertiary
        else if (hovered)
            (if (ten) win10Hover(kit) else p.subtle_secondary)
        else
            .transparent,
    });
    defer u.close();
    // Windows 11 leaves room where a tree's chevron would be.
    if (!ten) u.empty(.{ .width = .fixed(12) });
    if (glyph) |g| kit.icon(g, 16, if (g == .star) widgets.argb(0xFF2B88D8) else if (g == .home) p.accent_text else p.text_primary, .regular);
    if (icon_name) |n| icons.themed(self, kit, n, 16);
    u.open(.{ .width = .grow, .clip = .both });
    var style = kit.style(.body, p.text_primary);
    style.wrap = .none;
    u.text(name, style);
    u.close();
    if (pinned != null and !ten) kit.icon(.pin, 12, p.text_secondary, .regular);
    return u.justReleased();
}

/// A row that opens to more under it: its chevron opens or closes it, the
/// rest goes there.
fn expandable(self: *Files, kit: *Kit, id: []const u8, glyph: widgets.icons.Name, name: []const u8, lit: bool, open: *bool) bool {
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    const hovered = u.isPointerOver(id);
    u.open(.{
        .id = id,
        .width = .grow,
        .height = .fixed(if (ten) 24 else 32),
        .padding = .xy(if (ten) 2 else 4, 0),
        .gap = 8,
        .align_y = .center,
        .corner_radius = .all(if (ten) 0 else 4),
        .background_color = if (lit) (if (ten) win10Selection(kit) else p.subtle_secondary) else if (hovered) (if (ten) win10Hover(kit) else p.subtle_secondary) else .transparent,
    });
    defer u.close();
    const chevron_id = kit.print("{s}/chevron", .{id});
    u.open(.{ .id = chevron_id, .width = .fixed(16), .height = .fixed(16), .align_x = .center, .align_y = .center });
    if (hovered or !ten or open.*) kit.icon(if (open.*) .chevron_down else .chevron_right, 12, p.text_secondary, .regular);
    const toggled = u.justReleased();
    u.close();
    if (toggled) {
        open.* = !open.*;
        return false;
    }
    kit.icon(glyph, 16, p.text_primary, .regular);
    var style = kit.style(.body, p.text_primary);
    style.wrap = .none;
    u.text(name, style);
    u.empty(.{ .width = .grow });
    return u.justReleased() and !u.isPointerOver(chevron_id);
}

/// Windows 10's: light blue for what is chosen and under the pointer.
pub fn win10Selection(kit: *Kit) ui.Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF777777) else widgets.argb(0xFFCCE8FF);
}

pub fn win10Hover(kit: *Kit) ui.Color {
    return if (kit.theme.palette.mode == .dark) widgets.argb(0xFF4D4D4D) else widgets.argb(0xFFE5F3FF);
}
