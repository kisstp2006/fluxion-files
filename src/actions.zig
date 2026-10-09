// SPDX-License-Identifier: BSD-2-Clause

//! What a person does to what is chosen - from the keys, the command bar,
//! the ribbon or a right-click menu: cut, copy and paste, rename, delete,
//! new folders and files, copy as path.

const std = @import("std");

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Ops = @import("Ops.zig");

const log = std.log.scoped(.actions);

/// The full paths of what is chosen, into `out`.
fn chosenPaths(self: *Files, out: *std.ArrayList([]u8)) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    for (t.selected.items, 0..) |s, i| {
        if (!s) continue;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = Ops.join(&buffer, dir, t.entry(i).name) catch continue;
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
    return self.clipboard.items.len > 0 and self.tab().path() != null;
}

/// What was copied or cut, here: the pasted chosen afterwards, as Windows
/// chooses them.
pub fn paste(self: *Files) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| self.gpa.free(n);
        names.deinit(self.gpa);
    }
    var failed: ?anyerror = null;
    for (self.clipboard.items) |source| {
        var buffer: [512]u8 = undefined;
        const name = (if (self.clipboard_cut) Ops.moveInto(self.io, source, dir, &buffer) else Ops.copyInto(self.io, source, dir, &buffer)) catch |err| {
            failed = err;
            continue;
        };
        names.append(self.gpa, self.gpa.dupe(u8, name) catch continue) catch {};
    }
    // Cut, it is pasted once: gone from where it was.
    if (self.clipboard_cut) clearClipboard(self);
    if (failed) |err| self.notify("Some items could not be pasted", err);
    self.refreshAll();
    choose(self, names.items);
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
    if (n == 0 or t.path() == null) return;
    if (permanent) {
        self.confirm = .delete_permanently;
        self.window.redraw();
        return;
    }
    deleteChosen(self, false);
}

pub fn deleteChosen(self: *Files, permanent: bool) void {
    var paths: std.ArrayList([]u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    chosenPaths(self, &paths);
    var failed: ?anyerror = null;
    for (paths.items) |p| {
        (if (permanent) Ops.deletePermanently(self.io, p) else Ops.trash(self.io, p)) catch |err| {
            log.warn("could not delete {s}: {t}", .{ p, err });
            failed = err;
        };
    }
    if (failed) |err| self.notify(if (permanent) "Some items could not be deleted" else "Some items could not be moved to the Recycle Bin", err);
    self.refreshAll();
}

/// A new folder here, its name being typed.
pub fn newFolder(self: *Files) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    self.menu = .none;
    var buffer: [256]u8 = undefined;
    const name = Ops.newFolder(self.io, dir, &buffer) catch |err| return self.notify("The folder could not be made", err);
    self.refresh();
    choose(self, &.{name});
    if (t.focus) |i| self.startRename(i);
}

pub fn newTextFile(self: *Files) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    self.menu = .none;
    var buffer: [256]u8 = undefined;
    const name = Ops.newTextFile(self.io, dir, &buffer) catch |err| return self.notify("The document could not be made", err);
    self.refresh();
    choose(self, &.{name});
    if (t.focus) |i| self.startRename(i);
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
