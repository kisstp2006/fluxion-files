// SPDX-License-Identifier: BSD-2-Clause

//! How Files is set up, as Windows' Folder Options sets File Explorer up -
//! General, View and Search - and the rest it keeps between windows: the
//! panes' widths, Windows 10's Quick Access Toolbar. Kept in
//! `$XDG_CONFIG_HOME/fluxion/files.ini`, written whenever it changes and
//! read by every window as it starts.
//!
//! ```
//! [general]
//! open_to=home
//! single_click=false
//! [view]
//! hidden=false
//! extensions=true
//! [window]
//! preview_width=320
//! ```

const std = @import("std");

const Prefs = @This();

const log = std.log.scoped(.prefs);

pub const OpenTo = enum { home, this_pc };
/// The pane on the right: the details pane, the preview pane, or neither.
pub const Pane = enum { none, details, preview };
/// Single-click's underline: always, or under the pointer alone.
pub const Underline = enum { always, hover };

/// Windows 10's Quick Access Toolbar: which of its buttons are on it.
pub const Qat = struct {
    undo: bool = false,
    redo: bool = false,
    delete: bool = false,
    properties: bool = true,
    new_folder: bool = true,
    rename: bool = false,

    /// As the file has it: a bit each, in this order.
    fn bits(self: Qat) u8 {
        var out: u8 = 0;
        inline for (@typeInfo(Qat).@"struct".fields, 0..) |f, i| {
            if (@field(self, f.name)) out |= 1 << i;
        }
        return out;
    }

    fn fromBits(value: u8) Qat {
        var out: Qat = .{};
        inline for (@typeInfo(Qat).@"struct".fields, 0..) |f, i| @field(out, f.name) = value & (1 << i) != 0;
        return out;
    }
};

// -- General --
open_to: OpenTo = .home,
/// Each folder in a window of its own, rather than in the same one.
own_window: bool = false,
single_click: bool = false,
underline: Underline = .hover,
show_recent: bool = true,
show_frequent: bool = true,
show_favorites: bool = true,

// -- View: the advanced settings --
/// Icons, never thumbnails.
always_icons: bool = false,
/// The pointer resting on an item: what it is, in a tip.
infotips: bool = true,
/// A folder's tip says how big it is and what is in it.
folder_size_tips: bool = true,
full_path_title: bool = false,
hidden: bool = false,
extensions: bool = true,
hide_empty_drives: bool = true,
preview_handlers: bool = true,
status_bar: bool = true,
check_boxes: bool = false,
/// The navigation pane opens its tree to the folder shown.
expand_to_open: bool = false,
/// The navigation pane lists everything: the home folder, the Recycle Bin.
show_all_folders: bool = false,

// -- Search --
/// Into compressed folders too.
search_archives: bool = false,
/// File names and what is in the files.
search_contents: bool = false,
/// System folders too: `/usr`, `/etc`.
search_system: bool = false,

// -- The window --
pane: Pane = .none,
navigation: bool = true,
preview_width: f32 = 320,
/// The progress dialog with its graph: "More details".
transfer_details: bool = false,
details_width: f32 = 300,
qat: Qat = .{},

