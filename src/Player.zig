// SPDX-License-Identifier: BSD-2-Clause

//! A video or a song played in the preview pane, as Windows' preview pane
//! plays one: FFmpeg decodes it at its own pace - the pictures made as
//! small as the pane, handed over a pipe and read here on a thread, the
//! sound sent to the desktop's sound server - and the pane shows the newest
//! picture each time it is drawn.
//!
//! **Paused, FFmpeg is stopped**, and started again from where it was:
//! told to play at the pace of its own clock, one kept waiting would race
//! to catch up. A jump along the bar is the same: started again from
//! there. Each run is a thread of its own and owns its FFmpeg; stopping
//! one is a signal, and the thread lets go of the rest.

const std = @import("std");
const raster = @import("fluxion_ui_raster");

const Icons = @import("Icons.zig");

const Player = @This();

const log = std.log.scoped(.player);

pub const State = enum { stopped, playing, paused, ended };

gpa: std.mem.Allocator,
io: std.Io,
wake: std.c.fd_t,
path_buffer: [std.fs.max_path_bytes]u8 = undefined,
path_len: usize = 0,
duration_ms: u64 = 0,
has_video: bool = false,
has_audio: bool = false,
/// The size the pictures are made at.
frame_w: u32 = 0,
frame_h: u32 = 0,
state: State = .stopped,
muted: bool = false,
/// Where it is, when it is not playing; and, playing, where it started
/// and when.
position_ms: u64 = 0,
started_at_ms: i64 = 0,
/// The window's slot the newest picture is in; null before the first.
slot: ?u32 = null,
/// Which run is the one playing: a picture or an ending from one before
/// it is not this one's.
run: u32 = 0,
shared: Shared = .{},

const Shared = struct {
    mutex: std.Io.Mutex = .init,
    /// The newest picture, for the run it came from.
    frame: ?raster.Image = null,
    frame_run: u32 = 0,
    /// A run that came to its end by itself.
    ended_run: u32 = 0,
    /// The FFmpeg playing, to be stopped: its process.
    pid: std.posix.pid_t = 0,
    pid_run: u32 = 0,
    /// Whether a byte is in the pipe already: one is enough.
    woken: bool = false,
    threads: u32 = 0,
};

pub fn init(gpa: std.mem.Allocator, io: std.Io, wake: std.c.fd_t) Player {
    return .{ .gpa = gpa, .io = io, .wake = wake, .muted = std.c.getenv("FLUXION_PREVIEW_MUTE") != null };
}

pub fn deinit(self: *Player) void {
    self.stop();
    // The threads let go of their FFmpeg, and of this, before it goes.
    while (true) {
        self.shared.mutex.lockUncancelable(self.io);
        const threads = self.shared.threads;
        self.shared.mutex.unlock(self.io);
        if (threads == 0) break;
        std.Thread.yield() catch {};
    }
    if (self.shared.frame) |*f| f.deinit(self.gpa);
}

/// The file it plays: `path`, `duration_ms` long, with pictures and sound
/// or not, its pictures `w` by `h`. Another than it had, it stops.
pub fn load(self: *Player, path: []const u8, duration_ms: u64, has_video: bool, has_audio: bool, w: u32, h: u32) void {
    const same = std.mem.eql(u8, self.path_buffer[0..self.path_len], path);
    if (same and self.frame_w == w and self.frame_h == h) return;
    if (!same) {
        self.stop();
        self.state = .stopped;
        self.position_ms = 0;
    }
    self.path_len = @min(path.len, self.path_buffer.len);
    @memcpy(self.path_buffer[0..self.path_len], path[0..self.path_len]);
    self.duration_ms = duration_ms;
    self.has_video = has_video;
    self.has_audio = has_audio;
    // Even, as FFmpeg's scaler wants them.
    self.frame_w = @max(2, w & ~@as(u32, 1));
    self.frame_h = @max(2, h & ~@as(u32, 1));
    // Bigger or smaller while playing: on from here at the new size.
    if (same and self.state == .playing) self.restart();
}

/// Played no more: another file chosen, the pane closed.
pub fn unload(self: *Player) void {
    self.stop();
    self.path_len = 0;
    self.state = .stopped;
    self.position_ms = 0;
}

