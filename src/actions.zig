// SPDX-License-Identifier: BSD-2-Clause

//! What a person does to what is chosen - from the keys, the command bar,
//! the ribbon or a right-click menu: cut, copy and paste, rename, delete,
//! new folders and files, copy as path.

const std = @import("std");

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Ops = @import("Ops.zig");
const Look = @import("Look.zig");
const apps = @import("apps.zig");
const Jobs = @import("Jobs.zig");
const archives = @import("archives.zig");
const Undo = @import("Undo.zig");

const log = std.log.scoped(.actions);

/// The full paths of what is chosen, into `out`: each where it is - a
/// search's findings in their own folders.
fn chosenPaths(self: *Files, out: *std.ArrayList([]u8)) void {
    const t = self.tab();
    for (t.selected.items, 0..) |s, i| {
        if (!s) continue;
        const e = t.entry(i);
        const dir = t.dirOf(e) orelse continue;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = Ops.join(&buffer, dir, e.name) catch continue;
        out.append(self.gpa, self.gpa.dupe(u8, full) catch continue) catch {};
    }
}

fn clearClipboard(self: *Files) void {
    for (self.clipboard.items) |p| self.gpa.free(p);
    self.clipboard.clearRetainingCapacity();
}

/// Kept to be pasted - and, cut, moved when it is.
pub fn copy(self: *Files, cut: bool) void {
    if (self.tab().selectedCount() == 0) return;
    // Nothing is taken out of a compressed folder but by copying.
    if (cut and self.tab().inArchive()) return;
    clearClipboard(self);
    chosenPaths(self, &self.clipboard);
    self.clipboard_cut = cut;
    // On the desktop's clipboard too, as GTK's and KDE's file managers put
    // files there: their own form, a URI list, and the paths as text.
    var gnome: std.ArrayList(u8) = .empty;
    defer gnome.deinit(self.gpa);
    var uris: std.ArrayList(u8) = .empty;
    defer uris.deinit(self.gpa);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.gpa);
    gnome.appendSlice(self.gpa, if (cut) "cut" else "copy") catch {};
    for (self.clipboard.items, 0..) |path, i| {
        var uri_buffer: [std.fs.max_path_bytes * 3 + 8]u8 = undefined;
        const uri = fileUri(path, &uri_buffer);
        gnome.append(self.gpa, '\n') catch {};
        gnome.appendSlice(self.gpa, uri) catch {};
        uris.appendSlice(self.gpa, uri) catch {};
        uris.appendSlice(self.gpa, "\r\n") catch {};
        if (i > 0) text.append(self.gpa, '\n') catch {};
        text.appendSlice(self.gpa, path) catch {};
    }
    self.window.setSelection(&.{
        .{ .mime = "x-special/gnome-copied-files", .data = gnome.items },
        .{ .mime = "text/uri-list", .data = uris.items },
        .{ .mime = "text/plain;charset=utf-8", .data = text.items },
        .{ .mime = "UTF8_STRING", .data = text.items },
    });
    self.window.redraw();
}

/// `file:///path`, every byte but the safe ones as `%XX`.
pub fn fileUri(path: []const u8, buffer: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buffer);
    w.writeAll("file://") catch return "";
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.' or c == '~') {
            w.writeByte(c) catch return "";
        } else w.print("%{X:0>2}", .{c}) catch return "";
    }
    return w.buffered();
}

pub fn canPaste(self: *Files) bool {
    return self.clipboard.items.len > 0 and self.tab().writable();
}

/// What was copied or cut, here - copied or moved on a thread of its own,
/// the progress dialog showing how far; the pasted chosen once it is done,
/// as Windows chooses them.
pub fn paste(self: *Files) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    if (self.clipboard.items.len == 0 or !t.writable()) return;
    // Copied out of a compressed folder: taken out of it, here.
    if (archives.pasteFromArchive(self, dir)) return;
    self.jobs.start(if (self.clipboard_cut) .move else .copy, @ptrCast(self.clipboard.items), dir, null);
    // Cut, it is pasted once: gone from where it was.
    if (self.clipboard_cut) clearClipboard(self);
    self.window.redraw();
}

