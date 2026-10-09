// SPDX-License-Identifier: BSD-2-Clause

//! Search, as the box in the address row asks for it: every file and
//! folder under the folder shown whose name has what was typed in it, case
//! aside - walked on a thread of its own, the findings handed to the
//! window as they come, so the list fills while it searches and the window
//! never waits.

const std = @import("std");

const Search = @This();

const log = std.log.scoped(.search);

/// How many findings before it stops: enough for any list a person reads.
const most = 5000;

gpa: std.mem.Allocator,
io: std.Io,
/// The window's pipe: a byte written wakes it to take what was found.
wake: std.c.fd_t,
job: ?*Job = null,

const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    wake: std.c.fd_t,
    folder: []u8,
    query: []u8,
    mutex: std.Io.Mutex = .init,
    found: std.ArrayList([]u8) = .empty,
    done: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    thread: std.Thread = undefined,

    fn run(job: *Job) void {
        defer {
            job.done.store(true, .release);
            _ = std.c.write(job.wake, "s", 1);
        }
        var stack: std.ArrayList([]u8) = .empty;
        defer {
            for (stack.items) |p| job.gpa.free(p);
            stack.deinit(job.gpa);
        }
        stack.append(job.gpa, job.gpa.dupe(u8, job.folder) catch return) catch return;
        var count: usize = 0;
        var since_wake: usize = 0;
        while (stack.pop()) |dir_path| {
            defer job.gpa.free(dir_path);
            if (job.cancel.load(.acquire)) return;
            var dir = std.Io.Dir.cwd().openDir(job.io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(job.io);
            var it = dir.iterate();
            while (it.next(job.io) catch null) |entry| {
                if (job.cancel.load(.acquire)) return;
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const full = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ if (std.mem.eql(u8, dir_path, "/")) "" else dir_path, entry.name }) catch continue;
                if (containsIgnoreCase(entry.name, job.query)) {
                    const copy = job.gpa.dupe(u8, full) catch continue;
                    job.mutex.lockUncancelable(job.io);
                    job.found.append(job.gpa, copy) catch job.gpa.free(copy);
                    job.mutex.unlock(job.io);
                    count += 1;
                    since_wake += 1;
                    if (count >= most) return;
                    // Told in batches: a byte a few dozen findings.
                    if (since_wake >= 32) {
                        since_wake = 0;
                        _ = std.c.write(job.wake, "s", 1);
                    }
                }
                // Into folders - not into the hidden ones, nor through links.
                if (entry.kind == .directory and entry.name[0] != '.') {
                    stack.append(job.gpa, job.gpa.dupe(u8, full) catch continue) catch {};
                }
            }
        }
    }

    fn finish(job: *Job) void {
        job.cancel.store(true, .release);
        job.thread.join();
        for (job.found.items) |p| job.gpa.free(p);
        job.found.deinit(job.gpa);
        job.gpa.free(job.folder);
        job.gpa.free(job.query);
        job.gpa.destroy(job);
    }
};

pub fn deinit(self: *Search) void {
    self.stop();
}

/// Search `folder` for `query`, whatever was being searched before let go.
pub fn start(self: *Search, folder: []const u8, query: []const u8) void {
    self.stop();
    const job = self.gpa.create(Job) catch return;
    job.* = .{
        .gpa = self.gpa,
        .io = self.io,
        .wake = self.wake,
        .folder = self.gpa.dupe(u8, folder) catch {
            self.gpa.destroy(job);
            return;
        },
        .query = self.gpa.dupe(u8, query) catch {
            self.gpa.destroy(job);
            return;
        },
    };
    job.thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        self.gpa.free(job.folder);
        self.gpa.free(job.query);
        self.gpa.destroy(job);
        return;
    };
    self.job = job;
}

pub fn stop(self: *Search) void {
    if (self.job) |job| job.finish();
    self.job = null;
}

/// Whether it is still looking.
pub fn running(self: *const Search) bool {
    const job = self.job orelse return false;
    return !job.done.load(.acquire);
}

/// What was found since asked last, handed over: the caller frees each.
pub fn take(self: *Search, out: *std.ArrayList([]u8)) void {
    const job = self.job orelse return;
    job.mutex.lockUncancelable(job.io);
    defer job.mutex.unlock(job.io);
    out.appendSlice(self.gpa, job.found.items) catch {
        for (job.found.items) |p| self.gpa.free(p);
    };
    job.found.clearRetainingCapacity();
}

/// Whether `text` has `query` in it, ASCII letters' case aside.
pub fn containsIgnoreCase(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > text.len) return false;
    var i: usize = 0;
    while (i + query.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i .. i + query.len], query)) return true;
    }
    return false;
}

test "names are found whatever their case" {
    try std.testing.expect(containsIgnoreCase("Report-2026.PDF", "report"));
    try std.testing.expect(containsIgnoreCase("notes.txt", "TES"));
    try std.testing.expect(!containsIgnoreCase("a.txt", "b"));
}

test "a folder's tree is searched on a thread" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "a/deep/er");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/deep/er/Target.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a/other.txt", .data = "x" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try tmp.dir.realPath(io, &path_buffer)];
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    defer for (fds) |fd| {
        _ = std.c.close(fd);
    };
    var search: Search = .{ .gpa = std.testing.allocator, .io = io, .wake = fds[1] };
    defer search.deinit();
    search.start(root, "target");
    while (search.running()) std.Thread.yield() catch {};
    var found: std.ArrayList([]u8) = .empty;
    defer {
        for (found.items) |p| std.testing.allocator.free(p);
        found.deinit(std.testing.allocator);
    }
    search.take(&found);
    try std.testing.expectEqual(@as(usize, 1), found.items.len);
    try std.testing.expect(std.mem.endsWith(u8, found.items[0], "a/deep/er/Target.txt"));
}
