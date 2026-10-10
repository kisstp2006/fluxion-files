// SPDX-License-Identifier: BSD-2-Clause

//! Compressed folders - a ZIP, a 7z, a tar - read and made with libarchive,
//! which is looked for when one is needed: not installed, an archive is a
//! file like any other, and Files starts all the same. As Windows 11 opens
//! them, so does Files: ZIP, 7z, RAR, and tar however it was compressed.
//!
//! Reading lists what is inside and takes it out; making writes a ZIP of
//! what was chosen, folders and all. Whatever an archive says its files are
//! called, nothing is ever written outside the folder it is taken out into:
//! a name that starts at the root, or climbs out with `..`, is left out, as
//! is a link that points out of it.

const std = @import("std");

const log = std.log.scoped(.archive);

/// libarchive's results.
const ok = 0;
const eof = 1;
const warn = -20;
const fatal = -30;

/// The kinds of file an entry is, as `archive_entry_filetype` says.
const if_mask = 0o170000;
const if_dir = 0o040000;
const if_reg = 0o100000;
const if_lnk = 0o120000;

const Handle = opaque {};
const EntryHandle = opaque {};

/// What of libarchive this uses, looked up once it is open.
const Lib = struct {
    read_new: *const fn () callconv(.c) ?*Handle,
    read_support_filter_all: *const fn (*Handle) callconv(.c) c_int,
    read_support_format_all: *const fn (*Handle) callconv(.c) c_int,
    read_open_filename: *const fn (*Handle, [*:0]const u8, usize) callconv(.c) c_int,
    read_next_header: *const fn (*Handle, *?*EntryHandle) callconv(.c) c_int,
    read_data: *const fn (*Handle, [*]u8, usize) callconv(.c) isize,
    read_data_skip: *const fn (*Handle) callconv(.c) c_int,
    read_free: *const fn (*Handle) callconv(.c) c_int,
    error_string: *const fn (*Handle) callconv(.c) ?[*:0]const u8,
    entry_pathname: *const fn (*EntryHandle) callconv(.c) ?[*:0]const u8,
    entry_pathname_utf8: *const fn (*EntryHandle) callconv(.c) ?[*:0]const u8,
    entry_size: *const fn (*EntryHandle) callconv(.c) i64,
    entry_mtime: *const fn (*EntryHandle) callconv(.c) i64,
    entry_filetype: *const fn (*EntryHandle) callconv(.c) c_uint,
    entry_perm: *const fn (*EntryHandle) callconv(.c) c_uint,
    entry_symlink: *const fn (*EntryHandle) callconv(.c) ?[*:0]const u8,
    entry_is_encrypted: *const fn (*EntryHandle) callconv(.c) c_int,
    write_new: *const fn () callconv(.c) ?*Handle,
    write_set_format_zip: *const fn (*Handle) callconv(.c) c_int,
    write_set_format_7zip: *const fn (*Handle) callconv(.c) c_int,
    write_set_format_pax_restricted: *const fn (*Handle) callconv(.c) c_int,
    write_add_filter_gzip: *const fn (*Handle) callconv(.c) c_int,
    write_set_options: *const fn (*Handle, [*:0]const u8) callconv(.c) c_int,
    write_open_filename: *const fn (*Handle, [*:0]const u8) callconv(.c) c_int,
    write_header: *const fn (*Handle, *EntryHandle) callconv(.c) c_int,
    write_data: *const fn (*Handle, [*]const u8, usize) callconv(.c) isize,
    write_close: *const fn (*Handle) callconv(.c) c_int,
    write_free: *const fn (*Handle) callconv(.c) c_int,
    entry_new: *const fn () callconv(.c) ?*EntryHandle,
    entry_free: *const fn (*EntryHandle) callconv(.c) void,
    entry_set_pathname_utf8: *const fn (*EntryHandle, [*:0]const u8) callconv(.c) void,
    entry_set_size: *const fn (*EntryHandle, i64) callconv(.c) void,
    entry_set_filetype: *const fn (*EntryHandle, c_uint) callconv(.c) void,
    entry_set_perm: *const fn (*EntryHandle, c_uint) callconv(.c) void,
    entry_set_mtime: *const fn (*EntryHandle, i64, c_long) callconv(.c) void,

    fn open() ?Lib {
        var dl = std.DynLib.open("libarchive.so.13") catch std.DynLib.open("libarchive.so") catch return null;
        var found: Lib = undefined;
        inline for (@typeInfo(Lib).@"struct".fields) |f| {
            @field(found, f.name) = dl.lookup(f.type, "archive_" ++ f.name) orelse {
                log.warn("libarchive has no archive_{s}", .{f.name});
                return null;
            };
        }
        // Kept open: what it gives out is used long after.
        return found;
    }
};

