// SPDX-License-Identifier: BSD-2-Clause

//! Files: the desktop's file manager, laid out as Windows 11's - tabs in
//! the title bar, an address row, a command bar, the navigation pane, the
//! folder, a status bar - or, in Windows 10's look, as Windows 10's, with
//! no tabs and the ribbon. See `docs/FILES.md` in fluxion-de for the whole
//! design.
//!
//! ```
//! ┌[▢ Documents ×][+]──────────────────────────────[─][▢][✕]┐
//! │ ← → ↑ ⟳ │ › Home › Documents ›           │ 🔍 Search     │
//! │ ⊕ New ▾ │ ✂ ⧉ 📋 ✎ 🗑 │ ⇅ Sort ▾  ☰ View ▾  ···          │
//! ├────────────┬─────────────────────────────────────────────┤
//! │ ⌂ Home     │ Name           Date modified    Type   Size │
//! │ 📌 Desktop  │ ▢ Projects     10/08/2026 21:…  File folder │
//! │ ▸ This PC  │ ▢ report.pdf   10/09/2026 09:…  PDF   2 MB  │
//! ├────────────┴─────────────────────────────────────────────┤
//! │ 2 items                                          [☰][▦] │
//! └──────────────────────────────────────────────────────────┘
//! ```

const std = @import("std");
const xkb = @import("xkbcommon");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Window = @import("Window.zig");
const Look = @import("Look.zig");
const Mime = @import("Mime.zig");
const Places = @import("Places.zig");
const OpenWith = @import("OpenWith.zig");
const Tab = @import("Tab.zig");
const Folder = @import("Folder.zig");
const apps_mod = @import("apps.zig");
const chrome = @import("chrome.zig");
const nav = @import("nav.zig");
const views = @import("views.zig");

const Files = @This();

const log = std.log.scoped(.files);

gpa: std.mem.Allocator,
io: std.Io,
window: Window = undefined,
look: Look,
look_watch: ?std.c.fd_t = null,
/// Rings a moment after a new look: this window takes it after the
/// compositor has its picture of the screens to cross over from.
retheme_timer: ?std.c.fd_t = null,
mime: Mime,
places: Places,
open_with: OpenWith,
/// The installed apps, read the first time one is needed.
apps: ?apps_mod.Apps = null,
tabs: std.ArrayList(*Tab) = .empty,
active: usize = 0,
/// View ▸ Show: hidden items, file name extensions.
show_hidden: bool = false,
show_extensions: bool = true,
/// The navigation pane's width, and whether This PC is open in it.
nav_width: f32 = 240,
this_pc_open: bool = true,
/// The address bar turned into a field with the path to type over.
editing_address: bool = false,
address_draws: u8 = 0,
/// The pointer rests on the maximise button drawn here: since when, and
/// whether the layouts were asked for.
maximize_rest_ms: i64 = 0,
layouts_shown: bool = false,
/// A menu open: View, Sort, New, "···".
menu: Menu = .none,
/// Items on a row of the view drawn last: what Up and Down move by.
grid_columns: usize = 1,
/// The place chosen on Home or This PC, by its element's id.
page_chosen: ?void = null,
page_chosen_buffer: [64]u8 = undefined,
page_chosen_len: usize = 0,

pub const Menu = enum { none, view, sort, more, new };

pub fn init(self: *Files, gpa: std.mem.Allocator, io: std.Io, start: ?[]const u8) !void {
    const look = Look.load(io);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .look = look,
        .mime = .load(gpa, io),
        .places = .load(gpa, io),
        .open_with = .load(gpa, io),
    };
    try self.window.init(gpa, io, "Files", "org.fluxion.Files", look.widgetsMode(), look.widgetsAccent(), look.widgetsLook(), .{
        .context = self,
        .draw = draw,
        .key = key,
        .button = pointerButton,
        .close = closeRequested,
    });
    self.look_watch = Look.watch(io);
    if (self.look_watch) |fd| self.window.addWatch(.{ .fd = fd, .context = self, .ready = lookChanged });
    const timer = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (std.os.linux.errno(timer) == .SUCCESS) {
        self.retheme_timer = @intCast(timer);
        self.window.addWatch(.{ .fd = @intCast(timer), .context = self, .ready = rethemeRang });
    }
    const first: Tab.Location = if (start) |p| .{ .folder = p } else .home;
    self.newTab(first);
}

