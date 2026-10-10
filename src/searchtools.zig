// SPDX-License-Identifier: BSD-2-Clause

//! What refines a search, as Windows offers it: Windows 10's Search Tools
//! tab - Date modified, Kind, Size, Other properties, Recent searches,
//! Advanced options - and Windows 11's "Search options" in the command bar
//! while a search is shown. Each writes Windows' own words into the search
//! box - `datemodified:this week`, `kind:=picture`, `size:large` - as
//! Windows does, so what is searched for can be read, and typed.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const menus = @import("menus.zig");

/// Which of the menus: Windows 11's, all of them; Windows 10's, each under
/// its button.
pub const Which = enum { all, date, kind, size, other, advanced, recent };

const dates = [_][2][]const u8{
    .{ "Today", "today" },           .{ "Yesterday", "yesterday" },   .{ "This week", "this week" },
    .{ "Last week", "last week" },   .{ "This month", "this month" }, .{ "Last month", "last month" },
    .{ "This year", "this year" },   .{ "Last year", "last year" },
};

const kinds = [_][2][]const u8{
    .{ "Document", "document" }, .{ "Folder", "folder" }, .{ "Movie", "video" },     .{ "Music", "music" },
    .{ "Picture", "picture" },   .{ "Program", "program" }, .{ "Compressed", "archive" },
};

const sizes = [_][2][]const u8{
    .{ "Empty (0 KB)", "empty" },             .{ "Tiny (0 - 16 KB)", "tiny" },          .{ "Small (16 KB - 1 MB)", "small" },
    .{ "Medium (1 - 128 MB)", "medium" },     .{ "Large (128 MB - 1 GB)", "large" },    .{ "Huge (1 - 4 GB)", "huge" },
    .{ "Gigantic (> 4 GB)", "gigantic" },
};

/// The search box with `name:value` in place of the `name:` it had - or,
/// a null value, without it - searched for again.
pub fn setTerm(self: *Files, name: []const u8, value: ?[]const u8) void {
    const typed = std.mem.trim(u8, self.window.layout.textValueOf("search/field") orelse "", " \t");
    var out: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    var i: usize = 0;
    var first = true;
    while (i < typed.len) {
        while (i < typed.len and typed[i] == ' ') i += 1;
        if (i >= typed.len) break;
        const from = i;
        var quoted = false;
        while (i < typed.len and (quoted or typed[i] != ' ')) : (i += 1) {
            if (typed[i] == '"') quoted = !quoted;
        }
        const word = typed[from..i];
        if (std.ascii.startsWithIgnoreCase(word, name) and word.len > name.len and word[name.len] == ':') {
            // "datemodified:this week": its second word goes with it.
            const rest = word[name.len + 1 ..];
            if (std.ascii.eqlIgnoreCase(rest, "this") or std.ascii.eqlIgnoreCase(rest, "last")) {
                while (i < typed.len and typed[i] == ' ') i += 1;
                while (i < typed.len and typed[i] != ' ') i += 1;
            }
            continue;
        }
        w.print("{s}{s}", .{ if (first) "" else " ", word }) catch return;
        first = false;
    }
    if (value) |v| w.print("{s}{s}:{s}", .{ if (first) "" else " ", name, v }) catch return;
    self.window.layout.setTextValue("search/field", w.buffered());
    self.menu = .none;
    self.context_open = null;
    self.searchChanged();
}

/// The menu open: under its button, Windows 10's ribbon's or Windows 11's
/// command bar's.
pub fn menu(self: *Files, kit: *Kit) void {
    const u = kit.ui;
    const anchor = self.search_anchor;
    if (self.window.down and !u.isPointerOver("menu/search") and !u.isPointerOver(menus.sub_menu_id) and !u.isPointerOver(anchor)) {
        self.menu = .none;
        return;
    }
    menus.begin(self, kit, "menu/search", .{ .attach = .id, .to = anchor, .fractions = .{ .element_x = 0, .element_y = 0, .target_x = 0, .target_y = 1 }, .offset = .{ .x = 0, .y = if (self.ten()) 0 else 4 }, .z_index = 50 });
    defer menus.end(kit);
    switch (self.search_menu) {
        .all => {
            menus.subRow(self, kit, "menu/search/date", "Date modified", .calendar_ltr, .search_date, false);
            menus.subRow(self, kit, "menu/search/kind", "Kind", .apps, .search_kind, false);
            menus.subRow(self, kit, "menu/search/size", "Size", .data_area, .search_size, false);
            menus.separator(self, kit);
            menus.subRow(self, kit, "menu/search/advanced", "Advanced options", .settings, .search_advanced, false);
            menus.subRow(self, kit, "menu/search/recent", "Recent searches", .clock, .search_recent, self.history.searches.items.len == 0);
        },
        .date => dateMenu(self, kit),
        .kind => kindMenu(self, kit),
        .size => sizeMenu(self, kit),
        .other => otherMenu(self, kit),
        .advanced => advancedMenu(self, kit),
        .recent => recentMenu(self, kit),
    }
}

