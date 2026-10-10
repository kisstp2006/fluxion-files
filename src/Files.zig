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
const actions = @import("actions.zig");
const menus = @import("menus.zig");
const win10 = @import("win10.zig");
const win11 = @import("win11.zig");
const panes = @import("panes.zig");
const property_sheet = @import("properties.zig");
const Search = @import("Search.zig");
const Thumbs = @import("Thumbs.zig");
const drag = @import("drag.zig");
const Prefs = @import("Prefs.zig");
const Preview = @import("Preview.zig");
const Player = @import("Player.zig");
const Jobs = @import("Jobs.zig");
const Undo = @import("Undo.zig");
const progress = @import("progress.zig");
const archives = @import("archives.zig");
const chooser_mod = @import("chooser.zig");
const Archive = @import("Archive.zig");

const Files = @This();

const log = std.log.scoped(.files);

gpa: std.mem.Allocator,
io: std.Io,
window: Window = undefined,
look: Look,
/// Folder Options, and what else is kept between windows.
prefs: Prefs,
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
/// Windows 10's Quick access opened in the pane, and the folders opened
/// in its tree.
quick_open: bool = true,
nav_opened: std.ArrayList(nav.Opened) = .empty,
/// The row of the pane last clicked, and the folder it went to: while
/// that folder is shown, that row - and only it - is lit, though the
/// folder is in the tree more than once.
nav_chosen_buffer: [160]u8 = undefined,
nav_chosen_len: usize = 0,
nav_chosen_path_buffer: [std.fs.max_path_bytes]u8 = undefined,
nav_chosen_path_len: usize = 0,
/// The address bar's "›" opened: the folders in the crumb before it, and
/// which "›" it was.
crumb_list: ?nav.Opened = null,
crumb_anchor_buffer: [32]u8 = undefined,
crumb_anchor_len: usize = 0,
/// The address bar turned into a field with the path to type over.
editing_address: bool = false,
address_draws: u8 = 0,
/// The pointer rests on the maximise button drawn here: since when, and
/// whether the layouts were asked for.
maximize_rest_ms: i64 = 0,
layouts_shown: bool = false,
/// A menu open: View, Sort, New, "···".
menu: Menu = .none,
/// What was copied or cut, by full path, to be pasted.
clipboard: std.ArrayList([]u8) = .empty,
clipboard_cut: bool = false,
/// The item whose name is being typed anew, and how many drawings the
/// field has been there.
renaming: ?usize = null,
rename_draws: u8 = 0,
/// A question asked over the window.
confirm: ?Confirm = null,
/// What went wrong last, said at the top of the folder until closed.
notice_buffer: [256]u8 = undefined,
notice_len: usize = 0,
/// A right click, where it was - the menu for what it was on, or for the
/// folder - and whether the full ("Show more options") menu is asked for.
context_at: ?[2]f32 = null,
context_open: ?[2]f32 = null,
context_on_item: bool = false,
context_more: bool = false,
/// The menu open beside a row of the right-click menu: View ▸, Send to ▸.
context_sub: menus.Sub = .none,
/// A middle click, to be answered by what it was on.
middle_click: bool = false,
/// The folder in front watched for changes, and when to read it again.
watch_fd: ?std.c.fd_t = null,
watch_wd: i32 = -1,
refresh_due_ms: i64 = 0,
/// Items on a row of the view drawn last: what Up and Down move by.
grid_columns: usize = 1,
/// The place chosen on Home or This PC, by its element's id.
page_chosen: ?void = null,
page_chosen_buffer: [64]u8 = undefined,
page_chosen_len: usize = 0,
/// The navigation pane shown, and the pane on the right: details or
/// preview, or neither.
show_nav: bool = true,
pane: Pane = .none,
/// View ▸ Show: check boxes on the items; Windows 11's Compact view.
check_boxes: bool = false,
compact: bool = false,
/// Windows 10's ribbon: its tab in front, and whether it is folded to the
/// tabs' names.
ribbon_tab: RibbonTab = .home,
ribbon_folded: bool = false,
/// The tab whose menu is open.
tab_menu: usize = 0,
/// Properties open, for a file or a folder.
properties: ?property_sheet.Sheet = null,
/// The picture of the chosen file, for the panes.
thumbs: Thumbs = undefined,
/// A search running, and the pipe its thread wakes the window through.
search: Search = undefined,
search_wake: [2]std.c.fd_t = .{ -1, -1 },
/// A rubber band being dragged over the folder: where it began, in the
/// window's pixels.
band_from: ?[2]f32 = null,
/// What was chosen as the band began: what it adds to, with Ctrl.
band_base: std.ArrayList(bool) = .empty,
/// A press on an item, and where: a drag once the pointer moves away.
drag_press: ?struct { at: [2]f32, item: usize } = null,
/// What the drag out of this window carries, by full path.
dragged: std.ArrayList([]u8) = .empty,
/// A tab a drag is held over, and since when.
drag_tab: ?usize = null,
drag_tab_since: i64 = 0,
/// A click on the one item chosen: its name to type anew, in a moment.
rename_pending: ?usize = null,
rename_pending_ms: i64 = 0,
/// The photos of the icon views, made on a thread, and its pipe.
gallery: Thumbs.Gallery = undefined,
gallery_wake: [2]std.c.fd_t = .{ -1, -1 },
/// The pipe the other threads wake the window through: the preview's, the
/// player's, the file operations'.
work_wake: [2]std.c.fd_t = .{ -1, -1 },
/// What the preview pane shows, made on a thread; and a video or a song
/// playing in it.
preview: Preview = undefined,
player: Player = undefined,
/// The pane's edge being dragged: from where, from how wide.
pane_drag: ?struct { from_x: f32, from_width: f32 } = null,
/// The media bar being dragged: where to, when it is let go.
seek_value: ?f32 = null,
/// What is being done to files, each on a thread; and what can be undone.
jobs: Jobs = undefined,
undo: Undo = undefined,
/// The progress dialog: where it was moved to, the pointer's hold on its
/// title, its details shown, folded into the status bar.
progress_at: ?[2]f32 = null,
progress_drag: ?[2]f32 = null,
progress_more: bool = false,
progress_folded: bool = false,
/// "Let me decide for each file": for which job, and which side of each
/// name taken is kept.
deciding: ?u32 = null,
/// "Extract Compressed (Zipped) Folders", open; and the folder to show
/// once what it takes out is out.
wizard: ?archives.Wizard = null,
/// "Choose another app", open.
chooser: ?chooser_mod.Chooser = null,
show_after_buffer: [std.fs.max_path_bytes]u8 = undefined,
show_after_len: usize = 0,
decide_source: std.ArrayList(bool) = .empty,
decide_dest: std.ArrayList(bool) = .empty,

