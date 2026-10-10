// SPDX-License-Identifier: BSD-2-Clause

//! Compressed folders, as File Explorer has them: a ZIP - or a 7z, a RAR,
//! a tar - opened is a folder, its folders gone into, its files opened -
//! taken out to a folder of the session's first, as Windows takes them
//! out to a temporary one - copied and dragged out of; and the "Extract
//! Compressed (Zipped) Folders" wizard that takes it all out, where it is
//! told. Windows 10 has "Compressed Folder Tools" over its ribbon for one,
//! Windows 11 "Extract all" in its command bar; and Windows 11 compresses
//! to a ZIP, a 7z or a tar.

const std = @import("std");

const ui = @import("fluxion_ui");
const widgets = @import("fluxion_widgets");
const Kit = widgets.Kit;

const Files = @import("Files.zig");
const Tab = @import("Tab.zig");
const Ops = @import("Ops.zig");
const Archive = @import("Archive.zig");
const apps_mod = @import("apps.zig");
const icons = @import("icons.zig");
const menus = @import("menus.zig");

/// "Extract Compressed (Zipped) Folders", open.
pub const Wizard = struct {
    archive_buffer: [std.fs.max_path_bytes]u8 = undefined,
    archive_len: usize = 0,
    /// Show the folder taken out into once it is done.
    show: bool = true,
    /// Browse's places, open.
    browsing: bool = false,
    draws: u8 = 0,

    pub fn archive(self: *const Wizard) []const u8 {
        return self.archive_buffer[0..self.archive_len];
    }
};

/// The archive chosen - a compressed folder in the folder shown - or the
/// one the folder shown is in.
pub fn chosenArchive(self: *Files, buffer: []u8) ?[]const u8 {
    const t = self.tab();
    if (t.folder) |f| if (f.archive) |a| return std.fmt.bufPrint(buffer, "{s}", .{a}) catch null;
    if (t.selectedCount() != 1) return null;
    const i = t.current() orelse return null;
    const e = t.entry(i);
    if (e.isFolder() or !Archive.named(e.name) or !Archive.available()) return null;
    const dir = t.dirOf(e) orelse return null;
    return Ops.join(buffer, dir, e.name) catch null;
}

/// Where the files of an archive are taken out to, to be opened: a folder
/// of the session's own, one for each archive.
fn scratchFor(archive: []const u8, buffer: []u8) ?[]const u8 {
    const runtime = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
    const hash = std.hash.Wyhash.hash(0, archive);
    return std.fmt.bufPrint(buffer, "{s}/fluxion-files/{x}", .{ runtime, hash }) catch null;
}

/// A file inside a compressed folder opened: taken out first, then opened
/// by the app that opens its kind.
pub fn openInside(self: *Files, i: usize) void {
    const t = self.tab();
    const f = t.folder orelse return;
    const archive = f.archive orelse return;
    const e = t.entry(i);
    var inner_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const inner = if (f.inner.len == 0) e.name else std.fmt.bufPrint(&inner_buffer, "{s}/{s}", .{ f.inner, e.name }) catch return;
    var scratch_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scratch = scratchFor(archive, &scratch_buffer) orelse return;
    Archive.extract(self.io, archive, scratch, &.{inner}, null) catch |err| return self.notify("The file could not be extracted", err);
    var out_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const out = Ops.join(&out_buffer, scratch, inner) catch return;
    self.openFile(out, e.mime);
}

/// What is chosen inside a compressed folder, taken out to the session's
/// folder for it - for a drag out of it. The paths it was taken out to.
pub fn extractChosen(self: *Files, out: *std.ArrayList([]u8)) bool {
    const t = self.tab();
    const f = t.folder orelse return false;
    const archive = f.archive orelse return false;
    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| self.gpa.free(n);
        names.deinit(self.gpa);
    }
    for (t.selected.items, 0..) |s, i| {
        if (!s) continue;
        const e = t.entry(i);
        const inner = if (f.inner.len == 0) self.gpa.dupe(u8, e.name) catch continue else std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ f.inner, e.name }) catch continue;
        names.append(self.gpa, inner) catch self.gpa.free(inner);
    }
    if (names.items.len == 0) return false;
    var scratch_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const scratch = scratchFor(archive, &scratch_buffer) orelse return false;
    Archive.extract(self.io, archive, scratch, names.items, null) catch |err| {
        self.notify("The files could not be extracted", err);
        return false;
    };
    for (names.items) |n| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = Ops.join(&buffer, scratch, n) catch continue;
        out.append(self.gpa, self.gpa.dupe(u8, full) catch continue) catch {};
    }
    return true;
}