pub fn deinit(self: *Files) void {
    for (self.tabs.items) |t| {
        t.deinit();
        self.gpa.destroy(t);
    }
    self.tabs.deinit(self.gpa);
    if (self.apps) |*a| a.deinit();
    if (self.look_watch) |fd| _ = std.c.close(fd);
    if (self.retheme_timer) |fd| _ = std.c.close(fd);
    self.open_with.deinit();
    self.places.deinit();
    self.mime.deinit();
    self.window.deinit();
}

pub fn tab(self: *Files) *Tab {
    return self.tabs.items[self.active];
}

/// Windows 10's look: no tabs, the ribbon, square.
pub fn ten(self: *const Files) bool {
    return self.look.style == .win10;
}

// -------------------------------------------------------------------------
// Tabs and places
// -------------------------------------------------------------------------

/// A tab at `at`, in front.
pub fn newTab(self: *Files, at: Tab.Location) void {
    const t = self.gpa.create(Tab) catch return;
    t.* = .{ .gpa = self.gpa };
    t.go(at);
    // Its first place is no place to go back to.
    for (t.back_stack.items) |l| switch (l) {
        .folder => |p| self.gpa.free(p),
        else => {},
    };
    t.back_stack.clearRetainingCapacity();
    self.tabs.append(self.gpa, t) catch {
        t.deinit();
        self.gpa.destroy(t);
        return;
    };
    self.active = self.tabs.items.len - 1;
    self.arrived();
}

pub fn closeTab(self: *Files, index: usize) void {
    if (index >= self.tabs.items.len) return;
    // The last one closes the window, as Windows' does.
    if (self.tabs.items.len == 1) {
        self.window.running = false;
        return;
    }
    const t = self.tabs.orderedRemove(index);
    t.deinit();
    self.gpa.destroy(t);
    if (self.active >= self.tabs.items.len) self.active = self.tabs.items.len - 1 else if (self.active > index) self.active -= 1;
    self.arrived();
}

pub fn switchTab(self: *Files, index: usize) void {
    if (index >= self.tabs.items.len) return;
    self.active = index;
    self.editing_address = false;
    self.arrived();
}

/// Go to `at` in the tab in front.
pub fn goTo(self: *Files, at: Tab.Location) void {
    self.tab().go(at);
    self.arrived();
}

pub fn goBack(self: *Files) void {
    self.tab().goBack();
    self.arrived();
}

pub fn goForward(self: *Files) void {
    self.tab().goForward();
    self.arrived();
}

pub fn goUp(self: *Files) void {
    const parent = self.tab().parentPath() orelse return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const copy = std.fmt.bufPrint(&buffer, "{s}", .{parent}) catch return;
    self.goTo(.{ .folder = copy });
}

/// Read it again: F5.
pub fn refresh(self: *Files) void {
    self.tab().read(self.io, &self.mime, self.show_hidden);
    self.window.redraw();
}

/// Arrived somewhere: the folder read, the title and the scroll set.
fn arrived(self: *Files) void {
    const t = self.tab();
    self.editing_address = false;
    self.menu = .none;
    self.page_chosen = null;
    if (t.path() != null and t.folder == null) t.read(self.io, &self.mime, self.show_hidden);
    self.window.layout.scrollTo("view/scroll", 0, 0);
    var buffer: [256]u8 = undefined;
    self.window.setTitle(self.titleOf(t, &buffer));
    self.window.redraw();
}