pub const Menu = enum { none, view, sort, group, more, new, file, move_to, copy_to, recent, tab, crumb, qat };
pub const Confirm = enum { delete_permanently, empty_trash };
pub const Pane = enum { none, details, preview };
pub const RibbonTab = enum { home, share, view, manage, search };

pub fn init(self: *Files, gpa: std.mem.Allocator, io: std.Io, start: ?[]const u8) !void {
    const look = Look.load(io);
    const prefs = Prefs.load(io);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .look = look,
        .prefs = prefs,
        .show_hidden = prefs.hidden,
        .show_extensions = prefs.extensions,
        .check_boxes = prefs.check_boxes,
        .show_nav = prefs.navigation,
        .pane = switch (prefs.pane) {
            .none => .none,
            .details => .details,
            .preview => .preview,
        },
        .mime = .load(gpa, io),
        .places = .load(gpa, io),
        .open_with = .load(gpa, io),
        .thumbs = .{ .gpa = gpa, .io = io },
    };
    try self.window.init(gpa, io, "Files", "org.fluxion.Files", look.widgetsMode(), look.widgetsAccent(), look.widgetsLook(), .{
        .context = self,
        .draw = draw,
        .key = key,
        .button = pointerButton,
        .close = closeRequested,
        .dropped = drag.dropped,
    });
    self.look_watch = Look.watch(io);
    if (self.look_watch) |fd| self.window.addWatch(.{ .fd = fd, .context = self, .ready = lookChanged });
    const timer = std.os.linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true });
    if (std.os.linux.errno(timer) == .SUCCESS) {
        self.retheme_timer = @intCast(timer);
        self.window.addWatch(.{ .fd = @intCast(timer), .context = self, .ready = rethemeRang });
    }
    const watch = std.os.linux.inotify_init1(std.os.linux.IN.NONBLOCK | std.os.linux.IN.CLOEXEC);
    if (std.os.linux.errno(watch) == .SUCCESS) {
        self.watch_fd = @intCast(watch);
        self.window.addWatch(.{ .fd = @intCast(watch), .context = self, .ready = folderChanged });
    }
    if (std.c.pipe2(&self.search_wake, .{ .CLOEXEC = true, .NONBLOCK = true }) == 0) {
        self.window.addWatch(.{ .fd = self.search_wake[0], .context = self, .ready = searchReady });
    }
    self.search = .{ .gpa = gpa, .io = io, .wake = self.search_wake[1] };
    if (std.c.pipe2(&self.gallery_wake, .{ .CLOEXEC = true, .NONBLOCK = true }) == 0) {
        self.window.addWatch(.{ .fd = self.gallery_wake[0], .context = self, .ready = galleryReady });
    }
    self.gallery = .init(gpa, io, self.gallery_wake[1]);
    if (std.c.pipe2(&self.work_wake, .{ .CLOEXEC = true, .NONBLOCK = true }) == 0) {
        self.window.addWatch(.{ .fd = self.work_wake[0], .context = self, .ready = workReady });
    }
    self.preview = .init(gpa, io, self.work_wake[1]);
    self.player = .init(gpa, io, self.work_wake[1]);
    self.jobs = .init(gpa, io, self.work_wake[1]);
    self.undo = .init(gpa);
    self.progress_more = prefs.transfer_details;
    // Folder Options' "Open File Explorer to".
    const first: Tab.Location = if (start) |p| startPlace(p) else if (prefs.open_to == .this_pc) .this_pc else .home;
    self.newTab(first);
}