/// Where the file is.
pub fn path(buffer: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |dir| return std.fmt.bufPrint(buffer, "{s}/fluxion/files.ini", .{std.mem.span(dir)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/fluxion/files.ini", .{std.mem.span(home)}) catch null;
}

pub fn load(io: std.Io) Prefs {
    var self: Prefs = .{};
    var buffer: [512]u8 = undefined;
    const file = path(&buffer) orelse return self;
    var text_buffer: [16384]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, file, &text_buffer) catch return self;
    self.parse(text);
    return self;
}

/// What each key of the file is, by its section and name.
const Key = struct { section: []const u8, name: []const u8, field: []const u8 };

const keys = [_]Key{
    .{ .section = "general", .name = "open_to", .field = "open_to" },
    .{ .section = "general", .name = "own_window", .field = "own_window" },
    .{ .section = "general", .name = "single_click", .field = "single_click" },
    .{ .section = "general", .name = "underline", .field = "underline" },
    .{ .section = "general", .name = "show_recent", .field = "show_recent" },
    .{ .section = "general", .name = "show_frequent", .field = "show_frequent" },
    .{ .section = "general", .name = "show_favorites", .field = "show_favorites" },
    .{ .section = "view", .name = "always_icons", .field = "always_icons" },
    .{ .section = "view", .name = "infotips", .field = "infotips" },
    .{ .section = "view", .name = "folder_size_tips", .field = "folder_size_tips" },
    .{ .section = "view", .name = "full_path_title", .field = "full_path_title" },
    .{ .section = "view", .name = "hidden", .field = "hidden" },
    .{ .section = "view", .name = "extensions", .field = "extensions" },
    .{ .section = "view", .name = "hide_empty_drives", .field = "hide_empty_drives" },
    .{ .section = "view", .name = "preview_handlers", .field = "preview_handlers" },
    .{ .section = "view", .name = "status_bar", .field = "status_bar" },
    .{ .section = "view", .name = "check_boxes", .field = "check_boxes" },
    .{ .section = "view", .name = "expand_to_open", .field = "expand_to_open" },
    .{ .section = "view", .name = "show_all_folders", .field = "show_all_folders" },
    .{ .section = "search", .name = "archives", .field = "search_archives" },
    .{ .section = "search", .name = "contents", .field = "search_contents" },
    .{ .section = "search", .name = "system", .field = "search_system" },
    .{ .section = "window", .name = "pane", .field = "pane" },
    .{ .section = "window", .name = "navigation", .field = "navigation" },
    .{ .section = "window", .name = "preview_width", .field = "preview_width" },
    .{ .section = "window", .name = "transfer_details", .field = "transfer_details" },
    .{ .section = "window", .name = "details_width", .field = "details_width" },
    .{ .section = "window", .name = "qat", .field = "qat" },
};

pub fn parse(self: *Prefs, text: []const u8) void {
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            section = std.mem.trim(u8, line, "[]");
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        inline for (keys) |k| {
            if (std.mem.eql(u8, k.section, section) and std.mem.eql(u8, k.name, name)) self.set(k.field, value);
        }
    }
}

fn set(self: *Prefs, comptime field: []const u8, value: []const u8) void {
    const T = @TypeOf(@field(self, field));
    switch (@typeInfo(T)) {
        .bool => @field(self, field) = std.mem.eql(u8, value, "true"),
        .@"enum" => @field(self, field) = std.meta.stringToEnum(T, value) orelse @field(self, field),
        .float => @field(self, field) = std.fmt.parseFloat(f32, value) catch @field(self, field),
        .@"struct" => @field(self, field) = Qat.fromBits(std.fmt.parseInt(u8, value, 10) catch @field(self, field).bits()),
        else => {},
    }
}

/// The file as it is to be written.
pub fn format(self: *const Prefs, w: *std.Io.Writer) !void {
    var section: []const u8 = "";
    inline for (keys) |k| {
        if (!std.mem.eql(u8, section, k.section)) {
            if (section.len > 0) try w.writeByte('\n');
            try w.print("[{s}]\n", .{k.section});
            section = k.section;
        }
        const value = @field(self, k.field);
        switch (@typeInfo(@TypeOf(value))) {
            .bool => try w.print("{s}={s}\n", .{ k.name, if (value) "true" else "false" }),
            .@"enum" => try w.print("{s}={t}\n", .{ k.name, value }),
            .float => try w.print("{s}={d:.0}\n", .{ k.name, value }),
            .@"struct" => try w.print("{s}={d}\n", .{ k.name, value.bits() }),
            else => {},
        }
    }
}

/// Written to its file, the folder made if it is not there.
pub fn save(self: *const Prefs, io: std.Io) void {
    var buffer: [512]u8 = undefined;
    const file = path(&buffer) orelse return;
    var text_buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&text_buffer);
    self.format(&w) catch return;
    if (std.fs.path.dirname(file)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = w.buffered() }) catch |err| log.warn("could not save {s}: {t}", .{ file, err });
}

test "what is written is read back" {
    var prefs: Prefs = .{ .open_to = .this_pc, .single_click = true, .preview_width = 412, .qat = .{ .undo = true, .redo = true } };
    prefs.search_archives = true;
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try prefs.format(&w);
    var back: Prefs = .{};
    back.parse(w.buffered());
    try std.testing.expectEqual(OpenTo.this_pc, back.open_to);
    try std.testing.expect(back.single_click);
    try std.testing.expect(back.search_archives);
    try std.testing.expectEqual(@as(f32, 412), back.preview_width);
    try std.testing.expect(back.qat.undo and back.qat.redo and back.qat.properties);
}