/// The jobs that have finished: what they made chosen, if it is in the
/// folder shown; kept to be undone; what went wrong said. Whether any did.
pub fn jobsDone(self: *Files) bool {
    var done: std.ArrayList(*Jobs.Job) = .empty;
    defer done.deinit(self.gpa);
    self.jobs.takeFinished(&done);
    if (done.items.len == 0) return false;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.gpa);
    for (done.items) |j| {
        if (j.state == .done) switch (j.kind) {
            .copy, .extract => self.undo.made(.copy, j.made.items),
            .compress => self.undo.made(.new, j.made.items),
            .move => self.undo.movedAll(j.moved.items),
            .trash => self.undo.trashedAll(j.trashed.items),
            .delete => {},
        };
        if (j.failure) |err| switch (j.kind) {
            .copy => self.notify("Some items could not be copied", err),
            .move => self.notify("Some items could not be moved", err),
            .trash => self.notify("Some items could not be moved to the Recycle Bin", err),
            .delete => self.notify("Some items could not be deleted", err),
            .extract => self.notify("The compressed folder could not be extracted", err),
            .compress => self.notify("The compressed folder could not be made", err),
        };
    }
    self.refreshAll();
    // What was made in the folder shown: chosen.
    if (self.tab().path()) |shown| for (done.items) |j| {
        for (j.made.items) |m| if (std.mem.eql(u8, std.fs.path.dirname(m) orelse "/", shown)) {
            names.append(self.gpa, std.fs.path.basename(m)) catch {};
        };
    };
    choose(self, names.items);
    // "Show extracted files when complete": the folder they went into.
    if (self.show_after_len > 0) for (done.items) |j| {
        if (j.kind != .extract or j.state != .done) continue;
        const want = self.show_after_buffer[0..self.show_after_len];
        if (!std.mem.eql(u8, j.dest, want)) continue;
        self.show_after_len = 0;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const copy_of = std.fmt.bufPrint(&buffer, "{s}", .{want}) catch break;
        self.goTo(.{ .folder = copy_of });
        break;
    };
    for (done.items) |j| self.jobs.release(j);
    return true;
}

/// Choose the entries named `names` in the tab in front, the first focused.
pub fn choose(self: *Files, names: []const []const u8) void {
    const t = self.tab();
    if (names.len == 0) return;
    t.selectNone();
    for (0..t.count()) |i| {
        for (names) |n| if (std.mem.eql(u8, t.entry(i).name, n)) {
            t.selected.items[i] = true;
            if (t.focus == null or !t.selected.items[t.focus.?]) t.focus = i;
            t.anchor = i;
            t.reveal = true;
        };
    }
}

/// Delete what is chosen: into the Recycle Bin, or - `permanent`, after
/// asking - gone for good.
pub fn delete(self: *Files, permanent: bool) void {
    const t = self.tab();
    const n = t.selectedCount();
    if (n == 0 or !t.lists() or t.inArchive()) return;
    // From the Recycle Bin, nothing is deleted but for good.
    if (permanent or t.location == .trash) {
        self.confirm = .delete_permanently;
        self.window.redraw();
        return;
    }
    deleteChosen(self, false);
}

pub fn deleteChosen(self: *Files, permanent: bool) void {
    const t = self.tab();
    if (t.location == .trash) {
        var trash_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const bin = Ops.homeTrash(&trash_buffer) orelse return;
        var failed: ?anyerror = null;
        for (0..t.count()) |i| {
            if (!t.selected.items[i]) continue;
            Ops.purge(self.io, bin, t.entry(i).stored orelse continue) catch |err| {
                failed = err;
            };
        }
        if (failed) |err| self.notify("Some items could not be deleted", err);
        return self.refreshAll();
    }
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    if (paths.items.len == 0) return;
    self.jobs.start(if (permanent) .delete else .trash, @ptrCast(paths.items), "", null);
    self.window.redraw();
}

/// A new folder here, its name being typed.
pub fn newFolder(self: *Files) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    if (!t.writable()) return;
    self.menu = .none;
    var buffer: [256]u8 = undefined;
    const name = Ops.newFolder(self.io, dir, &buffer) catch |err| return self.notify("The folder could not be made", err);
    madeNew(self, dir, &.{name});
    self.refresh();
    choose(self, &.{name});
    if (t.focus) |i| self.startRename(i);
}

pub fn newTextFile(self: *Files) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    if (!t.writable()) return;
    self.menu = .none;
    var buffer: [256]u8 = undefined;
    const name = Ops.newTextFile(self.io, dir, &buffer) catch |err| return self.notify("The document could not be made", err);
    madeNew(self, dir, &.{name});
    self.refresh();
    choose(self, &.{name});
    if (t.focus) |i| self.startRename(i);
}