/// What a start's argument names: a folder, or a place by its URI.
fn startPlace(arg: []const u8) Tab.Location {
    if (std.mem.startsWith(u8, arg, "trash:")) return .trash;
    if (std.mem.startsWith(u8, arg, "computer:")) return .this_pc;
    return .{ .folder = arg };
}

pub fn deinit(self: *Files) void {
    for (self.tabs.items) |t| {
        t.deinit();
        self.gpa.destroy(t);
    }
    self.tabs.deinit(self.gpa);
    self.search.deinit();
    for (self.search_wake) |fd| if (fd >= 0) {
        _ = std.c.close(fd);
    };
    self.gallery.deinit();
    for (self.gallery_wake) |fd| if (fd >= 0) {
        _ = std.c.close(fd);
    };
    self.jobs.deinit();
    self.undo.deinit();
    self.decide_source.deinit(self.gpa);
    self.decide_dest.deinit(self.gpa);
    self.player.deinit();
    self.preview.deinit();
    for (self.work_wake) |fd| if (fd >= 0) {
        _ = std.c.close(fd);
    };
    self.band_base.deinit(self.gpa);
    for (self.dragged.items) |p| self.gpa.free(p);
    self.dragged.deinit(self.gpa);
    nav.forget(self);
    if (self.crumb_list) |l| l.free(self.gpa);
    self.nav_opened.deinit(self.gpa);
    if (self.apps) |*a| a.deinit();
    for (self.clipboard.items) |p| self.gpa.free(p);
    self.clipboard.deinit(self.gpa);
    if (self.watch_fd) |fd| _ = std.c.close(fd);
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

/// Every tab but `keep` closed.
pub fn closeOtherTabs(self: *Files, keep: usize) void {
    if (keep >= self.tabs.items.len) return;
    const kept = self.tabs.items[keep];
    for (self.tabs.items) |t| if (t != kept) {
        t.deinit();
        self.gpa.destroy(t);
    };
    self.tabs.clearRetainingCapacity();
    self.tabs.append(self.gpa, kept) catch {};
    self.active = 0;
    self.arrived();
}

/// Another window of Files: a process of its own, at the folder in front.
pub fn openNewWindow(self: *Files) void {
    var buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "fluxion-files {s}", .{self.tab().path() orelse ""}) catch return;
    apps_mod.run(self.gpa, self.io, "Files", line, null);
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
    // From Home, or a person's folder at the top, up is This PC... as
    // Windows has it; from a folder, its parent.
    if (self.tab().location == .home) return self.goTo(.this_pc);
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

/// Every tab showing a folder read again: something was done to files.
pub fn refreshAll(self: *Files) void {
    for (self.tabs.items) |t| if (t.path() != null or t.location == .trash) t.read(self.io, &self.mime, self.show_hidden);
    self.window.redraw();
}

pub fn toggleHidden(self: *Files) void {
    self.show_hidden = !self.show_hidden;
    for (self.tabs.items) |each| each.refilter(self.show_hidden);
    self.savePrefs();
    self.window.redraw();
}

pub fn togglePane(self: *Files, which: Pane) void {
    self.pane = if (self.pane == which) .none else which;
    self.savePrefs();
    self.window.redraw();
}

pub fn sortBy(self: *Files, by: Folder.Column) void {
    self.tab().sortBy(by, &self.mime, self.show_hidden);
    self.window.redraw();
}

/// Ascending or descending, by what it is sorted by.
pub fn sortOrder(self: *Files, ascending: bool) void {
    const t = self.tab();
    t.ascending = ascending;
    if (t.folder) |*f| f.sort(t.sort_by, ascending, &self.mime);
    t.refilter(self.show_hidden);
    self.window.redraw();
}

pub fn groupBy(self: *Files, by: ?Folder.Column) void {
    self.tab().groupBy(by, self.show_hidden);
    self.window.redraw();
}

/// Properties: of the one item chosen, or of the folder shown.
pub fn openProperties(self: *Files) void {
    const t = self.tab();
    self.menu = .none;
    self.context_open = null;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (t.selectedCount() >= 1) if (t.current()) |i| {
        const e = t.entry(i);
        const dir = t.dirOf(e) orelse return;
        const full = @import("Ops.zig").join(&buffer, dir, e.name) catch return;
        return property_sheet.open(self, full, e.isFolder(), e.mime);
    };
    if (t.path()) |p| property_sheet.open(self, p, true, Mime.directory);
}

/// What the search box says now: searched for under the folder in front -
/// or, emptied, that folder again.
pub fn searchChanged(self: *Files) void {
    const t = self.tab();
    const typed = std.mem.trim(u8, self.window.layout.textValueOf("search/field") orelse "", " \t");
    const folder: []const u8 = switch (t.location) {
        .folder => |p| p,
        .search => |q| q.folder,
        // From Home and This PC, the home folder.
        else => self.places.home,
    };
    var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const from = std.fmt.bufPrint(&folder_buffer, "{s}", .{folder}) catch return;
    if (typed.len == 0) {
        self.search.stop();
        if (t.location == .search) {
            t.replace(.{ .folder = from });
            self.arrived();
        }
        return;
    }
    var query_buffer: [256]u8 = undefined;
    const query = std.fmt.bufPrint(&query_buffer, "{s}", .{typed}) catch return;
    if (t.location == .search) t.replace(.{ .search = .{ .folder = from, .query = query } }) else {
        t.go(.{ .search = .{ .folder = from, .query = query } });
        // Windows 10 turns to the Search tab as a search begins.
        if (self.ten()) self.ribbon_tab = .search;
    }
    t.folder = Folder.empty(self.gpa, "Search");
    t.refilter(self.show_hidden);
    self.search.start(from, query);
    self.window.redraw();
}

/// Search `folder` for `query`, the box saying what is searched for.
pub fn searchIn(self: *Files, folder: []const u8, query: []const u8) void {
    var folder_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const from = std.fmt.bufPrint(&folder_buffer, "{s}", .{folder}) catch return;
    var query_buffer: [256]u8 = undefined;
    const what = std.fmt.bufPrint(&query_buffer, "{s}", .{query}) catch return;
    const t = self.tab();
    if (t.location == .search) t.replace(.{ .search = .{ .folder = from, .query = what } }) else t.go(.{ .search = .{ .folder = from, .query = what } });
    t.folder = Folder.empty(self.gpa, "Search");
    t.refilter(self.show_hidden);
    self.search.start(from, what);
    self.window.layout.setTextValue("search/field", what);
    self.window.redraw();
}

/// Close search: the folder searched, again.
pub fn closeSearch(self: *Files) void {
    self.window.layout.setTextValue("search/field", "");
    self.searchChanged();
}

/// The person's folder `path` is, or is in: Documents, Pictures.
pub fn knownFolderOf(self: *Files, path: []const u8) ?Places.Folder {
    for (self.places.user.items) |f| {
        // A folder not set up is the home folder itself: not one of them.
        if (std.mem.eql(u8, f.path, self.places.home)) continue;
        if (std.mem.startsWith(u8, path, f.path) and (path.len == f.path.len or path[f.path.len] == '/')) return f;
    }
    return null;
}

/// The drive chosen on This PC.
pub fn chosenDrive(self: *Files) ?Places.Drive {
    if (self.page_chosen == null) return null;
    const id = self.page_chosen_buffer[0..self.page_chosen_len];
    const prefix = "pc/drive/";
    if (!std.mem.startsWith(u8, id, prefix)) return null;
    const i = std.fmt.parseInt(usize, id[prefix.len..], 10) catch return null;
    if (i >= self.places.drives.items.len) return null;
    return self.places.drives.items[i];
}

pub fn searching(self: *Files) bool {
    return self.tab().location == .search and self.search.running();
}

/// The gallery's thread made pictures: into the window, and drawn.
fn galleryReady(context: *anyopaque) void {
    const self: *Files = @ptrCast(@alignCast(context));
    var drain: [256]u8 = undefined;
    while (std.c.read(self.gallery_wake[0], &drain, drain.len) > 0) {}
    if (self.gallery.take(&self.window.icons)) self.window.redraw();
}

/// The other threads made something: a preview, a frame of a video, a
/// step of a file operation.
fn workReady(context: *anyopaque) void {
    const self: *Files = @ptrCast(@alignCast(context));
    var drain: [256]u8 = undefined;
    while (std.c.read(self.work_wake[0], &drain, drain.len) > 0) {}
    var any = self.preview.take(&self.window.icons);
    if (self.player.take(&self.window.icons)) any = true;
    if (actions.jobsDone(self)) any = true;
    // A job going on: the dialog drawn again.
    if (self.jobs.running()) any = true;
    if (any) self.window.redraw();
}

/// Keep what the window shows of itself - its panes, hidden items and
/// extensions, check boxes - for the next window.
pub fn savePrefs(self: *Files) void {
    self.prefs.hidden = self.show_hidden;
    self.prefs.extensions = self.show_extensions;
    self.prefs.check_boxes = self.check_boxes;
    self.prefs.navigation = self.show_nav;
    self.prefs.transfer_details = self.progress_more;
    self.prefs.pane = switch (self.pane) {
        .none => .none,
        .details => .details,
        .preview => .preview,
    };
    self.prefs.save(self.io);
}

/// The search's thread found more: into the list.
fn searchReady(context: *anyopaque) void {
    const self: *Files = @ptrCast(@alignCast(context));
    var drain: [256]u8 = undefined;
    while (std.c.read(self.search_wake[0], &drain, drain.len) > 0) {}
    const t = self.tab();
    if (t.location != .search) return;
    var found: std.ArrayList([]u8) = .empty;
    defer {
        for (found.items) |p| self.gpa.free(p);
        found.deinit(self.gpa);
    }
    self.search.take(&found);
    const folder = &(t.folder orelse return);
    for (found.items) |full| folder.addFound(self.io, &self.mime, full);
    // Kept in the order searched; the list grows below what is chosen.
    const keep_selected = t.selected.items.len;
    const old: []bool = self.gpa.dupe(bool, t.selected.items) catch &.{};
    defer self.gpa.free(old);
    t.refilter(self.show_hidden);
    for (old, 0..) |sel, i| if (i < keep_selected and i < t.selected.items.len) {
        t.selected.items[i] = sel;
    };
    self.window.redraw();
}

/// The name a place goes by in a list of them: Recent locations.
pub fn locationName(self: *Files, l: Tab.Location, buffer: []u8) []const u8 {
    return switch (l) {
        .home => if (self.ten()) "Quick access" else "Home",
        .this_pc => "This PC",
        .trash => "Recycle Bin",
        .search => |q| std.fmt.bufPrint(buffer, "Search results in {s}", .{std.fs.path.basename(q.folder)}) catch "Search",
        .folder => |p| std.fmt.bufPrint(buffer, "{s}", .{if (std.mem.eql(u8, p, "/")) "/" else std.fs.path.basename(p)}) catch "",
    };
}

pub fn arrivedPublic(self: *Files) void {
    self.arrived();
}

/// Say what went wrong, at the top of the folder.
pub fn notify(self: *Files, what: []const u8, err: anyerror) void {
    log.warn("{s}: {t}", .{ what, err });
    const text = std.fmt.bufPrint(&self.notice_buffer, "{s} ({t}).", .{ what, err }) catch what;
    self.notice_len = text.len;
    self.window.redraw();
}

pub fn notice(self: *const Files) ?[]const u8 {
    return if (self.notice_len > 0) self.notice_buffer[0..self.notice_len] else null;
}

/// Type a new name for item `i`, in its place.
pub fn startRename(self: *Files, i: usize) void {
    const t = self.tab();
    if (!t.writable() or i >= t.count()) return;
    self.renaming = i;
    self.rename_draws = 0;
    t.focus = i;
    t.reveal = true;
    self.window.redraw();
}

/// The folder in front changed on disk: read again a moment later, once a
/// burst of changes has settled.
fn folderChanged(context: *anyopaque) void {
    const self: *Files = @ptrCast(@alignCast(context));
    var buffer: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (std.c.read(self.watch_fd.?, &buffer, buffer.len) > 0) {}
    if (self.refresh_due_ms == 0) self.refresh_due_ms = Window.nowMs() + 150;
    self.window.wakeAt(self.refresh_due_ms);
}

/// Watch the folder in front - and only it.
fn watchFolder(self: *Files) void {
    const fd = self.watch_fd orelse return;
    if (self.watch_wd >= 0) _ = std.os.linux.inotify_rm_watch(fd, self.watch_wd);
    self.watch_wd = -1;
    const path = self.tab().path() orelse return;
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= z.len) return;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const L = std.os.linux.IN;
    const wd = std.os.linux.inotify_add_watch(fd, @ptrCast(&z), L.CREATE | L.DELETE | L.MOVED_FROM | L.MOVED_TO | L.CLOSE_WRITE | L.ATTRIB);
    if (std.os.linux.errno(wd) == .SUCCESS) self.watch_wd = @intCast(wd);
}