/// What a tab, and the window, is called: the folder's name, as Windows'.
pub fn titleOf(self: *Files, t: *const Tab, buffer: []u8) []const u8 {
    return switch (t.location) {
        .home => if (self.ten()) "Quick access" else "Home",
        .this_pc => "This PC",
        .folder => |p| blk: {
            if (std.mem.eql(u8, p, "/")) break :blk "Local Disk";
            if (std.mem.eql(u8, p, self.places.home)) break :blk std.fs.path.basename(p);
            for (self.places.user.items) |f| if (std.mem.eql(u8, f.path, p)) break :blk f.name;
            break :blk std.fmt.bufPrint(buffer, "{s}", .{std.fs.path.basename(p)}) catch "Files";
        },
    };
}

// -------------------------------------------------------------------------
// Opening
// -------------------------------------------------------------------------

/// Open item `i` of the tab in front: a folder here - in a new tab with
/// Ctrl - and a file in the app that opens its kind.
pub fn open(self: *Files, i: usize, new_tab: bool) void {
    const t = self.tab();
    if (i >= t.count()) return;
    const e = t.entry(i);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ if (std.mem.eql(u8, t.path().?, "/")) "" else t.path().?, e.name }) catch return;
    if (e.isFolder()) {
        if (new_tab and !self.ten()) self.newTab(.{ .folder = full }) else self.goTo(.{ .folder = full });
        return;
    }
    self.openFile(full, e.mime);
}

pub fn openFile(self: *Files, path: []const u8, mime: []const u8) void {
    const apps = self.installedApps() orelse return;
    const app = self.open_with.defaultFor(apps, mime) orelse {
        log.warn("no app opens {s}", .{mime});
        return;
    };
    apps_mod.runWith(self.gpa, self.io, app.name, app.exec, path);
}

pub fn installedApps(self: *Files) ?*const apps_mod.Apps {
    if (self.apps == null) self.apps = apps_mod.load(self.gpa, self.io) catch return null;
    return &self.apps.?;
}

/// The path the address bar was given: `~`, a folder, a file's folder.
fn goToTyped(self: *Files, typed: []const u8) void {
    const trimmed = std.mem.trim(u8, typed, " \t");
    if (trimmed.len == 0) return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const lower = std.ascii.lowerString(buffer[0..@min(trimmed.len, buffer.len)], trimmed[0..@min(trimmed.len, buffer.len)]);
    if (std.mem.eql(u8, lower, "home") or std.mem.eql(u8, lower, "quick access")) return self.goTo(.home);
    if (std.mem.eql(u8, lower, "this pc") or std.mem.eql(u8, lower, "computer:")) return self.goTo(.this_pc);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (std.mem.startsWith(u8, trimmed, "~"))
        std.fmt.bufPrint(&path_buffer, "{s}{s}", .{ self.places.home, trimmed[1..] }) catch return
    else if (std.mem.startsWith(u8, trimmed, "file://"))
        trimmed["file://".len..]
    else
        trimmed;
    const clean = std.mem.trimEnd(u8, path, "/");
    self.goTo(.{ .folder = if (clean.len == 0) "/" else clean });
}

// -------------------------------------------------------------------------
// The look
// -------------------------------------------------------------------------

fn lookChanged(context: *anyopaque) void {
    const self: *Files = @ptrCast(@alignCast(context));
    if (!Look.changed(self.look_watch.?)) return;
    const before = self.look;
    self.look = Look.load(self.io);
    if (!std.meta.eql(before, self.look)) self.rethemeSoon();
}

/// Take the new look a moment from now: the compositor crosses the screens
/// over from a picture of them as they were, which must not have this
/// window in the new look already.
fn rethemeSoon(self: *Files) void {
    const fd = self.retheme_timer orelse return self.retheme();
    const spec: std.os.linux.itimerspec = .{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = 0, .nsec = 120 * std.time.ns_per_ms },
    };
    if (std.os.linux.errno(std.os.linux.timerfd_settime(fd, .{}, &spec, null)) != .SUCCESS) self.retheme();
}