var lib_once: ?Lib = null;
var lib_tried = false;
var lib_mutex: std.atomic.Mutex = .unlocked;

fn library() ?*const Lib {
    while (!lib_mutex.tryLock()) std.atomic.spinLoopHint();
    defer lib_mutex.unlock();
    if (!lib_tried) {
        lib_tried = true;
        lib_once = Lib.open();
        if (lib_once == null) log.info("no libarchive: compressed folders are files", .{});
    }
    return if (lib_once) |*l| l else null;
}

/// Whether libarchive is there to open one.
pub fn available() bool {
    return library() != null;
}

/// The endings of the archives this opens as folders.
const extensions = [_][]const u8{ ".zip", ".7z", ".rar", ".tar", ".tar.gz", ".tgz", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tbz", ".tar.zst", ".tzst", ".tar.lz", ".tar.lzma", ".cab", ".cpio", ".xar" };

/// A path through a compressed folder - "/home/k/a.zip/docs" - split
/// where the archive is: the archive, and the folder inside it ("docs",
/// or "" for its top). Null for a path that goes through none.
pub fn split(io: std.Io, path: []const u8) ?struct { archive: []const u8, inner: []const u8 } {
    var end: usize = 0;
    while (end < path.len) {
        end = std.mem.indexOfScalarPos(u8, path, end + 1, '/') orelse path.len;
        const prefix = path[0..end];
        if (!named(prefix)) continue;
        const stat = std.Io.Dir.cwd().statFile(io, prefix, .{}) catch return null;
        if (stat.kind != .file) continue;
        const inner = if (end < path.len) std.mem.trim(u8, path[end..], "/") else "";
        return .{ .archive = prefix, .inner = inner };
    }
    return null;
}

/// Whether a file of this name is a compressed folder.
pub fn named(name: []const u8) bool {
    for (extensions) |e| {
        if (name.len > e.len and std.ascii.eqlIgnoreCase(name[name.len - e.len ..], e)) return true;
    }
    return false;
}

/// "ZIP", "7z", "TAR": what to call an archive in its type's column.
pub fn kindName(name: []const u8) []const u8 {
    const lower_end = struct {
        fn f(n: []const u8, e: []const u8) bool {
            return n.len > e.len and std.ascii.eqlIgnoreCase(n[n.len - e.len ..], e);
        }
    }.f;
    if (lower_end(name, ".zip")) return "Compressed (zipped) Folder";
    if (lower_end(name, ".7z")) return "7-Zip Archive";
    if (lower_end(name, ".rar")) return "RAR Archive";
    return "Compressed Archive";
}

pub const Kind = enum { file, folder, link };

pub const Entry = struct {
    /// Inside the archive, without a slash at either end: "docs/a.txt".
    path: []const u8,
    kind: Kind,
    size: u64 = 0,
    /// Seconds since the epoch.
    mtime: i64 = 0,
    encrypted: bool = false,
};

/// Everything in the archive at `path`, into `out` - its names in `arena`.
/// Folders an archive does not list on their own but holds files in are
/// listed too, as Windows shows them.
pub fn list(arena: std.mem.Allocator, path: []const u8, out: *std.ArrayList(Entry)) !void {
    const l = library() orelse return error.NoLibarchive;
    const a = l.read_new() orelse return error.OutOfMemory;
    defer _ = l.read_free(a);
    _ = l.read_support_filter_all(a);
    _ = l.read_support_format_all(a);
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pz = try std.fmt.bufPrintZ(&z, "{s}", .{path});
    if (l.read_open_filename(a, pz.ptr, 64 << 10) != ok) {
        log.warn("{s}: {s}", .{ path, if (l.error_string(a)) |e| std.mem.span(e) else "cannot open" });
        return error.NotAnArchive;
    }
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    while (true) {
        var entry: ?*EntryHandle = null;
        const r = l.read_next_header(a, &entry);
        if (r == eof) break;
        if (r < warn or entry == null) return error.Damaged;
        const e = entry.?;
        const raw = l.entry_pathname_utf8(e) orelse l.entry_pathname(e) orelse continue;
        const name = clean(std.mem.span(raw)) orelse continue;
        const kind: Kind = switch (l.entry_filetype(e) & if_mask) {
            if_dir => .folder,
            if_lnk => .link,
            else => .file,
        };
        try addParents(arena, out, &seen, name);
        if (seen.contains(name)) continue;
        const owned = try arena.dupe(u8, name);
        try seen.put(arena, owned, {});
        try out.append(arena, .{
            .path = owned,
            .kind = kind,
            .size = @intCast(@max(0, l.entry_size(e))),
            .mtime = l.entry_mtime(e),
            .encrypted = l.entry_is_encrypted(e) > 0,
        });
        _ = l.read_data_skip(a);
    }
}

/// The folders `name` is in, each listed once.
fn addParents(arena: std.mem.Allocator, out: *std.ArrayList(Entry), seen: *std.StringHashMapUnmanaged(void), name: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, name, i, '/')) |slash| : (i = slash + 1) {
        const parent = name[0..slash];
        if (seen.contains(parent)) continue;
        const owned = try arena.dupe(u8, parent);
        try seen.put(arena, owned, {});
        try out.append(arena, .{ .path = owned, .kind = .folder });
    }
}