/// Things made new in `dir` - a folder, a document, shortcuts - kept to be
/// undone.
fn madeNew(self: *Files, dir: []const u8, names: []const []const u8) void {
    var paths: [64][]const u8 = undefined;
    var buffers: [64][std.fs.max_path_bytes]u8 = undefined;
    var n: usize = 0;
    for (names) |name| {
        if (n == paths.len) break;
        paths[n] = Ops.join(&buffers[n], dir, name) catch continue;
        n += 1;
    }
    self.undo.made(.new, paths[0..n]);
}

/// The name typed, given - or, unchanged or empty, left as it was.
pub fn commitRename(self: *Files) void {
    const index = self.renaming orelse return;
    self.renaming = null;
    const t = self.tab();
    const dir = t.path() orelse return;
    if (index >= t.count()) return;
    const typed = std.mem.trim(u8, self.window.layout.textValueOf("rename/field") orelse "", " \t");
    self.window.layout.clearFocus();
    const old = t.entry(index).name;
    if (typed.len == 0 or std.mem.eql(u8, typed, old)) return;
    var name_buffer: [256]u8 = undefined;
    const new = std.fmt.bufPrint(&name_buffer, "{s}", .{typed}) catch return;
    Ops.rename(self.io, dir, old, new) catch |err| switch (err) {
        error.BadName => return self.notify("A file name can't contain a slash, or be empty", err),
        error.PathAlreadyExists => return self.notify("There is already a file with the same name in this location", err),
        else => return self.notify("The item could not be renamed", err),
    };
    self.undo.renamed(dir, old, new);
    self.refresh();
    choose(self, &.{new});
}

/// The paths of what is chosen, a line each, onto the clipboard -
/// Windows' Copy as path.
pub fn copyAsPath(self: *Files) void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    if (paths.items.len == 0) if (self.tab().path()) |p| {
        paths.append(self.gpa, self.gpa.dupe(u8, p) catch return) catch {};
    };
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(self.gpa);
    for (paths.items, 0..) |p, i| {
        if (i > 0) text.append(self.gpa, '\n') catch {};
        text.append(self.gpa, '"') catch {};
        text.appendSlice(self.gpa, p) catch {};
        text.append(self.gpa, '"') catch {};
    }
    self.window.copyText(text.items);
}

/// Pin to Quick access: the chosen folders - or, none chosen, the folder
/// shown - or take them off where they are pinned already.
pub fn pinChosen(self: *Files) void {
    const t = self.tab();
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    if (paths.items.len == 0) if (t.path()) |p| paths.append(self.gpa, self.gpa.dupe(u8, p) catch return) catch {};
    for (paths.items) |p| {
        var kind = std.Io.Dir.cwd().statFile(self.io, p, .{}) catch continue;
        if (kind.kind != .directory) continue;
        _ = &kind;
        self.places.togglePin(self.io, p);
    }
    self.window.redraw();
}

/// Windows 10's Move to and Copy to: what is chosen, into `to`.
pub fn sendTo(self: *Files, to: []const u8, moving: bool) void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    if (paths.items.len == 0) return;
    self.jobs.start(if (moving) .move else .copy, @ptrCast(paths.items), to, null);
    self.window.redraw();
}

/// A shortcut to each chosen, beside it: "report - Shortcut.pdf".
pub fn createShortcut(self: *Files) void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| self.gpa.free(n);
        names.deinit(self.gpa);
    }
    var failed: ?anyerror = null;
    for (paths.items) |target| {
        var buffer: [512]u8 = undefined;
        const name = Ops.shortcut(self.io, target, std.fs.path.dirname(target) orelse "/", &buffer) catch |err| {
            failed = err;
            continue;
        };
        names.append(self.gpa, self.gpa.dupe(u8, name) catch continue) catch {};
        madeNew(self, std.fs.path.dirname(target) orelse "/", &.{name});
    }
    if (failed) |err| self.notify("The shortcut could not be created", err);
    self.refreshAll();
    choose(self, names.items);
}

/// Paste shortcut: a shortcut here to each of what was copied.
pub fn pasteShortcut(self: *Files) void {
    const dir = self.tab().path() orelse return;
    var failed: ?anyerror = null;
    for (self.clipboard.items) |target| {
        var buffer: [512]u8 = undefined;
        const name = Ops.shortcut(self.io, target, dir, &buffer) catch |err| {
            failed = err;
            continue;
        };
        madeNew(self, dir, &.{name});
    }
    if (failed) |err| self.notify("Some shortcuts could not be created", err);
    self.refreshAll();
}

