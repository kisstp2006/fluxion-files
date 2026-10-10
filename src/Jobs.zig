// SPDX-License-Identifier: BSD-2-Clause

//! What is done to files that takes a while - copied, moved, put in the
//! Recycle Bin, deleted, taken out of a compressed folder or put in one -
//! done on a thread each, as Windows does them, while the window goes on:
//! the progress dialog shows how far each is, how fast, and what is left,
//! and each can be paused or cancelled.
//!
//! **First the plan**: everything that is to be done, file by file - how
//! big it is all, and which names are taken where it goes. Names taken are
//! asked about once, before anything is copied - "Replace or Skip Files" -
//! and the answers kept for each.
//!
//! **Then the work**, a megabyte at a time between asking whether to pause
//! or stop: a file cut short by Cancel is taken away, the rest left as it
//! is, as Windows leaves it. A copy keeps what it was copied from's
//! permissions and when it was last changed.

const std = @import("std");
const linux = std.os.linux;

const Ops = @import("Ops.zig");
const Archive = @import("Archive.zig");

const Jobs = @This();

const log = std.log.scoped(.jobs);

pub const Kind = enum { copy, move, trash, delete, extract, compress };

/// What is done with a name taken where a file goes.
pub const Answer = enum { replace, skip, keep_both };

pub const State = enum {
    /// Finding out what there is to do.
    planning,
    /// Names are taken: waiting to be told what to do with them.
    asking,
    running,
    done,
    canceled,
};

const Step = struct {
    from: []const u8,
    to: []const u8,
    kind: enum { folder, file, link, rename },
    size: u64 = 0,
    /// A file is there already, by this name.
    conflict: bool = false,
    answer: Answer = .replace,
    /// One of what was chosen, not something inside it: what is chosen
    /// once it is done, and taken back by Undo.
    top: bool = false,
};

/// What a finished job leaves for Undo and for choosing: each thing as it
/// was and as it is; a thing put in the Recycle Bin, where it was, which
/// bin, its name there.
pub const Moved = @import("Undo.zig").Moved;
pub const Trashed = @import("Undo.zig").Trashed;