/// A name inside an archive as it may be used: without "./" in front or a
/// slash at either end - or null for one that starts at the root, or climbs
/// out with "..".
pub fn clean(name: []const u8) ?[]const u8 {
    var n = name;
    while (std.mem.startsWith(u8, n, "./")) n = n[2..];
    n = std.mem.trimEnd(u8, n, "/");
    if (n.len == 0 or n[0] == '/') return null;
    var parts = std.mem.splitScalar(u8, n, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return null;
    }
    return n;
}

/// How a long job says how far along it is, and hears whether to go on.
pub const Progress = struct {
    context: *anyopaque,
    /// `bytes` more done, of the file `name` now; false to stop.
    step: *const fn (context: *anyopaque, bytes: u64, name: []const u8) bool,

    fn tell(self: ?Progress, bytes: u64, name: []const u8) !void {
        const p = self orelse return;
        if (!p.step(p.context, bytes, name)) return error.Canceled;
    }
};

/// Take out of the archive at `path`, into the folder `into` - everything,
/// or what `only` names and what is inside it. Made as it goes, the
/// folders an entry is in. The names it was given, kept.
pub fn extract(io: std.Io, path: []const u8, into: []const u8, only: ?[]const []const u8, progress: ?Progress) !void {
    const l = library() orelse return error.NoLibarchive;
    const a = l.read_new() orelse return error.OutOfMemory;
    defer _ = l.read_free(a);
    _ = l.read_support_filter_all(a);
    _ = l.read_support_format_all(a);
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pz = try std.fmt.bufPrintZ(&z, "{s}", .{path});
    if (l.read_open_filename(a, pz.ptr, 64 << 10) != ok) return error.NotAnArchive;
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, into) catch {};
    var buffer: [64 << 10]u8 = undefined;
    while (true) {
        var entry: ?*EntryHandle = null;
        const r = l.read_next_header(a, &entry);
        if (r == eof) break;
        if (r < warn or entry == null) return error.Damaged;
        const e = entry.?;
        const raw = l.entry_pathname_utf8(e) orelse l.entry_pathname(e) orelse continue;
        const name = clean(std.mem.span(raw)) orelse continue;
        if (only) |wanted| if (!chosen(name, wanted)) {
            _ = l.read_data_skip(a);
            continue;
        };
        if (l.entry_is_encrypted(e) > 0) return error.Encrypted;
        var out_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const out = try std.fmt.bufPrint(&out_buffer, "{s}/{s}", .{ if (std.mem.eql(u8, into, "/")) "" else into, name });
        if (std.fs.path.dirname(out)) |dir| try cwd.createDirPath(io, dir);
        const mode = l.entry_perm(e) & 0o777;
        switch (l.entry_filetype(e) & if_mask) {
            if_dir => try cwd.createDirPath(io, out),
            if_lnk => {
                const target = std.mem.span(l.entry_symlink(e) orelse continue);
                // A link out of the folder taken out into is left out.
                if (target.len == 0 or target[0] == '/' or std.mem.indexOf(u8, target, "..") != null) continue;
                cwd.symLink(io, target, out, .{}) catch |err| if (err != error.PathAlreadyExists) return err;
            },
            else => {
                var file = try cwd.createFile(io, out, .{ .permissions = .fromMode(if (mode == 0) 0o644 else mode | 0o600) });
                defer file.close(io);
                var w = file.writer(io, &.{});
                while (true) {
                    const n = l.read_data(a, &buffer, buffer.len);
                    if (n < 0) return error.Damaged;
                    if (n == 0) break;
                    const got: usize = @intCast(n);
                    try w.interface.writeAll(buffer[0..got]);
                    try Progress.tell(progress, got, name);
                }
            },
        }
        try Progress.tell(progress, 0, name);
    }
}

