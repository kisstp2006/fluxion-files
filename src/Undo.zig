// SPDX-License-Identifier: BSD-2-Clause

//! Undo and Redo (Ctrl+Z, Ctrl+Y), as File Explorer has them: what was
//! done to files taken back - and done again - one step at a time, the
//! last first.
//!
//! | Done | Undone | Redone |
//! | --- | --- | --- |
//! | renamed | the old name back | the new name again |
//! | made new: a folder, a document, a shortcut | into the Recycle Bin | back out of it |
//! | copied | the copies into the Recycle Bin | back out of it |
//! | moved | moved back where they were | moved again |
//! | put in the Recycle Bin | back out of it, where they were | into it again |
//!
//! Deleted for good is not undone, as Windows has it: it asked first.

const std = @import("std");

const Ops = @import("Ops.zig");

const Undo = @This();

/// The most steps kept: the oldest go past this.
const most = 32;

pub const Kind = enum { rename, new, copy, move, trash };

pub const Moved = struct { from: []const u8, to: []const u8 };
pub const Trashed = struct { path: []const u8, bin: []const u8, stored: []const u8 };

pub const Step = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    /// Renamed: in `dir`, from `old` to `new`.
    dir: []const u8 = "",
    old: []const u8 = "",
    new: []const u8 = "",
    /// Made, copied: the full paths made. Put in the Recycle Bin by Undo,
    /// they are in `trashed`, for Redo to take out again.
    paths: []const []const u8 = &.{},
    moved: []const Moved = &.{},
    trashed: []const Trashed = &.{},

    fn deinit(self: *Step) void {
        self.arena.deinit();
    }

    /// "Rename", "Copy", "Delete": what Undo and Redo say they take back.
    pub fn verb(self: *const Step) []const u8 {
        return switch (self.kind) {
            .rename => "Rename",
            .new => "New",
            .copy => "Copy",
            .move => "Move",
            .trash => "Delete",
        };
    }
};

gpa: std.mem.Allocator,
done: std.ArrayList(*Step) = .empty,
undone: std.ArrayList(*Step) = .empty,

pub fn init(gpa: std.mem.Allocator) Undo {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Undo) void {
    for (self.done.items) |s| self.free(s);
    for (self.undone.items) |s| self.free(s);
    self.done.deinit(self.gpa);
    self.undone.deinit(self.gpa);
}

fn free(self: *Undo, s: *Step) void {
    s.deinit();
    self.gpa.destroy(s);
}

fn create(self: *Undo, kind: Kind) ?*Step {
    const s = self.gpa.create(Step) catch return null;
    s.* = .{ .arena = .init(self.gpa), .kind = kind };
    return s;
}

/// Something done: kept to be undone, and what was undone before it
/// forgotten - it cannot be redone over it.
fn push(self: *Undo, s: *Step) void {
    for (self.undone.items) |u| self.free(u);
    self.undone.clearRetainingCapacity();
    if (self.done.items.len == most) self.free(self.done.orderedRemove(0));
    self.done.append(self.gpa, s) catch self.free(s);
}

pub fn renamed(self: *Undo, dir: []const u8, old: []const u8, new: []const u8) void {
    const s = self.create(.rename) orelse return;
    const a = s.arena.allocator();
    s.dir = a.dupe(u8, dir) catch return self.free(s);
    s.old = a.dupe(u8, old) catch return self.free(s);
    s.new = a.dupe(u8, new) catch return self.free(s);
    self.push(s);
}

/// Made new - `kind` .new - or copied - .copy: the paths made.
pub fn made(self: *Undo, kind: Kind, paths: []const []const u8) void {
    if (paths.len == 0) return;
    const s = self.create(kind) orelse return;
    s.paths = dupeAll(s.arena.allocator(), paths) orelse return self.free(s);
    self.push(s);
}

pub fn movedAll(self: *Undo, moved: []const Moved) void {
    if (moved.len == 0) return;
    const s = self.create(.move) orelse return;
    const a = s.arena.allocator();
    const list = a.alloc(Moved, moved.len) catch return self.free(s);
    for (moved, 0..) |m, i| list[i] = .{ .from = a.dupe(u8, m.from) catch return self.free(s), .to = a.dupe(u8, m.to) catch return self.free(s) };
    s.moved = list;
    self.push(s);
}

pub fn trashedAll(self: *Undo, trashed: []const Trashed) void {
    if (trashed.len == 0) return;
    const s = self.create(.trash) orelse return;
    s.trashed = dupeTrashed(s.arena.allocator(), trashed) orelse return self.free(s);
    self.push(s);
}

fn dupeAll(a: std.mem.Allocator, paths: []const []const u8) ?[]const []const u8 {
    const list = a.alloc([]const u8, paths.len) catch return null;
    for (paths, 0..) |p, i| list[i] = a.dupe(u8, p) catch return null;
    return list;
}