pub const Job = struct {
    jobs: *Jobs,
    id: u32,
    kind: Kind,
    arena: std.heap.ArenaAllocator,
    sources: []const []const u8,
    /// The folder it goes into; for a ZIP being made, the ZIP.
    dest: []const u8,
    /// Taking out of a compressed folder: the archive's names chosen, or
    /// all of it.
    only: ?[]const []const u8 = null,
    steps: std.ArrayList(Step) = .empty,
    /// The steps whose names are taken.
    conflicts: std.ArrayList(u32) = .empty,

    // -- What the dialog reads, under the lock --
    state: State = .planning,
    total_bytes: u64 = 0,
    total_items: u64 = 0,
    done_bytes: u64 = 0,
    done_items: u64 = 0,
    current_buffer: [256]u8 = undefined,
    current_len: usize = 0,
    /// The speed, in bytes a second, a sample every quarter second.
    samples: [120]f32 = @splat(0),
    sample_count: usize = 0,
    started_ms: i64 = 0,
    last_sample_ms: i64 = 0,
    last_sample_bytes: u64 = 0,
    /// How long it has been paused, all told, and since when now.
    paused_ms: i64 = 0,
    paused_since: i64 = 0,
    failure: ?anyerror = null,
    failed: u32 = 0,
    /// What it made, and what it moved or put in the bin: for Undo, and to
    /// choose what was pasted.
    made: std.ArrayList([]const u8) = .empty,
    moved: std.ArrayList(Moved) = .empty,
    trashed: std.ArrayList(Trashed) = .empty,
    /// The answer to "Replace or Skip Files", given.
    answered: bool = false,

    pause: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),

    pub fn current(self: *const Job) []const u8 {
        return self.current_buffer[0..self.current_len];
    }

    /// How far along it is, nought to one.
    pub fn fraction(self: *const Job) f32 {
        if (self.total_bytes > 0) return @min(1, @as(f32, @floatFromInt(self.done_bytes)) / @as(f32, @floatFromInt(self.total_bytes)));
        if (self.total_items > 0) return @min(1, @as(f32, @floatFromInt(self.done_items)) / @as(f32, @floatFromInt(self.total_items)));
        return 0;
    }

    /// Bytes a second, lately.
    pub fn speed(self: *const Job) f32 {
        if (self.sample_count == 0) return 0;
        const n = @min(self.sample_count, 4);
        var sum: f32 = 0;
        for (0..n) |k| sum += self.samples[(self.sample_count - 1 - k) % self.samples.len];
        return sum / @as(f32, @floatFromInt(n));
    }

    /// Milliseconds left, as the speed so far says - null until it can.
    pub fn remainingMs(self: *const Job, now: i64) ?u64 {
        const ran = now - self.started_ms - self.paused_ms;
        if (ran < 1500 or self.done_bytes == 0 or self.total_bytes == 0) return null;
        const rate = @as(f64, @floatFromInt(self.done_bytes)) / @as(f64, @floatFromInt(ran));
        if (rate <= 0) return null;
        return @intFromFloat(@as(f64, @floatFromInt(self.total_bytes - @min(self.total_bytes, self.done_bytes))) / rate);
    }

    pub fn paused(self: *const Job) bool {
        return self.pause.load(.acquire);
    }

    pub fn finished(self: *const Job) bool {
        return self.state == .done or self.state == .canceled;
    }

    fn deinit(self: *Job) void {
        self.arena.deinit();
    }

    // -- On the thread --

    fn lock(self: *Job) void {
        self.jobs.mutex.lockUncancelable(self.jobs.io);
    }

    fn unlock(self: *Job) void {
        self.jobs.mutex.unlock(self.jobs.io);
    }

    /// Paused: waits. Cancelled: an error, to stop.
    fn check(self: *Job) !void {
        while (self.pause.load(.acquire) and !self.cancel.load(.acquire)) {
            sleepMs(50);
        }
        if (self.cancel.load(.acquire)) return error.Canceled;
    }

    /// `bytes` more done, of `name` now.
    fn advance(self: *Job, bytes: u64, items: u64, name: []const u8) void {
        const now = nowMs();
        self.lock();
        self.done_bytes += bytes;
        self.done_items += items;
        self.current_len = @min(name.len, self.current_buffer.len);
        @memcpy(self.current_buffer[0..self.current_len], name[0..self.current_len]);
        const due = now - self.last_sample_ms >= 250;
        if (due) {
            const dt: f32 = @floatFromInt(@max(1, now - self.last_sample_ms));
            const moved: f32 = @floatFromInt(self.done_bytes - self.last_sample_bytes);
            self.samples[self.sample_count % self.samples.len] = moved / dt * 1000;
            self.sample_count += 1;
            self.last_sample_ms = now;
            self.last_sample_bytes = self.done_bytes;
        }
        self.unlock();
        if (due) self.jobs.poke();
    }
};

gpa: std.mem.Allocator,
io: std.Io,
/// The window's pipe: a byte in it wakes the window to look.
wake: std.c.fd_t,
mutex: std.Io.Mutex = .init,
list: std.ArrayList(*Job) = .empty,
next_id: u32 = 1,
/// Threads still running: the window waits for them as it closes.
threads: std.atomic.Value(u32) = .init(0),

pub fn init(gpa: std.mem.Allocator, io: std.Io, wake: std.c.fd_t) Jobs {
    return .{ .gpa = gpa, .io = io, .wake = wake };
}

pub fn deinit(self: *Jobs) void {
    for (self.list.items) |j| j.cancel.store(true, .release);
    while (self.threads.load(.acquire) > 0) sleepMs(10);
    for (self.list.items) |j| {
        j.deinit();
        self.gpa.destroy(j);
    }
    self.list.deinit(self.gpa);
}

fn poke(self: *Jobs) void {
    _ = std.c.write(self.wake, "j", 1);
}

