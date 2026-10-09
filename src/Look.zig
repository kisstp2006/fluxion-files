// SPDX-License-Identifier: BSD-2-Clause

//! The desktop's look as Settings chose it: light or dark, the accent,
//! Windows 11's look or Windows 10's, the corners and transparency - read
//! from `$XDG_CONFIG_HOME/fluxion/settings.ini`, where Settings writes it,
//! and read again whenever that file changes. Files only reads it.

const std = @import("std");
const linux = std.os.linux;

const widgets = @import("fluxion_widgets");

const Look = @This();

pub const Mode = enum { light, dark };
pub const Style = enum { win11, win10 };

mode: Mode = .light,
accent: u32 = 0xFF1F6FCC,
style: Style = .win11,
rounded_corners: bool = true,
transparency: bool = true,
animations: bool = true,

/// Where the file is.
pub fn path(buffer: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |dir| return std.fmt.bufPrint(buffer, "{s}/fluxion/settings.ini", .{std.mem.span(dir)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buffer, "{s}/.config/fluxion/settings.ini", .{std.mem.span(home)}) catch null;
}

/// What the file says now, or the defaults for what it does not.
pub fn load(io: std.Io) Look {
    var self: Look = .{};
    var buffer: [512]u8 = undefined;
    const file = path(&buffer) orelse return self;
    var text_buffer: [16384]u8 = undefined;
    const text = std.Io.Dir.cwd().readFile(io, file, &text_buffer) catch return self;
    self.parse(text);
    return self;
}

pub fn parse(self: *Look, text: []const u8) void {
    const eql = std.mem.eql;
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            section = std.mem.trim(u8, line, "[]");
            continue;
        }
        if (!eql(u8, section, "appearance")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " ");
        const value = std.mem.trim(u8, line[eq + 1 ..], " ");
        if (eql(u8, key, "mode")) self.mode = std.meta.stringToEnum(Mode, value) orelse self.mode;
        if (eql(u8, key, "accent")) self.accent = parseColour(value) orelse self.accent;
        if (eql(u8, key, "style")) self.style = std.meta.stringToEnum(Style, value) orelse self.style;
        if (eql(u8, key, "rounded_corners")) self.rounded_corners = !eql(u8, value, "false");
        if (eql(u8, key, "transparency")) self.transparency = !eql(u8, value, "false");
        if (eql(u8, key, "animations")) self.animations = !eql(u8, value, "false");
    }
}

/// "#RRGGBB" as 0xFFRRGGBB.
fn parseColour(text: []const u8) ?u32 {
    const hex = if (std.mem.startsWith(u8, text, "#")) text[1..] else text;
    if (hex.len != 6) return null;
    const rgb = std.fmt.parseInt(u32, hex, 16) catch return null;
    return 0xFF000000 | rgb;
}

pub fn widgetsMode(self: Look) widgets.Mode {
    return switch (self.mode) {
        .light => .light,
        .dark => .dark,
    };
}

pub fn widgetsAccent(self: Look) widgets.theme.Accent {
    return widgets.Accent.from(widgets.argb(self.accent));
}

/// The look as the widgets draw it.
pub fn widgetsLook(self: Look) widgets.theme.Look {
    return .{
        .style = switch (self.style) {
            .win11 => .win11,
            .win10 => .win10,
        },
        .rounded = self.rounded_corners,
        .transparency = self.transparency,
    };
}

/// A watch on the file's folder, for `changed`; null where there is none.
pub fn watch(io: std.Io) ?std.c.fd_t {
    var buffer: [512]u8 = undefined;
    const file = path(&buffer) orelse return null;
    const dir = std.fs.path.dirname(file) orelse return null;
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var dir_z: [513]u8 = undefined;
    @memcpy(dir_z[0..dir.len], dir);
    dir_z[dir.len] = 0;
    const fd: isize = @bitCast(linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC));
    if (fd < 0) return null;
    const mask = linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.DELETE | linux.IN.MOVED_FROM;
    const added: isize = @bitCast(linux.inotify_add_watch(@intCast(fd), @ptrCast(&dir_z), mask));
    if (added < 0) {
        _ = std.c.close(@intCast(fd));
        return null;
    }
    return @intCast(fd);
}

/// Whether what the watch heard was of the settings file.
pub fn changed(fd: std.c.fd_t) bool {
    var ours = false;
    var buffer: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    while (true) {
        const n = std.c.read(fd, &buffer, buffer.len);
        if (n <= 0) break;
        var at: usize = 0;
        while (at + @sizeOf(linux.inotify_event) <= @as(usize, @intCast(n))) {
            const event: *const linux.inotify_event = @ptrCast(@alignCast(&buffer[at]));
            if (event.getName()) |name| {
                if (std.mem.eql(u8, name, "settings.ini")) ours = true;
            }
            at += @sizeOf(linux.inotify_event) + event.len;
        }
    }
    return ours;
}

test "the look is read from Settings' file" {
    var look: Look = .{};
    look.parse("[appearance]\nmode=dark\naccent=#E81123\nstyle=win10\ntransparency=false\n[desktop]\nmode=light\n");
    try std.testing.expectEqual(Mode.dark, look.mode);
    try std.testing.expectEqual(@as(u32, 0xFFE81123), look.accent);
    try std.testing.expectEqual(Style.win10, look.style);
    try std.testing.expect(!look.transparency);
}