/// Pasted, what was copied out of a compressed folder: taken out into
/// `dest`. Whether the clipboard was that.
pub fn pasteFromArchive(self: *Files, dest: []const u8) bool {
    if (self.clipboard.items.len == 0) return false;
    const first = Archive.split(self.io, self.clipboard.items[0]) orelse return false;
    var archive_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const archive = std.fmt.bufPrint(&archive_buffer, "{s}", .{first.archive}) catch return false;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(self.gpa);
    for (self.clipboard.items) |p| {
        if (!std.mem.startsWith(u8, p, archive) or p.len <= archive.len + 1) continue;
        names.append(self.gpa, p[archive.len + 1 ..]) catch {};
    }
    self.jobs.start(.extract, &.{archive}, dest, names.items);
    return true;
}

// -------------------------------------------------------------------------
// Compress to
// -------------------------------------------------------------------------

/// What is chosen, into a new compressed folder beside it: as Windows 11
/// names it, after the first.
pub fn compressTo(self: *Files, format: Archive.Format) void {
    const t = self.tab();
    const dir = t.path() orelse return;
    if (!t.writable()) return;
    const first = t.current() orelse return;
    const e = t.entry(first);
    const stem = if (e.isFolder()) e.name else std.fs.path.stem(e.name);
    var wanted_buffer: [512]u8 = undefined;
    const wanted = std.fmt.bufPrint(&wanted_buffer, "{s}{s}", .{ if (stem.len > 0) stem else e.name, format.extension() }) catch return;
    var name_buffer: [512]u8 = undefined;
    const name = Ops.freeName(self.io, dir, wanted, false, false, &name_buffer);
    var out_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const out = Ops.join(&out_buffer, dir, name) catch return;
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| self.gpa.free(p);
        paths.deinit(self.gpa);
    }
    for (t.selected.items, 0..) |s, i| {
        if (!s) continue;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const full = Ops.join(&buffer, dir, t.entry(i).name) catch continue;
        paths.append(self.gpa, self.gpa.dupe(u8, full) catch continue) catch {};
    }
    if (paths.items.len == 0) return;
    self.jobs.start(.compress, paths.items, out, null);
}

/// Windows 11's "Compress to" menu: a ZIP, a 7z, a tar.
pub fn compressMenu(self: *Files, kit: *Kit) void {
    const formats = [_]struct { name: []const u8, format: Archive.Format }{
        .{ .name = "ZIP File", .format = .zip },
        .{ .name = "7z File", .format = .seven_zip },
        .{ .name = "TAR File", .format = .tar_gz },
    };
    for (formats) |f| if (menus.row(self, kit, kit.print("context/compress/{t}", .{f.format}), f.name, .{ .themed = "package-x-generic" })) {
        self.context_open = null;
        self.context_sub = .none;
        return compressTo(self, f.format);
    };
}

// -------------------------------------------------------------------------
// Extract Compressed (Zipped) Folders
// -------------------------------------------------------------------------

/// The wizard, for `archive`: where to take it out to - a folder named for
/// it, beside it - in its field to change.
pub fn startWizard(self: *Files, archive: []const u8) void {
    self.menu = .none;
    self.context_open = null;
    var w: Wizard = .{};
    w.archive_len = @min(archive.len, w.archive_buffer.len);
    @memcpy(w.archive_buffer[0..w.archive_len], archive[0..w.archive_len]);
    self.wizard = w;
    self.window.redraw();
}

/// Beside the archive, a folder of its name: "photos.zip" into "photos".
fn defaultDest(archive: []const u8, buffer: []u8) []const u8 {
    var name = std.fs.path.basename(archive);
    for ([_][]const u8{ ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst" }) |e| {
        if (name.len > e.len and std.ascii.eqlIgnoreCase(name[name.len - e.len ..], e)) {
            name = name[0 .. name.len - e.len];
            break;
        }
    } else name = std.fs.path.stem(name);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ std.fs.path.dirname(archive) orelse "/", name }) catch "";
}

/// Everything in `archive` into `into`, the folder shown once it is done
/// if `show`.
pub fn extractAll(self: *Files, archive: []const u8, into: []const u8, show: bool) void {
    self.jobs.start(.extract, &.{archive}, into, null);
    if (show) {
        self.show_after_len = @min(into.len, self.show_after_buffer.len);
        @memcpy(self.show_after_buffer[0..self.show_after_len], into[0..self.show_after_len]);
    }
}