/// Start a job: `kind` of `sources` - full paths - into `dest`. `only`:
/// the names inside a compressed folder to take out of it.
pub fn start(self: *Jobs, kind: Kind, sources: []const []const u8, dest: []const u8, only: ?[]const []const u8) void {
    const job = self.gpa.create(Job) catch return;
    job.* = .{ .jobs = self, .id = self.next_id, .kind = kind, .arena = .init(self.gpa), .sources = &.{}, .dest = "", .started_ms = nowMs() };
    job.last_sample_ms = job.started_ms;
    self.next_id += 1;
    const a = job.arena.allocator();
    const copies = a.alloc([]const u8, sources.len) catch return self.drop(job);
    for (sources, 0..) |s, i| copies[i] = a.dupe(u8, s) catch return self.drop(job);
    job.sources = copies;
    job.dest = a.dupe(u8, dest) catch return self.drop(job);
    if (only) |names| {
        const o = a.alloc([]const u8, names.len) catch return self.drop(job);
        for (names, 0..) |n, i| o[i] = a.dupe(u8, n) catch return self.drop(job);
        job.only = o;
    }
    self.mutex.lockUncancelable(self.io);
    self.list.append(self.gpa, job) catch {
        self.mutex.unlock(self.io);
        return self.drop(job);
    };
    self.mutex.unlock(self.io);
    _ = self.threads.fetchAdd(1, .acq_rel);
    const thread = std.Thread.spawn(.{}, work, .{job}) catch {
        _ = self.threads.fetchSub(1, .acq_rel);
        job.state = .canceled;
        return;
    };
    thread.detach();
}

fn drop(self: *Jobs, job: *Job) void {
    job.deinit();
    self.gpa.destroy(job);
}

pub fn lock(self: *Jobs) void {
    self.mutex.lockUncancelable(self.io);
}

pub fn unlock(self: *Jobs) void {
    self.mutex.unlock(self.io);
}

/// The jobs finished, taken out of the list for the window to look at
/// and then `release`.
pub fn takeFinished(self: *Jobs, out: *std.ArrayList(*Job)) void {
    self.lock();
    defer self.unlock();
    var i: usize = 0;
    while (i < self.list.items.len) {
        const j = self.list.items[i];
        if (j.finished()) {
            out.append(self.gpa, self.list.orderedRemove(i)) catch {
                i += 1;
                continue;
            };
        } else i += 1;
    }
}

pub fn release(self: *Jobs, job: *Job) void {
    self.drop(job);
}

/// Whether any is still going.
pub fn running(self: *Jobs) bool {
    self.lock();
    defer self.unlock();
    for (self.list.items) |j| if (!j.finished()) return true;
    return false;
}

/// "Replace or Skip Files" answered: the same for every name taken, or -
/// `each` - as set on each step already.
pub fn answer(self: *Jobs, job: *Job, all: ?Answer) void {
    self.lock();
    if (all) |a| for (job.conflicts.items) |i| {
        job.steps.items[i].answer = a;
    };
    job.answered = true;
    self.unlock();
}

/// The same, the lock held already: from the dialog, drawn with it.
pub fn answerLocked(self: *Jobs, job: *Job, all: Answer) void {
    _ = self;
    for (job.conflicts.items) |i| job.steps.items[i].answer = all;
    job.answered = true;
}

pub fn togglePause(self: *Jobs, job: *Job) void {
    self.lock();
    defer self.unlock();
    const now = nowMs();
    if (job.pause.load(.acquire)) {
        job.paused_ms += now - job.paused_since;
        job.pause.store(false, .release);
    } else {
        job.paused_since = now;
        job.pause.store(true, .release);
    }
}

pub fn cancel(job: *Job) void {
    job.cancel.store(true, .release);
}

// -------------------------------------------------------------------------
// The thread
// -------------------------------------------------------------------------

fn work(job: *Job) void {
    const jobs = job.jobs;
    defer _ = jobs.threads.fetchSub(1, .acq_rel);
    const result = run(job);
    job.lock();
    if (result) |_| {
        job.state = if (job.cancel.load(.acquire)) .canceled else .done;
    } else |err| {
        if (err == error.Canceled) job.state = .canceled else {
            job.failure = err;
            job.state = .done;
        }
    }
    job.unlock();
    jobs.poke();
}