/// Whether `name` is one of `wanted`, or inside one.
fn chosen(name: []const u8, wanted: []const []const u8) bool {
    for (wanted) |w| {
        if (std.mem.eql(u8, name, w)) return true;
        if (name.len > w.len and std.mem.startsWith(u8, name, w) and name[w.len] == '/') return true;
    }
    return false;
}

/// What Windows 11's "Compress to" makes.
pub const Format = enum {
    zip,
    seven_zip,
    tar_gz,

    pub fn extension(self: Format) []const u8 {
        return switch (self) {
            .zip => ".zip",
            .seven_zip => ".7z",
            .tar_gz => ".tar.gz",
        };
    }

    /// What a file's name says it is, to be made: a ZIP unless it says.
    pub fn of(name: []const u8) Format {
        const ends = struct {
            fn f(n: []const u8, e: []const u8) bool {
                return n.len > e.len and std.ascii.eqlIgnoreCase(n[n.len - e.len ..], e);
            }
        }.f;
        if (ends(name, ".7z")) return .seven_zip;
        if (ends(name, ".tar.gz") or ends(name, ".tgz")) return .tar_gz;
        return .zip;
    }
};

/// A ZIP at `path` of `sources` - files and folders, each by its full path
/// - named inside it as they are named where they are: what Windows' "Send
/// to Compressed (zipped) folder" makes.
pub fn createZip(io: std.Io, path: []const u8, sources: []const []const u8, progress: ?Progress) !void {
    return create(io, path, sources, .zip, progress);
}

/// The same, as `format` has it: a ZIP, a 7z, a gzipped tar.
pub fn create(io: std.Io, path: []const u8, sources: []const []const u8, format: Format, progress: ?Progress) !void {
    const l = library() orelse return error.NoLibarchive;
    const a = l.write_new() orelse return error.OutOfMemory;
    defer _ = l.write_free(a);
    switch (format) {
        .zip => {
            if (l.write_set_format_zip(a) != ok) return error.NoZip;
            // Names in UTF-8, as Windows' own ZIPs have them since Windows 10.
            _ = l.write_set_options(a, "zip:hdrcharset=UTF-8");
        },
        .seven_zip => if (l.write_set_format_7zip(a) != ok) return error.No7z,
        .tar_gz => {
            if (l.write_set_format_pax_restricted(a) != ok) return error.NoTar;
            if (l.write_add_filter_gzip(a) != ok) return error.NoGzip;
        },
    }
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const pz = try std.fmt.bufPrintZ(&z, "{s}", .{path});
    if (l.write_open_filename(a, pz.ptr) != ok) return error.CannotWrite;
    errdefer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    for (sources) |source| {
        const base = std.fs.path.dirname(source) orelse "/";
        try addTree(io, l, a, source, base.len + @as(usize, if (std.mem.eql(u8, base, "/")) 0 else 1), progress, 0);
    }
    if (l.write_close(a) != ok) return error.CannotWrite;
}

