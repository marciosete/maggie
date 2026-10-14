//! A pty tap observes everything a pty prints, for mirroring a terminal
//! elsewhere (Maggie's mobile companion streams it to a device).
//!
//! The events form one ordered stream: a snapshot, then output and resizes
//! that apply on top of it. A mirror that restores the snapshot and then
//! applies each later event in order holds the same terminal as the source.
//!
//! The owner calls every function with the terminal locked, so each event is
//! delivered with the terminal locked too, on whichever thread made the call.
//! The callback must copy what it needs and return.
const PtyTap = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const terminalpkg = @import("../terminal/main.zig");
const Terminal = terminalpkg.Terminal;
const Screen = terminalpkg.Screen;
const formatter = terminalpkg.formatter;

const log = std.log.scoped(.pty_tap);

/// The most rows of scrollback a snapshot carries, above the screen.
pub const history_rows = 2000;

userdata: ?*anyopaque,
callback: *const fn (userdata: ?*anyopaque, event: Event) void,

/// True while a requested snapshot waits for the stream parser to reach
/// ground. Nothing else is delivered meanwhile.
snapshot_pending: bool = false,

pub const Event = union(enum) {
    /// The terminal as VT sequences (see `screenVt`), taken with the stream
    /// parser at ground, so the output after it resumes it exactly. Written
    /// into a fresh terminal of `cols` by `rows`, it reproduces this one.
    snapshot: Snapshot,

    /// Bytes the pty printed, before the terminal processes them.
    output: []const u8,

    /// The terminal grid was resized.
    resize: struct { cols: u16, rows: u16 },
};

pub const Snapshot = struct {
    vt: []const u8,
    cols: u16,
    rows: u16,
};

/// Deliver a snapshot now if `stream` is at ground, or else once the output
/// brings it there. A newly installed tap starts with this.
pub fn requestSnapshot(
    self: *PtyTap,
    alloc: Allocator,
    t: *const Terminal,
    stream: anytype,
) void {
    if (stream.ground()) {
        self.emitSnapshot(alloc, t);
    } else {
        self.snapshot_pending = true;
    }
}

/// Deliver one chunk of pty output before `stream` processes it. Returns the
/// part of `buf` the caller still has to feed to `stream`: the bytes that
/// bring a pending snapshot's stream to ground are fed here, since the
/// snapshot that follows them already contains their effect.
pub fn output(
    self: *PtyTap,
    alloc: Allocator,
    t: *const Terminal,
    stream: anytype,
    buf: []const u8,
) []const u8 {
    var rest = buf;
    if (self.snapshot_pending) {
        const consumed = stream.nextSliceUntilGround(rest) orelse rest.len;
        rest = rest[consumed..];
        if (!stream.ground()) return rest;
        self.emitSnapshot(alloc, t);
    }

    if (rest.len > 0) self.callback(self.userdata, .{ .output = rest });
    return rest;
}

/// Deliver a grid resize, in order with the output around it. A pending
/// snapshot will carry the new size instead.
pub fn resized(self: *PtyTap, cols: u16, rows: u16) void {
    if (self.snapshot_pending) return;
    self.callback(self.userdata, .{ .resize = .{ .cols = cols, .rows = rows } });
}

fn emitSnapshot(self: *PtyTap, alloc: Allocator, t: *const Terminal) void {
    self.snapshot_pending = false;

    const vt = screenVt(alloc, t, history_rows) catch |err| {
        log.warn("error writing snapshot err={}", .{err});
        return;
    };
    defer alloc.free(vt);

    self.callback(self.userdata, .{ .snapshot = .{
        .vt = vt,
        .cols = t.cols,
        .rows = t.rows,
    } });
}