fn run(job: *Job) !void {
    switch (job.kind) {
        .copy, .move => {
            try plan(job);
            try ask(job);
            try copySteps(job);
        },
        .trash, .delete => try remove(job),
        .extract => try extract(job),
        .compress => try compress(job),
    }
}

/// Names taken: asked about, and waited for.
fn ask(job: *Job) !void {
    if (job.conflicts.items.len == 0) {
        job.lock();
        job.state = .running;
        job.unlock();
        return;
    }
    job.lock();
    job.state = .asking;
    job.unlock();
    job.jobs.poke();
    while (true) {
        try job.check();
        job.lock();
        const done = job.answered;
        job.unlock();
        if (done) break;
        sleepMs(30);
    }
    job.lock();
    job.state = .running;
    // Time spent being asked is not time spent copying.
    job.started_ms = nowMs();
    job.last_sample_ms = job.started_ms;
    job.unlock();
}

// -- Copy and move --

fn plan(job: *Job) !void {
    const io = job.jobs.io;
    const a = job.arena.allocator();
    for (job.sources) |source| {
        try job.check();
        const from_dir = std.fs.path.dirname(source) orelse "/";
        const here = std.mem.eql(u8, from_dir, job.dest);
        // Moved where it is, or into itself: nothing.
        if (job.kind == .move and here) continue;
        if (Ops.isInside(job.dest, source)) {
            job.failure = error.IntoItself;
            continue;
        }
        const stat = std.Io.Dir.cwd().statFile(io, source, .{ .follow_symlinks = false }) catch |err| {
            job.failure = err;
            job.failed += 1;
            continue;
        };
        const folder = stat.kind == .directory;
        var name_buffer: [512]u8 = undefined;
        // Copied into its own folder: "- Copy", as Windows names it.
        const name = if (here) Ops.freeName(io, job.dest, std.fs.path.basename(source), folder, true, &name_buffer) else std.fs.path.basename(source);
        var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const to = try a.dupe(u8, try Ops.join(&to_buffer, job.dest, name));
        const there = std.Io.Dir.cwd().statFile(io, to, .{ .follow_symlinks = false }) catch null;
        // Moved within a drive to where nothing is by its name: renamed,
        // whole, at once.
        if (job.kind == .move and there == null and sameDevice(source, job.dest)) {
            try job.steps.append(a, .{ .from = source, .to = to, .kind = .rename, .top = true });
            job.total_items += 1;
            continue;
        }
        try addTree(job, source, to, stat, there, true, 0);
    }
}

fn sameDevice(a: []const u8, b: []const u8) bool {
    const x = Ops.deviceOf(a) orelse return false;
    const y = Ops.deviceOf(b) orelse return false;
    return x == y;
}

fn addTree(job: *Job, from: []const u8, to: []const u8, stat: std.Io.File.Stat, there: ?std.Io.File.Stat, top: bool, depth: u8) !void {
    if (depth > 64) return error.TooDeep;
    const io = job.jobs.io;
    const a = job.arena.allocator();
    switch (stat.kind) {
        .directory => {
            // A folder there already of its name: what is in both put
            // together, names taken asked about one by one.
            try job.steps.append(a, .{ .from = from, .to = to, .kind = .folder, .top = top, .conflict = false });
            job.total_items += 1;
            var dir = std.Io.Dir.cwd().openDir(io, from, .{ .iterate = true }) catch |err| {
                job.failure = err;
                job.failed += 1;
                return;
            };
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |entry| {
                try job.check();
                var from_buffer: [std.fs.max_path_bytes]u8 = undefined;
                var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const child_from = try a.dupe(u8, try Ops.join(&from_buffer, from, entry.name));
                const child_to = try a.dupe(u8, try Ops.join(&to_buffer, to, entry.name));
                const child = std.Io.Dir.cwd().statFile(io, child_from, .{ .follow_symlinks = false }) catch continue;
                const child_there = if (there != null) std.Io.Dir.cwd().statFile(io, child_to, .{ .follow_symlinks = false }) catch null else null;
                try addTree(job, child_from, child_to, child, child_there, false, depth + 1);
            }
        },
        .sym_link => {
            try job.steps.append(a, .{ .from = from, .to = to, .kind = .link, .top = top, .conflict = there != null });
            if (there != null) try job.conflicts.append(a, @intCast(job.steps.items.len - 1));
            job.total_items += 1;
        },
        else => {
            const conflict = there != null and there.?.kind != .directory;
            try job.steps.append(a, .{ .from = from, .to = to, .kind = .file, .size = stat.size, .top = top, .conflict = conflict });
            if (conflict) try job.conflicts.append(a, @intCast(job.steps.items.len - 1));
            job.total_items += 1;
            job.total_bytes += stat.size;
        },
    }
}