fn rethemeRang(context: *anyopaque) void {
    const self: *Files = @ptrCast(@alignCast(context));
    var expirations: u64 = 0;
    _ = std.c.read(self.retheme_timer.?, std.mem.asBytes(&expirations), 8);
    self.retheme();
}

fn retheme(self: *Files) void {
    self.window.setTheme(self.look.widgetsMode(), self.look.widgetsAccent(), self.look.widgetsLook());
    // Windows 10's had no tabs: the one in front stays.
    if (self.ten()) while (self.tabs.items.len > 1) {
        const last = if (self.active == self.tabs.items.len - 1) 0 else self.tabs.items.len - 1;
        self.closeTab(last);
    };
}

// -------------------------------------------------------------------------
// Drawing
// -------------------------------------------------------------------------

fn draw(context: *anyopaque, window: *Window, kit: *Kit) void {
    const self: *Files = @ptrCast(@alignCast(context));
    const u = kit.ui;
    const p = &kit.theme.palette;
    // Over Mica, the window's base is the glass; without it, solid.
    u.open(.{
        .id = "files",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = if (window.mica) .transparent else p.solid_base,
    });
    defer u.close();
    if (window.own_title_bar) chrome.titleBar(self, kit);
    // Windows 10's ribbon is over the address row; Windows 11's command
    // bar under it.
    if (self.ten()) {
        chrome.ribbon(self, kit);
        chrome.addressRow(self, kit);
    } else {
        chrome.addressRow(self, kit);
        chrome.commandBar(self, kit);
    }
    {
        u.open(.{ .id = "body", .width = .grow, .height = .grow });
        defer u.close();
        nav.pane(self, kit);
        views.content(self, kit);
    }
    chrome.statusBar(self, kit);
    chrome.menus(self, kit);
}

// -------------------------------------------------------------------------
// Keys and buttons
// -------------------------------------------------------------------------