fn addTree(io: std.Io, l: *const Lib, a: *Handle, full: []const u8, skip: usize, progress: ?Progress, depth: u8) !void {
    if (depth > 64) return error.TooDeep;
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, full, .{ .follow_symlinks = false });
    const name = full[skip..];
    const e = l.entry_new() orelse return error.OutOfMemory;
    defer l.entry_free(e);
    var nz: [std.fs.max_path_bytes + 1]u8 = undefined;
    const name_z = try std.fmt.bufPrintZ(&nz, "{s}{s}", .{ name, if (stat.kind == .directory) "/" else "" });
    l.entry_set_pathname_utf8(e, name_z.ptr);
    l.entry_set_mtime(e, @intCast(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s)), 0);
    l.entry_set_perm(e, @intCast(stat.permissions.toMode() & 0o777));
    switch (stat.kind) {
        .directory => {
            l.entry_set_filetype(e, if_dir);
            l.entry_set_size(e, 0);
            if (l.write_header(a, e) < warn) return error.CannotWrite;
            var dir = try cwd.openDir(io, full, .{ .iterate = true });
            defer dir.close(io);
            var it = dir.iterate();
            while (try it.next(io)) |child| {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const child_path = try std.fmt.bufPrint(&buffer, "{s}/{s}", .{ full, child.name });
                try addTree(io, l, a, child_path, skip, progress, depth + 1);
            }
        },
        .file => {
            l.entry_set_filetype(e, if_reg);
            l.entry_set_size(e, @intCast(stat.size));
            if (l.write_header(a, e) < warn) return error.CannotWrite;
            var file = try cwd.openFile(io, full, .{});
            defer file.close(io);
            var buffer: [64 << 10]u8 = undefined;
            var r = file.reader(io, &.{});
            while (true) {
                const n = r.interface.readSliceShort(&buffer) catch return error.CannotRead;
                if (n == 0) break;
                if (l.write_data(a, &buffer, n) < 0) return error.CannotWrite;
                try Progress.tell(progress, n, name);
            }
        },
        // A link, a device: not a file of its own in a ZIP.
        else => {},
    }
}

test "names that would climb out of the folder are left out" {
    try std.testing.expectEqualStrings("a/b.txt", clean("./a/b.txt/").?);
    try std.testing.expect(clean("/etc/passwd") == null);
    try std.testing.expect(clean("a/../../x") == null);
    try std.testing.expect(clean("") == null);
    try std.testing.expect(named("photos.ZIP"));
    try std.testing.expect(named("backup.tar.gz"));
    try std.testing.expect(!named("zip"));
    try std.testing.expect(chosen("docs/a.txt", &.{"docs"}));
    try std.testing.expect(!chosen("docs2/a.txt", &.{"docs"}));
}

test "a folder zipped is read back, and taken out whole" {
    if (!available()) return error.SkipZigTest;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/inner/hello.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/top.txt", .data = "top" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var a_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var b_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var c_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const src = try std.fmt.bufPrint(&a_buffer, "{s}/src", .{root});
    const zip = try std.fmt.bufPrint(&b_buffer, "{s}/src.zip", .{root});
    try createZip(io, zip, &.{src}, null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var entries: std.ArrayList(Entry) = .empty;
    try list(arena.allocator(), zip, &entries);
    var found = false;
    for (entries.items) |e| if (std.mem.eql(u8, e.path, "src/inner/hello.txt")) {
        found = true;
        try std.testing.expectEqual(@as(u64, 5), e.size);
    };
    try std.testing.expect(found);
    const out = try std.fmt.bufPrint(&c_buffer, "{s}/out", .{root});
    try extract(io, zip, out, null, null);
    var read_buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", try tmp.dir.readFile(io, "out/src/inner/hello.txt", &read_buffer));
}

test "a path through a compressed folder is split where it is" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "photos.zip", .data = "PK" });
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(io, &root_buffer)];
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const inside = try std.fmt.bufPrint(&buffer, "{s}/photos.zip/2024/june", .{root});
    const parts = split(io, inside).?;
    try std.testing.expect(std.mem.endsWith(u8, parts.archive, "/photos.zip"));
    try std.testing.expectEqualStrings("2024/june", parts.inner);
    try std.testing.expect(split(io, root) == null);
    try std.testing.expectEqual(Format.seven_zip, Format.of("a.7z"));
}