fn copySteps(job: *Job) !void {
    const io = job.jobs.io;
    const a = job.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    // Folders made, in order; emptied ones taken away after a move.
    var folders_moved: std.ArrayList([]const u8) = .empty;
    for (job.steps.items) |*step| {
        try job.check();
        var to = step.to;
        if (step.conflict) switch (step.answer) {
            .skip => {
                job.advance(step.size, 1, std.fs.path.basename(step.from));
                continue;
            },
            .keep_both => {
                var name_buffer: [512]u8 = undefined;
                const dir = std.fs.path.dirname(step.to) orelse "/";
                const name = Ops.freeName(io, dir, std.fs.path.basename(step.to), false, false, &name_buffer);
                var to_buffer: [std.fs.max_path_bytes]u8 = undefined;
                to = try a.dupe(u8, try Ops.join(&to_buffer, dir, name));
            },
            .replace => {},
        };
        const name = std.fs.path.basename(step.from);
        switch (step.kind) {
            .rename => {
                std.Io.Dir.renameAbsolute(step.from, to, io) catch |err| {
                    job.failure = err;
                    job.failed += 1;
                    continue;
                };
                job.advance(0, 1, name);
            },
            .folder => {
                cwd.createDir(io, to, .default_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        job.failure = err;
                        job.failed += 1;
                        continue;
                    },
                };
                if (job.kind == .move) try folders_moved.append(a, step.from);
                job.advance(0, 1, name);
            },
            .link => {
                var target_buffer: [std.fs.max_path_bytes]u8 = undefined;
                const n = cwd.readLink(io, step.from, &target_buffer) catch |err| {
                    job.failure = err;
                    job.failed += 1;
                    continue;
                };
                if (step.conflict) cwd.deleteFile(io, to) catch {};
                cwd.symLink(io, target_buffer[0..n], to, .{}) catch |err| {
                    job.failure = err;
                    job.failed += 1;
                    continue;
                };
                if (job.kind == .move) cwd.deleteFile(io, step.from) catch {};
                job.advance(0, 1, name);
            },
            .file => {
                // Within a drive, a file moved is renamed.
                const renamed = job.kind == .move and sameDevice(step.from, std.fs.path.dirname(to) orelse "/") and blk: {
                    std.Io.Dir.renameAbsolute(step.from, to, io) catch break :blk false;
                    break :blk true;
                };
                if (renamed) {
                    job.advance(step.size, 1, name);
                } else {
                    copyFile(job, step.from, to, step.size) catch |err| {
                        if (err == error.Canceled) return err;
                        job.failure = err;
                        job.failed += 1;
                        continue;
                    };
                    job.advance(0, 1, name);
                    if (job.kind == .move) cwd.deleteFile(io, step.from) catch |err| {
                        job.failure = err;
                    };
                }
            },
        }
        if (step.top) {
            try job.made.append(a, to);
            if (job.kind == .move) try job.moved.append(a, .{ .from = step.from, .to = to });
        }
    }
    // A move across drives: the folders emptied, gone - the deepest first.
    var i = folders_moved.items.len;
    while (i > 0) {
        i -= 1;
        cwd.deleteDir(io, folders_moved.items[i]) catch {};
    }
}