/// The terminal as VT sequences: written into a fresh terminal of the same
/// size, they reproduce its screen, styles, colors, modes, cursor and the
/// last `max_history` rows of scrollback, and the alternate screen if that
/// is the one showing, with the primary screen kept behind it.
///
/// The parts come in an order that makes the replay line up:
///
///   1. Scrollback rows, then enough line feeds to scroll every one of them
///      off the screen, so the screen starts empty with them in scrollback
///      however many blank rows the formatter trimmed.
///   2. With the alternate screen showing: the primary screen's rows from
///      the top, and its cursor, which entering the alternate screen saves.
///   3. The terminal itself: default colors, palette, modes (entering the
///      alternate screen if it shows), tab stops, the showing screen's rows
///      from the top, scrolling region, keyboard modes, and last its cursor
///      and pen, since everything before moves the cursor.
pub fn screenVt(alloc: Allocator, t: *const Terminal, max_history: usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    const options: formatter.Options = .{ .emit = .vt };

    // A clean slate for the replay, whatever wrote to the mirror before.
    try writer.writeAll("\x1bc");

    const primary = t.screens.get(.primary).?;
    try writeHistory(writer, primary, options, t.rows, max_history);

    if (t.screens.active_key == .alternate) {
        try writer.writeAll("\x1b[H");
        var rows: formatter.ScreenFormatter = .init(primary, options);
        rows.content = .{ .selection = activeArea(primary) };
        try rows.format(writer);
        var cursor: formatter.ScreenFormatter = .init(primary, options);
        cursor.content = .none;
        cursor.extra = .{
            .cursor = true,
            .style = false,
            .hyperlink = false,
            .protection = false,
            .kitty_keyboard = false,
            .charsets = false,
        };
        try cursor.format(writer);
        try writer.writeAll("\x1b[0m");
    }

    // Default colors, which the formatter's palette doesn't cover.
    if (t.colors.foreground.get()) |rgb| try writer.print("\x1b]10;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ rgb.r, rgb.g, rgb.b });
    if (t.colors.background.get()) |rgb| try writer.print("\x1b]11;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ rgb.r, rgb.g, rgb.b });

    var terminal: formatter.TerminalFormatter = .init(t, options);
    terminal.content = .{ .selection = activeArea(t.screens.active) };
    terminal.extra = .all;
    try terminal.format(writer);

    return try out.toOwnedSlice();
}

/// The rows of `screen`'s active area, top to bottom.
fn activeArea(screen: *const Screen) terminalpkg.Selection {
    return .init(
        screen.pages.getTopLeft(.active),
        screen.pages.getBottomRight(.active).?,
        false,
    );
}

/// The last `max` scrollback rows of `screen`, then line feeds that scroll
/// them all off a `rows`-tall screen into the replay's scrollback.
fn writeHistory(
    writer: *std.Io.Writer,
    screen: *const Screen,
    options: formatter.Options,
    rows: u16,
    max: usize,
) !void {
    const history = screen.pages.total_rows - screen.pages.rows;
    if (history == 0 or max == 0) return;
    const count = @min(history, max);
    const top = screen.pages.pin(.{ .screen = .{ .y = @intCast(history - count) } }) orelse return;
    const bottom = screen.pages.pin(.{ .screen = .{
        .x = screen.pages.cols - 1,
        .y = @intCast(history - 1),
    } }) orelse return;

    var formatted: formatter.ScreenFormatter = .init(screen, options);
    formatted.content = .{ .selection = .init(top, bottom, false) };
    try formatted.format(writer);

    // Each line feed at the bottom row scrolls one row into scrollback; from
    // any row, `rows` of them leave nothing printed on the screen.
    try writer.writeAll("\x1b[0m\r");
    for (0..rows) |_| try writer.writeByte('\n');
}

/// A source terminal with a tap, fed the way Termio feeds its terminal, and
/// a recording of every event for the tests.
const TestSource = struct {
    const testing = std.testing;

    terminal: Terminal,
    stream: terminalpkg.TerminalStream,
    tap: ?PtyTap = null,
    events: std.ArrayList(Recorded) = .empty,

    const Recorded = union(enum) {
        snapshot: struct { vt: []u8, cols: u16, rows: u16 },
        output: []u8,
        resize: struct { cols: u16, rows: u16 },
    };

    fn init(self: *TestSource, cols: u16, rows: u16) !void {
        self.* = .{
            .terminal = try .init(testing.io, testing.allocator, .{
                .cols = cols,
                .rows = rows,
                .max_scrollback_bytes = null,
            }),
            .stream = undefined,
        };
        self.stream = .init(.{
            .allocator = testing.allocator,
            .handler = .init(&self.terminal),
        });
    }

    fn deinit(self: *TestSource) void {
        for (self.events.items) |event| switch (event) {
            .snapshot => |snapshot| testing.allocator.free(snapshot.vt),
            .output => |bytes| testing.allocator.free(bytes),
            .resize => {},
        };
        self.events.deinit(testing.allocator);
        self.stream.deinit();
        self.terminal.deinit(testing.allocator);
    }

    fn setTap(self: *TestSource, on: bool) void {
        self.tap = if (on) .{ .userdata = self, .callback = record } else null;
        if (self.tap) |*tap| tap.requestSnapshot(
            testing.allocator,
            &self.terminal,
            &self.stream,
        );
    }

    fn feed(self: *TestSource, buf: []const u8) void {
        const rest = if (self.tap) |*tap|
            tap.output(testing.allocator, &self.terminal, &self.stream, buf)
        else
            buf;
        self.stream.nextSlice(rest);
    }

    fn resize(self: *TestSource, cols: u16, rows: u16) !void {
        try self.terminal.resize(testing.allocator, .{ .cols = cols, .rows = rows });
        if (self.tap) |*tap| tap.resized(cols, rows);
    }

    fn record(userdata: ?*anyopaque, event: Event) void {
        const self: *TestSource = @ptrCast(@alignCast(userdata.?));
        const recorded: Recorded = switch (event) {
            .snapshot => |snapshot| .{ .snapshot = .{
                .vt = testing.allocator.dupe(u8, snapshot.vt) catch unreachable,
                .cols = snapshot.cols,
                .rows = snapshot.rows,
            } },
            .output => |bytes| .{ .output = testing.allocator.dupe(u8, bytes) catch unreachable },
            .resize => |size| .{ .resize = .{ .cols = size.cols, .rows = size.rows } },
        };
        self.events.append(testing.allocator, recorded) catch unreachable;
    }

    /// A mirror built from the recorded events, as a device builds one: each
    /// snapshot written into a fresh terminal of its size, then the output
    /// and resizes after it.
    const Mirror = struct {
        terminal: *Terminal,
        stream: *terminalpkg.TerminalStream,

        fn deinit(self: Mirror) void {
            self.stream.deinit();
            self.terminal.deinit(testing.allocator);
            testing.allocator.destroy(self.stream);
            testing.allocator.destroy(self.terminal);
        }
    };

    fn mirror(self: *TestSource) !Mirror {
        try testing.expect(self.events.items.len > 0);
        try testing.expect(self.events.items[0] == .snapshot);

        var built: ?Mirror = null;
        errdefer if (built) |m| m.deinit();
        for (self.events.items) |event| switch (event) {
            .snapshot => |snapshot| {
                if (built) |m| m.deinit();
                built = null;
                const terminal = try testing.allocator.create(Terminal);
                terminal.* = try .init(testing.io, testing.allocator, .{
                    .cols = snapshot.cols,
                    .rows = snapshot.rows,
                    .max_scrollback_bytes = null,
                });
                const stream = try testing.allocator.create(terminalpkg.TerminalStream);
                stream.* = .init(.{ .allocator = testing.allocator, .handler = .init(terminal) });
                built = .{ .terminal = terminal, .stream = stream };
                stream.nextSlice(snapshot.vt);
            },
            .output => |bytes| built.?.stream.nextSlice(bytes),
            .resize => |size| try built.?.terminal.resize(
                testing.allocator,
                .{ .cols = size.cols, .rows = size.rows },
            ),
        };
        return built.?;
    }

    /// Builds a mirror and checks that it matches this terminal.
    fn expectMirrorMatches(self: *TestSource) !void {
        const built = try self.mirror();
        defer built.deinit();
        const m = built.terminal;
        try testing.expectEqual(self.terminal.cols, m.cols);
        try testing.expectEqual(self.terminal.rows, m.rows);

        const want = try self.terminal.plainString(testing.allocator);
        defer testing.allocator.free(want);
        const got = try m.plainString(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);

        const want_cursor = self.terminal.screens.active.cursor;
        const got_cursor = m.screens.active.cursor;
        try testing.expectEqual(want_cursor.x, got_cursor.x);
        try testing.expectEqual(want_cursor.y, got_cursor.y);
        try testing.expectEqual(want_cursor.style_id, got_cursor.style_id);
        try testing.expectEqual(
            self.terminal.screens.active_key,
            m.screens.active_key,
        );
    }

    fn outputs(self: *TestSource, alloc: Allocator) ![]u8 {
        var all: std.ArrayList(u8) = .empty;
        errdefer all.deinit(alloc);
        for (self.events.items) |event| switch (event) {
            .output => |bytes| try all.appendSlice(alloc, bytes),
            else => {},
        };
        return all.toOwnedSlice(alloc);
    }
};

test "pty_tap: snapshot first, then output in order" {
    const testing = std.testing;
    var source: TestSource = undefined;
    try source.init(20, 4);
    defer source.deinit();

    source.feed("before\r\n");
    source.setTap(true);
    try testing.expectEqual(1, source.events.items.len);
    try testing.expect(source.events.items[0] == .snapshot);

    source.feed("one ");
    source.feed("two ");
    source.feed("three");
    const all = try source.outputs(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("one two three", all);
    try source.expectMirrorMatches();
}

test "pty_tap: removing the tap stops delivery" {
    const testing = std.testing;
    var source: TestSource = undefined;
    try source.init(20, 4);
    defer source.deinit();

    source.setTap(true);
    source.feed("seen");
    source.setTap(false);
    source.feed("unseen");
    try source.resize(30, 5);

    const all = try source.outputs(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqualStrings("seen", all);
    try testing.expectEqual(2, source.events.items.len);
}

test "pty_tap: a snapshot waits for the parser to reach ground" {
    const testing = std.testing;
    var source: TestSource = undefined;
    try source.init(20, 4);
    defer source.deinit();

    // Cut in the middle of an SGR sequence: no snapshot can be exact yet.
    source.feed("A\x1b[3");
    source.setTap(true);
    try testing.expectEqual(0, source.events.items.len);

    // The bytes that finish the sequence are inside the snapshot; the rest
    // is delivered as output after it.
    source.feed("1mB");
    try testing.expectEqual(2, source.events.items.len);
    try testing.expect(source.events.items[0] == .snapshot);
    try testing.expectEqualStrings("B", source.events.items[1].output);
    try source.expectMirrorMatches();

    // Also across a UTF-8 codepoint split between reads.
    source.feed("\xe2\x82");
    source.tap.?.requestSnapshot(testing.allocator, &source.terminal, &source.stream);
    source.feed("\xac done");
    try source.expectMirrorMatches();
}

test "pty_tap: snapshot round trip with styles, scrollback and resize" {
    var source: TestSource = undefined;
    try source.init(40, 6);
    defer source.deinit();

    // Scrollback, colors and a cursor mid-line.
    for (0..30) |i| {
        var buf: [64]u8 = undefined;
        source.feed(try std.fmt.bufPrint(&buf, "\x1b[3{d}mline {d}\x1b[0m\r\n", .{ i % 8, i }));
    }
    source.feed("\x1b[1;33mprompt> \x1b[4m");
    source.setTap(true);

    source.feed("typed text");
    try source.resize(30, 8);
    source.feed("\r\nafter resize");
    try source.resize(50, 5);
    source.feed(" and again");
    try source.expectMirrorMatches();
}

test "pty_tap: snapshot round trip on the alternate screen" {
    var source: TestSource = undefined;
    try source.init(30, 6);
    defer source.deinit();

    source.feed("shell output\r\n$ vim\r\n");
    source.feed("\x1b[?1049h\x1b[H\x1b[2Jfile contents\x1b[3;5H");
    source.setTap(true);
    source.feed("\x1b[7mstatus\x1b[0m");
    try source.expectMirrorMatches();

    // Leaving the alternate screen restores the primary on both sides.
    source.feed("\x1b[?1049l$ ");
    try source.expectMirrorMatches();
}

test "pty_tap: a fresh snapshot replaces a stale mirror" {
    const testing = std.testing;
    var source: TestSource = undefined;
    try source.init(20, 4);
    defer source.deinit();

    source.setTap(true);
    source.feed("first");
    source.tap.?.requestSnapshot(testing.allocator, &source.terminal, &source.stream);
    source.feed(" second");
    try testing.expect(source.events.items[2] == .snapshot);
    try source.expectMirrorMatches();
}

test "pty_tap: snapshot history is limited" {
    const testing = std.testing;
    var source: TestSource = undefined;
    try source.init(20, 4);
    defer source.deinit();

    for (0..20_000) |i| {
        var buf: [32]u8 = undefined;
        source.feed(try std.fmt.bufPrint(&buf, "row {d}\r\n", .{i}));
    }
    source.setTap(true);

    const built = try source.mirror();
    defer built.deinit();
    const pages = &built.terminal.screens.active.pages;
    try testing.expectEqual(history_rows, pages.total_rows - pages.rows);
    try source.expectMirrorMatches();
}

test "pty_tap: scrollback lines up above the screen" {
    const testing = std.testing;
    var source: TestSource = undefined;
    try source.init(20, 6);
    defer source.deinit();

    // History, then a screen with blank rows at its foot that the formatter
    // trims: the screen must still start where the source's does.
    for (0..10) |i| {
        var buf: [32]u8 = undefined;
        source.feed(try std.fmt.bufPrint(&buf, "old {d}\r\n", .{i}));
    }
    source.feed("\x1b[2J\x1b[Htop row\r\nsecond");
    source.setTap(true);
    try source.expectMirrorMatches();

    const built = try source.mirror();
    defer built.deinit();
    const want = try source.terminal.screens.active.dumpStringAlloc(testing.allocator, .{ .history = .{} });
    defer testing.allocator.free(want);
    const got = try built.terminal.screens.active.dumpStringAlloc(testing.allocator, .{ .history = .{} });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "pty_tap: modes the keyboard needs come across" {
    const testing = std.testing;
    var source: TestSource = undefined;
    try source.init(20, 4);
    defer source.deinit();

    // Application cursor keys, bracketed paste and the Kitty keyboard protocol.
    source.feed("\x1b[?1h\x1b[?2004h\x1b[>1u");
    source.setTap(true);
    const built = try source.mirror();
    defer built.deinit();
    try testing.expect(built.terminal.modes.get(.cursor_keys));
    try testing.expect(built.terminal.modes.get(.bracketed_paste));
    try testing.expectEqual(
        source.terminal.screens.active.kitty_keyboard.current().int(),
        built.terminal.screens.active.kitty_keyboard.current().int(),
    );
}

test "pty_tap: screen_vt round trips the screen" {
    const testing = std.testing;
    var source: TestSource = undefined;
    try source.init(30, 5);
    defer source.deinit();
    source.feed("\x1b[38;2;10;20;30mcolored\x1b[0m plain\r\n\x1b[1mbold\x1b[0m");

    const vt = try screenVt(testing.allocator, &source.terminal, history_rows);
    defer testing.allocator.free(vt);
    var copy: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 30, .rows = 5 });
    defer copy.deinit(testing.allocator);
    var stream: terminalpkg.TerminalStream = .init(.{ .allocator = testing.allocator, .handler = .init(&copy) });
    defer stream.deinit();
    stream.nextSlice(vt);

    const want = try source.terminal.plainString(testing.allocator);
    defer testing.allocator.free(want);
    const got = try copy.plainString(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    try testing.expectEqual(source.terminal.screens.active.cursor.x, copy.screens.active.cursor.x);
}