/// Arrived somewhere: the folder read, the title and the scroll set.
fn arrived(self: *Files) void {
    const t = self.tab();
    self.editing_address = false;
    self.menu = .none;
    self.page_chosen = null;
    self.renaming = null;
    self.notice_len = 0;
    if ((t.path() != null or t.location == .trash) and t.folder == null) t.read(self.io, &self.mime, self.show_hidden);
    // Left a search: it stops, and the box is emptied.
    if (t.location != .search) {
        self.search.stop();
        const typed: []const u8 = self.window.layout.textValueOf("search/field") orelse "";
        if (typed.len > 0) self.window.layout.setTextValue("search/field", "");
    }
    self.watchFolder();
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
        .trash => "Recycle Bin",
        .search => |q| std.fmt.bufPrint(buffer, "Search Results in {s}", .{std.fs.path.basename(q.folder)}) catch "Search Results",
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
    // In the Recycle Bin, a file is not opened: its properties are.
    if (t.location == .trash) return;
    const dir = t.dirOf(e) orelse return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, e.name }) catch return;
    // A compressed folder opens as a folder, as Windows opens one.
    const folder = e.isFolder() or (Archive.named(e.name) and Archive.available() and !t.inArchive());
    if (folder) {
        if (new_tab and !self.ten()) self.newTab(.{ .folder = full }) else self.goTo(.{ .folder = full });
        return;
    }
    // In one: taken out first.
    if (t.inArchive()) return archives.openInside(self, i);
    self.openFile(full, e.mime);
}