/// `from` copied to `to`, a megabyte at a time; its permissions and when
/// it was changed kept. Cut short, what was made of it is taken away.
fn copyFile(job: *Job, from: []const u8, to: []const u8, size: u64) !void {
    _ = size;
    const io = job.jobs.io;
    const cwd = std.Io.Dir.cwd();
    const source = try cwd.openFile(io, from, .{});
    defer source.close(io);
    const stat = try source.stat(io);
    const dest = try cwd.createFile(io, to, .{ .truncate = true, .permissions = stat.permissions });
    var ok = false;
    defer {
        dest.close(io);
        if (!ok) cwd.deleteFile(io, to) catch {};
    }
    const name = std.fs.path.basename(from);
    const buffer = try job.jobs.gpa.alloc(u8, 1 << 20);
    defer job.jobs.gpa.free(buffer);
    // A slow disk, for a test to see the dialog by: so many bytes a second.
    const rate: u64 = if (std.c.getenv("FLUXION_FILES_COPY_RATE")) |r| std.fmt.parseInt(u64, std.mem.span(r), 10) catch 0 else 0;
    while (true) {
        try job.check();
        if (rate > 0) sleepMs((buffer.len * 1000) / rate);
        const n = try std.posix.read(source.handle, buffer);
        if (n == 0) break;
        var written: usize = 0;
        while (written < n) {
            const w = std.c.write(dest.handle, buffer[written..n].ptr, n - written);
            if (w <= 0) return if (std.c._errno().* == @intFromEnum(linux.E.NOSPC)) error.NoSpaceLeft else error.WriteFailed;
            written += @intCast(w);
        }
        job.advance(n, 0, name);
    }
    dest.setTimestamps(io, .{ .modify_timestamp = .{ .new = stat.mtime } }) catch {};
    ok = true;
}

// -- The Recycle Bin, and gone for good --

fn remove(job: *Job) !void {
    const io = job.jobs.io;
    const a = job.arena.allocator();
    job.lock();
    job.total_items = job.sources.len;
    job.state = .running;
    job.unlock();
    for (job.sources) |source| {
        try job.check();
        const name = std.fs.path.basename(source);
        if (job.kind == .trash) {
            var bin_buffer: [std.fs.max_path_bytes]u8 = undefined;
            var stored_buffer: [512]u8 = undefined;
            if (Ops.trashKeeping(io, source, &bin_buffer, &stored_buffer)) |kept| {
                try job.trashed.append(a, .{ .path = source, .bin = try a.dupe(u8, kept.bin), .stored = try a.dupe(u8, kept.stored) });
            } else |err| {
                job.failure = err;
                job.failed += 1;
            }
        } else Ops.deletePermanently(io, source) catch |err| {
            job.failure = err;
            job.failed += 1;
        };
        job.advance(0, 1, name);
    }
}

// -- Compressed folders --

fn extract(job: *Job) !void {
    const a = job.arena.allocator();
    const archive = job.sources[0];
    var entries: std.ArrayList(Archive.Entry) = .empty;
    try Archive.list(a, archive, &entries);
    for (entries.items) |e| {
        if (job.only) |only| {
            var wanted = false;
            for (only) |o| if (std.mem.eql(u8, e.path, o) or (std.mem.startsWith(u8, e.path, o) and e.path.len > o.len and e.path[o.len] == '/')) {
                wanted = true;
            };
            if (!wanted) continue;
        }
        job.total_bytes += e.size;
        job.total_items += 1;
    }
    job.lock();
    job.state = .running;
    job.unlock();
    try Archive.extract(job.jobs.io, archive, job.dest, job.only, .{ .context = job, .step = extractStep });
    // What was taken out at the top, to be chosen.
    for (entries.items) |e| {
        if (std.mem.indexOfScalar(u8, e.path, '/') != null) continue;
        if (job.only) |only| {
            var wanted = false;
            for (only) |o| if (std.mem.eql(u8, e.path, o)) {
                wanted = true;
            };
            if (!wanted) continue;
        }
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        try job.made.append(a, try a.dupe(u8, try Ops.join(&buffer, job.dest, e.path)));
    }
}