/// The words a term has in the box now, to mark it.
fn termValue(self: *Files, name: []const u8, buffer: []u8) []const u8 {
    const typed = self.window.layout.textValueOf("search/field") orelse return "";
    var it = std.mem.splitScalar(u8, typed, ' ');
    while (it.next()) |word| {
        if (std.ascii.startsWithIgnoreCase(word, name) and word.len > name.len and word[name.len] == ':') {
            var v = std.mem.trimStart(u8, word[name.len + 1 ..], "=");
            if (std.ascii.eqlIgnoreCase(v, "this") or std.ascii.eqlIgnoreCase(v, "last")) {
                const next = it.next() orelse "";
                v = std.fmt.bufPrint(buffer, "{s} {s}", .{ v, next }) catch v;
            }
            return v;
        }
    }
    return "";
}

pub fn dateMenu(self: *Files, kit: *Kit) void {
    var buffer: [32]u8 = undefined;
    const now = termValue(self, "datemodified", &buffer);
    for (dates, 0..) |d, k| if (menus.row(self, kit, kit.print("menu/search/date/{d}", .{k}), d[0], .{ .marked = std.ascii.eqlIgnoreCase(now, d[1]) })) {
        return setTerm(self, "datemodified", d[1]);
    };
    if (now.len > 0) {
        menus.separator(self, kit);
        if (menus.row(self, kit, "menu/search/date/any", "Any time", .{})) setTerm(self, "datemodified", null);
    }
}

pub fn kindMenu(self: *Files, kit: *Kit) void {
    var buffer: [32]u8 = undefined;
    const now = termValue(self, "kind", &buffer);
    for (kinds, 0..) |d, k| if (menus.row(self, kit, kit.print("menu/search/kind/{d}", .{k}), d[0], .{ .marked = std.ascii.eqlIgnoreCase(now, d[1]) })) {
        var value_buffer: [32]u8 = undefined;
        return setTerm(self, "kind", std.fmt.bufPrint(&value_buffer, "={s}", .{d[1]}) catch d[1]);
    };
    if (now.len > 0) {
        menus.separator(self, kit);
        if (menus.row(self, kit, "menu/search/kind/any", "Any kind", .{})) setTerm(self, "kind", null);
    }
}

pub fn sizeMenu(self: *Files, kit: *Kit) void {
    var buffer: [32]u8 = undefined;
    const now = termValue(self, "size", &buffer);
    for (sizes, 0..) |d, k| if (menus.row(self, kit, kit.print("menu/search/size/{d}", .{k}), d[0], .{ .marked = std.ascii.eqlIgnoreCase(now, d[1]) })) {
        return setTerm(self, "size", d[1]);
    };
    if (now.len > 0) {
        menus.separator(self, kit);
        if (menus.row(self, kit, "menu/search/size/any", "Any size", .{})) setTerm(self, "size", null);
    }
}

/// Windows 10's Other properties: by type, by name, by what is in it.
fn otherMenu(self: *Files, kit: *Kit) void {
    if (menus.row(self, kit, "menu/search/other/type", "Type", .{})) return setTerm(self, "type", "pdf");
    if (menus.row(self, kit, "menu/search/other/content", "Contents", .{})) return setTerm(self, "content", "\"\"");
}

/// What else is searched: what is in the files, system folders,
/// compressed folders - Folder Options' Search tab, kept.
pub fn advancedMenu(self: *Files, kit: *Kit) void {
    const choices = [_]struct { name: []const u8, on: *bool }{
        .{ .name = "File contents", .on = &self.prefs.search_contents },
        .{ .name = "System files", .on = &self.prefs.search_system },
        .{ .name = "Zipped (compressed) folders", .on = &self.prefs.search_archives },
    };
    for (choices, 0..) |c, k| if (menus.row(self, kit, kit.print("menu/search/advanced/{d}", .{k}), c.name, .{ .marked = c.on.*, .ticked = true })) {
        c.on.* = !c.on.*;
        self.prefs.save(self.io);
        self.menu = .none;
        self.context_open = null;
        // Searched again, as told.
        return self.searchChanged();
    };
}

/// What was searched for lately - and "Clear search history".
pub fn recentMenu(self: *Files, kit: *Kit) void {
    for (self.history.searches.items, 0..) |text, k| if (menus.row(self, kit, kit.print("menu/search/recent/{d}", .{k}), text, .{ .icon = if (self.ten()) null else .search })) {
        var buffer: [512]u8 = undefined;
        const copy = std.fmt.bufPrint(&buffer, "{s}", .{text}) catch return;
        self.window.layout.setTextValue("search/field", copy);
        self.menu = .none;
        self.context_open = null;
        return self.searchChanged();
    };
    if (self.history.searches.items.len > 0) menus.separator(self, kit);
    if (menus.row(self, kit, "menu/search/recent/clear", "Clear search history", .{ .disabled = self.history.searches.items.len == 0 })) {
        self.history.clearSearches(self.io);
        self.menu = .none;
    }
}

/// Open one of the menus under `anchor`.
pub fn open(self: *Files, which: Which, anchor: []const u8) void {
    if (self.menu == .search_options and self.search_menu == which) {
        self.menu = .none;
        return;
    }
    self.history.refresh(self.io);
    self.search_menu = which;
    self.search_anchor = anchor;
    self.menu = .search_options;
    self.context_sub = .none;
}