fn dupeTrashed(a: std.mem.Allocator, trashed: []const Trashed) ?[]const Trashed {
    const list = a.alloc(Trashed, trashed.len) catch return null;
    for (trashed, 0..) |t, i| list[i] = .{
        .path = a.dupe(u8, t.path) catch return null,
        .bin = a.dupe(u8, t.bin) catch return null,
        .stored = a.dupe(u8, t.stored) catch return null,
    };
    return list;
}

/// What Undo would take back, if anything.
pub fn next(self: *const Undo) ?*const Step {
    return if (self.done.items.len > 0) self.done.items[self.done.items.len - 1] else null;
}

/// What Redo would do again, if anything.
pub fn nextRedo(self: *const Undo) ?*const Step {
    return if (self.undone.items.len > 0) self.undone.items[self.undone.items.len - 1] else null;
}

/// Take back the last thing done. The paths it leaves - to choose, where
/// the folder shown has them - into `touched`.
pub fn undo(self: *Undo, io: std.Io, touched: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    const s = self.done.pop() orelse return;
    errdefer self.done.append(self.gpa, s) catch self.free(s);
    try apply(s, io, false, touched, arena);
    self.undone.append(self.gpa, s) catch self.free(s);
}

/// Do again the last thing undone.
pub fn redo(self: *Undo, io: std.Io, touched: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    const s = self.undone.pop() orelse return;
    errdefer self.undone.append(self.gpa, s) catch self.free(s);
    try apply(s, io, true, touched, arena);
    self.done.append(self.gpa, s) catch self.free(s);
}

/// The step taken back - or, `again`, done again.
fn apply(s: *Step, io: std.Io, again: bool, touched: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    const a = s.arena.allocator();
    switch (s.kind) {
        .rename => {
            const from = if (again) s.old else s.new;
            const to = if (again) s.new else s.old;
            try Ops.rename(io, s.dir, from, to);
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            try touched.append(arena, try arena.dupe(u8, try Ops.join(&buffer, s.dir, to)));
        },
        .new, .copy => if (!again) {
            // Into the Recycle Bin, kept to be taken out again.
            var list: std.ArrayList(Trashed) = .empty;
            for (s.paths) |p| {
                var bin_buffer: [std.fs.max_path_bytes]u8 = undefined;
                var stored_buffer: [512]u8 = undefined;
                const kept = Ops.trashKeeping(io, p, &bin_buffer, &stored_buffer) catch continue;
                try list.append(a, .{ .path = p, .bin = try a.dupe(u8, kept.bin), .stored = try a.dupe(u8, kept.stored) });
            }
            s.trashed = list.items;
        } else {
            try restoreAll(io, s.trashed, touched, arena);
            s.trashed = &.{};
        },
        .move => for (s.moved) |m| {
            const from = if (again) m.from else m.to;
            const to = if (again) m.to else m.from;
            const into = std.fs.path.dirname(to) orelse "/";
            var name_buffer: [512]u8 = undefined;
            const name = try Ops.moveInto(io, from, into, &name_buffer);
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            try touched.append(arena, try arena.dupe(u8, try Ops.join(&buffer, into, name)));
        },
        .trash => if (!again) {
            try restoreAll(io, s.trashed, touched, arena);
        } else {
            var list: std.ArrayList(Trashed) = .empty;
            for (s.trashed) |t| {
                var bin_buffer: [std.fs.max_path_bytes]u8 = undefined;
                var stored_buffer: [512]u8 = undefined;
                const kept = Ops.trashKeeping(io, t.path, &bin_buffer, &stored_buffer) catch continue;
                try list.append(a, .{ .path = t.path, .bin = try a.dupe(u8, kept.bin), .stored = try a.dupe(u8, kept.stored) });
            }
            s.trashed = list.items;
        },
    }
}

fn restoreAll(io: std.Io, trashed: []const Trashed, touched: *std.ArrayList([]const u8), arena: std.mem.Allocator) !void {
    var failed: ?anyerror = null;
    for (trashed) |t| {
        const dir = std.fs.path.dirname(t.path) orelse "/";
        Ops.restore(io, t.bin, t.stored, dir, std.fs.path.basename(t.path)) catch |err| {
            failed = err;
            continue;
        };
        try touched.append(arena, try arena.dupe(u8, t.path));
    }
    if (failed) |err| return err;
}

test "a rename is undone and done again" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "x" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    try Ops.rename(io, root, "a.txt", "b.txt");
    var undo_state: Undo = .init(std.testing.allocator);
    defer undo_state.deinit();
    undo_state.renamed(root, "a.txt", "b.txt");
    try std.testing.expectEqualStrings("Rename", undo_state.next().?.verb());
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var touched: std.ArrayList([]const u8) = .empty;
    try undo_state.undo(io, &touched, arena.allocator());
    try tmp.dir.access(io, "a.txt", .{});
    try std.testing.expect(undo_state.next() == null);
    try undo_state.redo(io, &touched, arena.allocator());
    try tmp.dir.access(io, "b.txt", .{});
}