fn extractStep(context: *anyopaque, bytes: u64, name: []const u8) bool {
    const job: *Job = @ptrCast(@alignCast(context));
    job.check() catch return false;
    job.advance(bytes, if (bytes == 0) 1 else 0, std.fs.path.basename(name));
    return true;
}

fn compress(job: *Job) !void {
    const io = job.jobs.io;
    for (job.sources) |source| {
        try job.check();
        const stat = std.Io.Dir.cwd().statFile(io, source, .{ .follow_symlinks = false }) catch continue;
        try sizeOf(job, source, stat, 0);
    }
    job.lock();
    job.state = .running;
    job.unlock();
    try Archive.createZip(io, job.dest, job.sources, .{ .context = job, .step = extractStep });
    try job.made.append(job.arena.allocator(), job.dest);
}

fn sizeOf(job: *Job, path: []const u8, stat: std.Io.File.Stat, depth: u8) !void {
    if (depth > 64) return;
    const io = job.jobs.io;
    job.total_items += 1;
    if (stat.kind != .directory) {
        job.total_bytes += stat.size;
        return;
    }
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const child = Ops.join(&buffer, path, entry.name) catch continue;
        const child_stat = std.Io.Dir.cwd().statFile(io, child, .{ .follow_symlinks = false }) catch continue;
        try sizeOf(job, child, child_stat, depth + 1);
    }
}

// -------------------------------------------------------------------------

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

pub fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// "About 10 seconds", "About 2 minutes", as Windows says what is left.
pub fn remainingText(ms: ?u64, buffer: []u8) []const u8 {
    const left = ms orelse return "Calculating\u{2026}";
    const s = (left + 999) / 1000;
    if (s < 5) return "A few seconds";
    if (s < 60) return std.fmt.bufPrint(buffer, "About {d} seconds", .{(s + 4) / 5 * 5}) catch "";
    const m = (s + 30) / 60;
    if (m < 60) return std.fmt.bufPrint(buffer, "About {d} minute{s}", .{ m, if (m == 1) "" else "s" }) catch "";
    const h = m / 60;
    return std.fmt.bufPrint(buffer, "About {d} hour{s} and {d} minutes", .{ h, if (h == 1) "" else "s", m % 60 }) catch "";
}

test "a folder copied by plan, its names taken asked about, then copied" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/inner/a.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/b.txt", .data = "new" });
    try tmp.dir.createDirPath(io, "dest/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "dest/src/b.txt", .data = "old" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var src_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buffer, "{s}/src", .{root});
    const dest = try std.fmt.bufPrint(&dest_buffer, "{s}/dest", .{root});
    var jobs: Jobs = .init(std.testing.allocator, io, -1);
    defer jobs.deinit();
    var job: Job = .{ .jobs = &jobs, .id = 1, .kind = .copy, .arena = .init(std.testing.allocator), .sources = &.{src}, .dest = dest };
    defer job.deinit();
    try plan(&job);
    try std.testing.expectEqual(@as(usize, 1), job.conflicts.items.len);
    try std.testing.expectEqual(@as(u64, 8), job.total_bytes);
    // Both kept: the new one numbered.
    job.steps.items[job.conflicts.items[0]].answer = .keep_both;
    try copySteps(&job);
    var read_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try tmp.dir.readFile(io, "dest/src/inner/a.txt", &read_buffer));
    try std.testing.expectEqualStrings("old", try tmp.dir.readFile(io, "dest/src/b.txt", &read_buffer));
    try std.testing.expectEqualStrings("new", try tmp.dir.readFile(io, "dest/src/b (2).txt", &read_buffer));
    try std.testing.expectEqual(job.total_bytes, job.done_bytes);
}

test "what is left is said as Windows says it" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Calculating\u{2026}", remainingText(null, &buffer));
    try std.testing.expectEqualStrings("About 10 seconds", remainingText(9_200, &buffer));
    try std.testing.expectEqualStrings("About 2 minutes", remainingText(110_000, &buffer));
}