/// Send to ▸ Desktop (create shortcut).
pub fn shortcutOnDesktop(self: *Files) void {
    const desktop = self.places.pathOf(.desktop) orelse return;
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    var failed: ?anyerror = null;
    for (paths.items) |target| {
        var buffer: [512]u8 = undefined;
        _ = Ops.shortcut(self.io, target, desktop, &buffer) catch |err| {
            failed = err;
        };
    }
    if (failed) |err| self.notify("The shortcut could not be created", err);
    self.refreshAll();
}

/// Open with ▸ an app: the chosen file in it.
pub fn openWith(self: *Files, app: *const apps.App) void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    for (paths.items) |p| apps.runWith(self.gpa, self.io, app.name, app.exec, p);
}

/// Eject: a drive that comes and goes unmounted and turned off, by
/// udisks, as the desktop's own would.
pub fn eject(self: *Files, d: @import("Places.zig").Drive) void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(self.gpa);
    line.appendSlice(self.gpa, "udisksctl unmount -b ") catch return;
    quote(self, &line, d.device);
    line.appendSlice(self.gpa, " && udisksctl power-off -b ") catch return;
    quote(self, &line, d.device);
    apps.run(self.gpa, self.io, "Eject", line.items, null);
}

/// Email: the chosen files attached to a new mail, in the mail app.
pub fn email(self: *Files) void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    if (paths.items.len == 0) return;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(self.gpa);
    line.appendSlice(self.gpa, "xdg-email") catch return;
    for (paths.items) |p| {
        line.appendSlice(self.gpa, " --attach ") catch return;
        quote(self, &line, p);
    }
    apps.run(self.gpa, self.io, "Email", line.items, null);
}

/// Zip: the chosen into a compressed folder beside them, named after the
/// first, as Windows names it - made on a thread, its progress shown.
pub fn zip(self: *Files) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    const first = t.current() orelse return;
    var name_buffer: [512]u8 = undefined;
    const e = t.entry(first);
    const stem = if (e.isFolder()) e.name else std.fs.path.stem(e.name);
    var wanted_buffer: [512]u8 = undefined;
    const wanted = std.fmt.bufPrint(&wanted_buffer, "{s}.zip", .{if (stem.len > 0) stem else e.name}) catch return;
    const name = Ops.freeName(self.io, dir, wanted, false, false, &name_buffer);
    var zip_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const zip_path = Ops.join(&zip_buffer, dir, name) catch return;
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    if (paths.items.len == 0) return;
    self.jobs.start(.compress, @ptrCast(paths.items), zip_path, null);
}

/// Undo (Ctrl+Z): the last thing done taken back - what it leaves chosen.
pub fn undo(self: *Files) void {
    undoOrRedo(self, false);
}

/// Redo (Ctrl+Y): the last thing undone, done again.
pub fn redo(self: *Files) void {
    undoOrRedo(self, true);
}

fn undoOrRedo(self: *Files, again: bool) void {
    self.menu = .none;
    self.context_open = null;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    var touched: std.ArrayList([]const u8) = .empty;
    (if (again) self.undo.redo(self.io, &touched, arena.allocator()) else self.undo.undo(self.io, &touched, arena.allocator())) catch |err| {
        self.notify(if (again) "The last action could not be redone" else "The last action could not be undone", err);
    };
    self.refreshAll();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.gpa);
    if (self.tab().path()) |shown| for (touched.items) |p| {
        if (std.mem.eql(u8, std.fs.path.dirname(p) orelse "/", shown)) names.append(self.gpa, std.fs.path.basename(p)) catch {};
    };
    choose(self, names.items);
}

/// A terminal in the folder shown.
pub fn terminalHere(self: *Files) void {
    terminalIn(self, self.tab().path() orelse return);
}

/// Open in Terminal on the one folder chosen - or, with none, the folder
/// shown.
pub fn terminalChosen(self: *Files) void {
    const t = self.tab();
    if (t.selectedCount() == 1) if (t.current()) |i| {
        const e = t.entry(i);
        if (e.isFolder()) if (t.dirOf(e)) |dir| {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            return terminalIn(self, Ops.join(&buffer, dir, e.name) catch return);
        };
    };
    terminalHere(self);
}