pub fn loaded(self: *const Player, path: []const u8) bool {
    return self.path_len > 0 and std.mem.eql(u8, self.path_buffer[0..self.path_len], path);
}

/// Where it is, in milliseconds.
pub fn position(self: *const Player) u64 {
    if (self.state != .playing) return self.position_ms;
    const ms: u64 = @intCast(@max(0, nowMs() - self.started_at_ms));
    return @min(self.duration_ms, self.position_ms + ms);
}

pub fn toggle(self: *Player) void {
    switch (self.state) {
        .playing => self.pause(),
        .ended => {
            self.position_ms = 0;
            self.play();
        },
        else => self.play(),
    }
}

pub fn play(self: *Player) void {
    if (self.path_len == 0) return;
    self.state = .playing;
    self.restart();
}

pub fn pause(self: *Player) void {
    if (self.state != .playing) return;
    self.position_ms = self.position();
    self.stop();
    self.state = .paused;
}

/// To `ms` along: on from there, playing or not.
pub fn seek(self: *Player, ms: u64) void {
    self.position_ms = @min(ms, self.duration_ms);
    if (self.state == .ended) self.state = .paused;
    if (self.state == .playing) self.restart();
}

pub fn toggleMute(self: *Player) void {
    self.muted = !self.muted;
    if (self.state == .playing) {
        self.position_ms = self.position();
        self.restart();
    }
}

/// Whether it is playing: the pane drawn again and again.
pub fn playing(self: *const Player) bool {
    return self.state == .playing;
}

fn stop(self: *Player) void {
    self.shared.mutex.lockUncancelable(self.io);
    const pid = if (self.shared.pid_run == self.run) self.shared.pid else 0;
    self.shared.pid = 0;
    self.shared.mutex.unlock(self.io);
    if (pid > 0) std.posix.kill(pid, .TERM) catch {};
    self.run +%= 1;
}

fn restart(self: *Player) void {
    self.stop();
    self.started_at_ms = nowMs();
    const job = self.gpa.create(Job) catch return;
    job.* = .{ .player = self, .run = self.run };
    if (!job.argv(self)) {
        self.gpa.destroy(job);
        self.state = .ended;
        return;
    }
    self.shared.mutex.lockUncancelable(self.io);
    self.shared.threads += 1;
    self.shared.mutex.unlock(self.io);
    const thread = std.Thread.spawn(.{}, Job.work, .{job}) catch {
        self.shared.mutex.lockUncancelable(self.io);
        self.shared.threads -= 1;
        self.shared.mutex.unlock(self.io);
        self.gpa.destroy(job);
        return;
    };
    thread.detach();
}

/// The newest picture into the window's slot, and an ending heard. Whether
/// there is anything new to draw.
pub fn take(self: *Player, icons: *Icons) bool {
    self.shared.mutex.lockUncancelable(self.io);
    defer self.shared.mutex.unlock(self.io);
    self.shared.woken = false;
    var any = false;
    if (self.shared.frame) |newest| {
        self.shared.frame = null;
        if (self.shared.frame_run == self.run) {
            self.slot = icons.put(self.slot, newest);
            any = true;
        } else {
            var gone = newest;
            gone.deinit(self.gpa);
        }
    }
    if (self.shared.ended_run == self.run and self.state == .playing) {
        self.shared.ended_run = 0;
        self.state = .ended;
        self.position_ms = self.duration_ms;
        any = true;
    }
    return any;
}

/// The picture to show: the newest made, while there is one.
pub fn frame(self: *const Player) ?u32 {
    if (self.state == .stopped) return null;
    return self.slot;
}