pub fn openFile(self: *Files, path: []const u8, mime: []const u8) void {
    const apps = self.installedApps() orelse return;
    // No app opens its kind yet: which is to, asked as Windows asks it.
    const app = self.open_with.defaultFor(apps, mime) orelse return chooser_mod.open(self, path, mime);
    apps_mod.runWith(self.gpa, self.io, app.name, app.exec, path);
}

/// A search's finding shown where it is: its folder opened, it chosen.
pub fn openFileLocation(self: *Files) void {
    const t = self.tab();
    const i = t.current() orelse return;
    const e = t.entry(i);
    var dir_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buffer, "{s}", .{t.dirOf(e) orelse return}) catch return;
    var name_buffer: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "{s}", .{e.name}) catch return;
    self.goTo(.{ .folder = dir });
    actions.choose(self, &.{name});
}

pub fn installedApps(self: *Files) ?*const apps_mod.Apps {
    if (self.apps == null) self.apps = apps_mod.load(self.gpa, self.io) catch return null;
    return &self.apps.?;
}

/// The path the address bar was given: `~`, a folder, a file's folder.
pub fn goToTyped(self: *Files, typed: []const u8) void {
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
    // Changed on disk a moment ago: read again.
    if (self.refresh_due_ms != 0 and Window.nowMs() >= self.refresh_due_ms) {
        self.refresh_due_ms = 0;
        if (self.renaming == null) self.tab().read(self.io, &self.mime, self.show_hidden);
    }
    // Over Mica, the window's base is the glass; without it, solid.
    u.open(.{
        .id = "files",
        .width = .grow,
        .height = .grow,
        .direction = .top_to_bottom,
        .background_color = if (window.mica) .transparent else p.solid_base,
    });
    defer u.close();
    // Windows 10's ribbon is over the address row; Windows 11's command
    // bar under it.
    if (self.ten()) {
        if (window.own_title_bar) win10.titleBar(self, kit);
        win10.ribbon(self, kit);
        chrome.addressRow(self, kit);
    } else {
        if (window.own_title_bar) win11.titleBar(self, kit);
        chrome.addressRow(self, kit);
        win11.commandBar(self, kit);
    }
    {
        u.open(.{ .id = "body", .width = .grow, .height = .grow });
        defer u.close();
        if (self.show_nav) nav.pane(self, kit);
        views.content(self, kit);
        panes.pane(self, kit);
    }
    chrome.statusBar(self, kit);
    chrome.menus(self, kit);
    menus.context(self, kit);
    menus.confirmDialog(self, kit);
    progress.draw(self, kit);
    archives.wizard(self, kit);
    chooser_mod.draw(self, kit);
    property_sheet.draw(self, kit);
    drag.tip(self, kit);
    // A right or middle click on nothing that took it.
    self.context_at = null;
    self.middle_click = false;
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
    if (self.renaming != null and u.isFocused("rename/field")) {
        switch (code) {
            K.Escape => {
                self.renaming = null;
                u.clearFocus();
                return true;
            },
            K.Return, K.KP_Enter => {
                actions.commitRename(self);
                return true;
            },
            else => return false,
        }
    }
    if (self.properties != null) {
        if (code == K.Escape) self.properties = null;
        return code == K.Escape;
    }
    if (self.wizard != null) {
        if (code == K.Escape) self.wizard = null;
        return code == K.Escape;
    }
    if (self.chooser != null) {
        if (code == K.Escape) self.chooser = null;
        return code == K.Escape;
    }
    if (self.confirm != null) {
        switch (code) {
            K.Escape, K.n, K.N => self.confirm = null,
            K.Return, K.KP_Enter, K.y, K.Y => menus.confirmed(self),
            else => {},
        }
        return true;
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
    if (self.context_open != null and code == K.Escape) {
        self.context_open = null;
        return true;
    }

    if (alt) switch (code) {
        K.p, K.P => {
            self.togglePane(if (shift) .details else .preview);
            return true;
        },
        K.Return, K.KP_Enter => {
            self.openProperties();
            return true;
        },
        else => {},
    };
    if (ctrl and code == K.F1 and self.ten()) {
        self.ribbon_folded = !self.ribbon_folded;
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
        if (code == K.N or code == K.n) {
            actions.newFolder(self);
            return true;
        }
        if (code == K.C or code == K.c) {
            actions.copyAsPath(self);
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
        K.c, K.C, K.Insert => {
            actions.copy(self, false);
            return true;
        },
        K.x, K.X => {
            actions.copy(self, true);
            return true;
        },
        K.v, K.V => {
            actions.paste(self);
            return true;
        },
        K.d, K.D => {
            actions.delete(self, false);
            return true;
        },
        K.r, K.R => {
            self.refresh();
            return true;
        },
        K.z, K.Z => {
            actions.undo(self);
            return true;
        },
        K.y, K.Y => {
            actions.redo(self);
            return true;
        },
        K.n, K.N => {
            self.openNewWindow();
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
        K.F2 => if (t.current()) |i| self.startRename(i),
        K.Delete => actions.delete(self, shift),
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
    switch (code) {
        Window.button_back => self.goBack(),
        Window.button_forward => self.goForward(),
        // Answered in the next drawing, by what it was on.
        Window.button_right => {
            self.context_at = window.pointer_at;
            self.context_more = window.modifierHeld("Shift");
        },
        Window.button_middle => self.middle_click = true,
        else => return false,
    }
    return true;
}

fn closeRequested(context: *anyopaque, window: *Window) void {
    const self: *Files = @ptrCast(@alignCast(context));
    _ = self;
    window.running = false;
}