pub fn terminalIn(self: *Files, dir: []const u8) void {
    const apps_list = self.installedApps() orelse return;
    const terminals = [_][]const u8{ "org.gnome.Ptyxis.desktop", "org.gnome.Console.desktop", "org.gnome.Terminal.desktop", "org.kde.konsole.desktop", "foot.desktop", "kitty.desktop", "Alacritty.desktop" };
    const app = apps.firstOf(apps_list, &terminals) orelse return self.notify("No terminal is installed", error.FileNotFound);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(self.gpa);
    line.appendSlice(self.gpa, "cd ") catch return;
    quote(self, &line, dir);
    line.appendSlice(self.gpa, " && ") catch return;
    const exec = apps.commandLine(self.gpa, app.exec) catch return;
    defer self.gpa.free(exec);
    line.appendSlice(self.gpa, exec) catch return;
    apps.run(self.gpa, self.io, app.name, line.items, null);
}

/// The chosen picture as the desktop's background: in Settings' file,
/// where the shell takes it from.
pub fn setAsBackground(self: *Files) void {
    const t = self.tab();
    const i = t.current() orelse return;
    const e = t.entry(i);
    const dir = t.dirOf(e) orelse return;
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const full = Ops.join(&buffer, dir, e.name) catch return;
    var path_buffer: [512]u8 = undefined;
    const file = Look.path(&path_buffer) orelse return;
    var text_buffer: [16384]u8 = undefined;
    const was = std.Io.Dir.cwd().readFile(self.io, file, &text_buffer) catch "";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.gpa);
    setKey(self.gpa, &out, was, "desktop", "wallpaper", full) catch return;
    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = file, .data = out.items }) catch |err| self.notify("The background could not be set", err);
}

/// `text` with `key=value` in `[section]` - replaced where it is, added
/// where it is not.
pub fn setKey(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, section: []const u8, key: []const u8, value: []const u8) !void {
    var current: []const u8 = "";
    var done = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            // Leaving the section without the key: it goes at its end.
            if (!done and std.mem.eql(u8, current, section)) {
                try out.print(gpa, "{s}={s}\n", .{ key, value });
                done = true;
            }
            current = std.mem.trim(u8, line, "[]");
        }
        if (!done and std.mem.eql(u8, current, section)) if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " "), key)) {
                if (!first) try out.append(gpa, '\n');
                first = false;
                try out.print(gpa, "{s}={s}", .{ key, value });
                done = true;
                continue;
            }
        };
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, raw);
    }
    if (!done) {
        if (!std.mem.eql(u8, current, section)) try out.print(gpa, "\n[{s}]\n", .{section}) else try out.append(gpa, '\n');
        try out.print(gpa, "{s}={s}\n", .{ key, value });
    }
}

/// The Recycle Bin's chosen items - or, none chosen, all of them - back
/// where they were.
pub fn restore(self: *Files, all: bool) void {
    const t = self.tab();
    if (t.location != .trash) return;
    var trash_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trash = Ops.homeTrash(&trash_buffer) orelse return;
    var failed: ?anyerror = null;
    for (0..t.count()) |i| {
        if (!all and !t.selected.items[i]) continue;
        const e = t.entry(i);
        const stored = e.stored orelse continue;
        Ops.restore(self.io, trash, stored, e.dir orelse "/", e.name) catch |err| {
            failed = err;
        };
    }
    if (failed) |err| self.notify("Some items could not be restored", err);
    self.refreshAll();
}

/// The Recycle Bin emptied, everything in it gone for good.
pub fn emptyTrash(self: *Files) void {
    var trash_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const trash = Ops.homeTrash(&trash_buffer) orelse return;
    Ops.emptyTrash(self.io, trash) catch |err| self.notify("The Recycle Bin could not be emptied", err);
    self.refreshAll();
}

fn quote(self: *Files, out: *std.ArrayList(u8), text: []const u8) void {
    out.append(self.gpa, '\'') catch return;
    for (text) |c| if (c == '\'') out.appendSlice(self.gpa, "'\\''") catch return else out.append(self.gpa, c) catch return;
    out.append(self.gpa, '\'') catch return;
}

test "a key is set in its section, replaced or added" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try setKey(gpa, &out, "[appearance]\nmode=dark\n[desktop]\nwallpaper=/old.png\nslideshow=false\n", "desktop", "wallpaper", "/new.png");
    try std.testing.expectEqualStrings("[appearance]\nmode=dark\n[desktop]\nwallpaper=/new.png\nslideshow=false\n", out.items);
    out.clearRetainingCapacity();
    try setKey(gpa, &out, "[appearance]\nmode=dark\n", "desktop", "wallpaper", "/a.png");
    try std.testing.expectEqualStrings("[appearance]\nmode=dark\n\n[desktop]\nwallpaper=/a.png\n", out.items);
}