pub fn wizard(self: *Files, kit: *Kit) void {
    const w = &(self.wizard orelse return);
    const u = kit.ui;
    const p = &kit.theme.palette;
    const ten = self.ten();
    u.open(.{ .id = "extract/smoke", .width = .grow, .height = .grow, .align_x = .center, .align_y = .center, .background_color = p.smoke.withAlpha(0.2), .floating = .{ .attach = .root, .z_index = 94 } });
    defer u.close();
    u.open(.{
        .id = "extract",
        .width = .fixed(560),
        .direction = .top_to_bottom,
        .corner_radius = .all(if (ten) 0 else 8),
        .background_color = p.solid_base,
        .border = .{ .color = if (ten) widgets.argb(0xFF1979CA) else p.surface_stroke_flyout, .width = .all(1) },
        .shadow = kit.elevation(.window),
        .clip = .both,
    });
    defer u.close();
    // The wizard's top: back, its icon, its name - and the close button.
    {
        u.open(.{ .width = .grow, .height = .fixed(40), .padding = .trbl(0, 0, 0, 10), .gap = 10, .align_y = .center });
        defer u.close();
        kit.icon(.arrow_left, 16, p.text_disabled, .regular);
        icons.themed(self, kit, "package-x-generic", 16);
        var style = kit.style(.body, p.text_primary);
        style.wrap = .none;
        u.open(.{ .width = .grow });
        u.text("Extract Compressed (Zipped) Folders", style);
        u.close();
        const close_id = "extract/close";
        u.open(.{ .id = close_id, .width = .fixed(46), .height = .grow, .align_x = .center, .align_y = .center, .background_color = if (u.isPointerOver(close_id)) p.close_hover else .transparent });
        kit.icon(.dismiss, 10, if (u.isPointerOver(close_id)) widgets.argb(0xFFFFFFFF) else p.text_primary, .regular);
        if (u.justReleased()) self.wizard = null;
        u.close();
    }
    if (self.wizard == null) return;
    {
        u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .trbl(16, 40, 28, 40), .gap = 12 });
        defer u.close();
        // Windows' wizard heading: a dark blue in Windows 10.
        var heading = kit.style(.body_large, if (ten) (if (p.mode == .dark) widgets.argb(0xFF6CB4F2) else widgets.argb(0xFF1E3287)) else p.text_primary);
        heading.wrap = .words;
        u.text("Select a Destination and Extract Files", heading);
        u.empty(.{ .height = .fixed(8) });
        kit.label("Files will be extracted to this folder:", .caption, p.text_primary);
        {
            u.open(.{ .width = .grow, .gap = 8, .align_y = .center });
            defer u.close();
            kit.textField("extract/field", .{ .width = .grow });
            // Its text set once the field is there: where it goes by
            // default, beside the archive.
            if (w.draws < 2) {
                if (w.draws == 0) u.setFocus("extract/field");
                if (w.draws == 1) {
                    var dest_buffer: [std.fs.max_path_bytes]u8 = undefined;
                    u.setTextValue("extract/field", defaultDest(w.archive(), &dest_buffer));
                    _ = u.textAction(.moveTo(.end, false));
                }
                w.draws += 1;
                self.window.redraw();
            }
            if (kit.button("extract/browse", "Browse...", .{ .width = .fixed(96) })) w.browsing = !w.browsing;
        }
        if (w.browsing) browse(self, kit, w);
        _ = kit.checkbox("extract/show", &w.show, "Show extracted files when complete", .{});
    }
    u.open(.{ .width = .grow, .padding = .all(14), .gap = 8, .align_x = .right, .background_color = p.solid_secondary, .border = .{ .color = p.divider, .width = .{ .top = 1 } } });
    defer u.close();
    if (kit.button("extract/go", "Extract", .{ .kind = .accent, .width = .fixed(96) })) {
        const typed = std.mem.trim(u8, u.textValueOf("extract/field") orelse "", " \t");
        if (typed.len > 0) {
            var into_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const into = std.fmt.bufPrint(&into_buffer, "{s}", .{typed}) catch return;
            extractAll(self, w.archive(), into, w.show);
            self.wizard = null;
            return;
        }
    }
    if (kit.button("extract/cancel", "Cancel", .{ .width = .fixed(96) })) self.wizard = null;
}

/// Browse...: the person's folders, to take it out into - a folder named
/// for the archive in the one chosen.
fn browse(self: *Files, kit: *Kit, w: *Wizard) void {
    const u = kit.ui;
    const p = &kit.theme.palette;
    u.open(.{ .width = .grow, .direction = .top_to_bottom, .padding = .all(4), .border = .{ .color = p.divider, .width = .all(1) }, .corner_radius = .all(if (self.ten()) 0 else 4) });
    defer u.close();
    var stem_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const stem = std.fs.path.basename(defaultDest(w.archive(), &stem_buffer));
    for (self.places.user.items, 0..) |f, k| {
        const id = kit.print("extract/place/{d}", .{k});
        u.open(.{ .id = id, .width = .grow, .padding = .xy(8, 4), .gap = 8, .align_y = .center, .background_color = if (u.isPointerOver(id)) p.subtle_secondary else .transparent });
        icons.themed(self, kit, icons.special(f.special), 16);
        kit.label(f.name, .caption, p.text_primary);
        if (u.justReleased()) {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            u.setTextValue("extract/field", Ops.join(&buffer, f.path, stem) catch f.path);
            w.browsing = false;
        }
        u.close();
    }
}