/// One run of FFmpeg, and the thread that reads it.
const Job = struct {
    player: *Player,
    run: u32,
    args: [32][]const u8 = undefined,
    arg_count: usize = 0,
    text: [4][64]u8 = undefined,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    w: u32 = 0,
    h: u32 = 0,
    video: bool = false,

    fn add(self: *Job, arg: []const u8) void {
        self.args[self.arg_count] = arg;
        self.arg_count += 1;
    }

    fn argv(self: *Job, p: *Player) bool {
        const path = std.fmt.bufPrint(&self.path_buffer, "{s}", .{p.path_buffer[0..p.path_len]}) catch return false;
        self.w = p.frame_w;
        self.h = p.frame_h;
        self.video = p.has_video;
        self.add("ffmpeg");
        self.add("-v");
        self.add("error");
        self.add("-nostdin");
        self.add("-ss");
        self.add(std.fmt.bufPrint(&self.text[0], "{d:.3}", .{@as(f64, @floatFromInt(p.position_ms)) / 1000}) catch return false);
        // At the pace of its own clock: as fast as it plays.
        self.add("-re");
        self.add("-i");
        self.add(path);
        if (self.video) {
            self.add("-map");
            self.add("0:v:0");
            self.add("-vf");
            self.add(std.fmt.bufPrint(&self.text[1], "scale={d}:{d}", .{ self.w, self.h }) catch return false);
            self.add("-f");
            self.add("rawvideo");
            // The bytes as a picture of the renderer's holds them: blue,
            // green, red, alpha.
            self.add("-pix_fmt");
            self.add("bgra");
            self.add("pipe:1");
        }
        if (p.has_audio and !p.muted) {
            self.add("-map");
            self.add("0:a:0");
            self.add("-f");
            self.add("pulse");
            self.add("-name");
            self.add("Files");
            self.add("default");
        }
        // Nothing to show and nothing to hear: muted music.
        if (!self.video and (p.muted or !p.has_audio)) {
            self.add("-f");
            self.add("null");
            self.add("-");
        }
        return true;
    }

    fn work(self: *Job) void {
        const p = self.player;
        const gpa = p.gpa;
        defer {
            p.shared.mutex.lockUncancelable(p.io);
            p.shared.threads -= 1;
            p.shared.mutex.unlock(p.io);
            gpa.destroy(self);
        }
        var child = std.process.spawn(p.io, .{
            .argv = self.args[0..self.arg_count],
            .stdin = .ignore,
            .stdout = if (self.video) .pipe else .ignore,
            .stderr = .ignore,
        }) catch |err| {
            log.warn("could not play: {t}", .{err});
            self.ended();
            return;
        };
        p.shared.mutex.lockUncancelable(p.io);
        const stale = p.run != self.run;
        if (!stale) {
            p.shared.pid = child.id orelse 0;
            p.shared.pid_run = self.run;
        }
        p.shared.mutex.unlock(p.io);
        if (stale) {
            child.kill(p.io);
            return;
        }
        if (self.video) self.readFrames(child.stdout.?.handle);
        _ = child.wait(p.io) catch {};
        self.ended();
    }

    /// Picture after picture, as long as FFmpeg makes them.
    fn readFrames(self: *Job, fd: std.posix.fd_t) void {
        const p = self.player;
        const gpa = p.gpa;
        const size = @as(usize, self.w) * self.h * 4;
        while (true) {
            const pixels = gpa.alloc(raster.Pixel, @as(usize, self.w) * self.h) catch return;
            const bytes = std.mem.sliceAsBytes(pixels);
            var got: usize = 0;
            while (got < size) {
                const n = std.posix.read(fd, bytes[got..]) catch 0;
                if (n == 0) break;
                got += n;
            }
            if (got < size) {
                gpa.free(pixels);
                return;
            }
            // Opaque: whatever FFmpeg left in alpha.
            for (pixels) |*px| px.* |= 0xFF000000;
            p.shared.mutex.lockUncancelable(p.io);
            if (p.shared.frame) |*old| old.deinit(gpa);
            p.shared.frame = .{ .pixels = pixels, .width = self.w, .height = self.h };
            p.shared.frame_run = self.run;
            const wake = !p.shared.woken;
            p.shared.woken = true;
            p.shared.mutex.unlock(p.io);
            if (wake) _ = std.c.write(p.wake, "v", 1);
        }
    }

    fn ended(self: *Job) void {
        const p = self.player;
        p.shared.mutex.lockUncancelable(p.io);
        p.shared.ended_run = self.run;
        if (p.shared.pid_run == self.run) p.shared.pid = 0;
        p.shared.mutex.unlock(p.io);
        _ = std.c.write(p.wake, "e", 1);
    }
};

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