fn key(context: *anyopaque, window: *Window, sym: xkb.Keysym) bool {
    const self: *Files = @ptrCast(@alignCast(context));
    const u = &window.layout;
    const ctrl = window.modifierHeld(xkb.names.mod.ctrl);
    const shift = window.modifierHeld(xkb.names.mod.shift);
    const alt = window.modifierHeld(xkb.names.mod.alt);
    const K = xkb.Keysym;
    const code = @intFromEnum(sym);
    const t = self.tab();

    // A field being typed in has its keys - but for Escape and Enter.
    if (u.isFocused("address/field")) {
        switch (code) {
            K.Escape => {
                self.editing_address = false;
                u.clearFocus();
                return true;
            },
            K.Return, K.KP_Enter => {
                const typed = u.textValueOf("address/field") orelse "";
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const copy = std.fmt.bufPrint(&buffer, "{s}", .{typed}) catch return true;
                u.clearFocus();
                self.goToTyped(copy);
                return true;
            },
            else => return false,
        }
    }
    if (u.isFocused("search/field")) {
        if (code == K.Escape) {
            u.setTextValue("search/field", "");
            u.clearFocus();
            return true;
        }
        return false;
    }
    if (self.menu != .none and code == K.Escape) {
        self.menu = .none;
        return true;
    }

    switch (code) {
        K.Left => if (alt) {
            self.goBack();
            return true;
        },
        K.Right => if (alt) {
            self.goForward();
            return true;
        },
        K.Up => if (alt) {
            self.goUp();
            return true;
        },
        else => {},
    }
    if (ctrl and shift) {
        // Ctrl+Shift+1…8: the views, Extra large icons to Content.
        if (code >= K.@"1" and code <= K.@"8") {
            self.setView(@enumFromInt(code - K.@"1"));
            return true;
        }
        // Shift with the digits types !"§$…: the keys by where they are.
        const views_by_symbol = [_]u32{ K.exclam, K.at, K.numbersign, K.dollar, K.percent, K.asciicircum, K.ampersand, K.asterisk };
        for (views_by_symbol, 0..) |s, i| if (code == s) {
            self.setView(@enumFromInt(i));
            return true;
        };
    }
    if (ctrl) switch (code) {
        K.t, K.T => {
            if (!self.ten()) self.newTab(t.location);
            return true;
        },
        K.w, K.W => {
            self.closeTab(self.active);
            return true;
        },
        K.Tab, K.ISO_Left_Tab => {
            if (self.tabs.items.len > 1) {
                const n = self.tabs.items.len;
                self.switchTab(if (shift) (self.active + n - 1) % n else (self.active + 1) % n);
            }
            return true;
        },
        K.l, K.L => {
            self.editAddress();
            return true;
        },
        K.e, K.E, K.f, K.F => {
            u.setFocus("search/field");
            return true;
        },
        K.a, K.A => {
            t.selectAll();
            return true;
        },
        K.r, K.R => {
            self.refresh();
            return true;
        },
        else => {},
    };
    if (alt) switch (code) {
        K.d, K.D => {
            self.editAddress();
            return true;
        },
        else => {},
    };
    switch (code) {
        K.F4 => self.editAddress(),
        K.F5 => self.refresh(),
        K.F3 => u.setFocus("search/field"),
        K.BackSpace => self.goBack(),
        K.Return, K.KP_Enter => if (t.current()) |i| self.open(i, ctrl),
        K.Up => t.moveFocus(-self.across(), ctrl, shift),
        K.Down => t.moveFocus(self.across(), ctrl, shift),
        K.Left => t.moveFocus(if (self.across() > 1) -1 else 0, ctrl, shift),
        K.Right => t.moveFocus(if (self.across() > 1) 1 else 0, ctrl, shift),
        K.Home => t.moveFocus(-@as(isize, @intCast(t.count())), ctrl, shift),
        K.End => t.moveFocus(@intCast(t.count()), ctrl, shift),
        K.Page_Up => t.moveFocus(-10 * self.across(), ctrl, shift),
        K.Page_Down => t.moveFocus(10 * self.across(), ctrl, shift),
        K.Escape => t.selectNone(),
        else => {
            // Letters find an item by its name, as they are typed.
            if (ctrl or alt) return false;
            var buffer: [16]u8 = undefined;
            const n = xkb_keysym_to_utf8(code, &buffer, buffer.len);
            if (n <= 1) return false;
            const typed = buffer[0 .. @as(usize, @intCast(n)) - 1];
            if (typed[0] < 0x20) return false;
            t.typeAhead(typed, Window.nowMs());
        },
    }
    return true;
}

extern fn xkb_keysym_to_utf8(keysym: u32, buffer: [*]u8, size: usize) c_int;

/// How many items are on a row of the view in front: one, but for icons.
pub fn across(self: *Files) isize {
    return @intCast(@max(1, views.columns(self)));
}

pub fn editAddress(self: *Files) void {
    self.editing_address = true;
    self.address_draws = 0;
    self.window.redraw();
}

/// A place on Home or This PC chosen by a click.
pub fn choosePageItem(self: *Files, id: []const u8) void {
    self.page_chosen = {};
    self.page_chosen_len = @min(id.len, self.page_chosen_buffer.len);
    @memcpy(self.page_chosen_buffer[0..self.page_chosen_len], id[0..self.page_chosen_len]);
}

pub fn setView(self: *Files, view: Tab.View) void {
    self.tab().view = view;
    self.menu = .none;
    self.window.redraw();
}

fn pointerButton(context: *anyopaque, window: *Window, code: u32) bool {
    const self: *Files = @ptrCast(@alignCast(context));
    _ = window;
    switch (code) {
        Window.button_back => self.goBack(),
        Window.button_forward => self.goForward(),
        else => return false,
    }
    return true;
}

fn closeRequested(context: *anyopaque, window: *Window) void {
    const self: *Files = @ptrCast(@alignCast(context));
    _ = self;
    window.running = false;
}
