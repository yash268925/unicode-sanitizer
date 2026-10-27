const std = @import("std");
const Io = std.Io;
const utf8 = @import("utf8.zig");
const filter = @import("filter.zig");

pub const Options = filter.Options;

pub const Result = struct {
    /// 除去または U+FFFD への置換が 1 件でもあったか。
    changed: bool,
};

const Sink = struct {
    filter: *filter.Filter,
    w: *Io.Writer,

    pub fn emit(self: Sink, cp: u21) Io.Writer.Error!void {
        try self.filter.push(cp, self.w);
    }
};

/// r を最後まで読み、除去後の UTF-8 を w に書く。状態は呼び出しごとに初期化する。
pub fn run(r: *Io.Reader, w: *Io.Writer, opts: Options) (Io.Reader.Error || Io.Writer.Error)!Result {
    var dec: utf8.Decoder = .{};
    var f: filter.Filter = .init(opts);
    const sink: Sink = .{ .filter = &f, .w = w };
    while (true) {
        // fillMore を先に呼ぶと、最初から全データがバッファにある Reader で処理前に EndOfStream になる。
        const chunk = r.buffered();
        try dec.feed(chunk, sink);
        r.toss(chunk.len);
        try w.flush();
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
    }
    try dec.finish(sink);
    try f.finish(w);
    try w.flush();
    return .{ .changed = dec.replaced or f.removed };
}

const testing = std.testing;

const Cleaned = struct {
    out: []u8,
    result: Result,

    fn deinit(self: Cleaned) void {
        testing.allocator.free(self.out);
    }
};

/// buf_len が null なら全データを最初からバッファに持つ Reader で、そうでなければ
/// その大きさの読み取りバッファで与える。
fn cleanBytes(input: []const u8, buf_len: ?usize, opts: Options) !Cleaned {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    const result = if (buf_len) |n| blk: {
        var buf: [16]u8 = undefined;
        var tr: std.testing.Reader = .init(buf[0..n], &.{.{ .buffer = input }});
        break :blk try run(&tr.interface, &aw.writer, opts);
    } else blk: {
        var r: Io.Reader = .fixed(input);
        break :blk try run(&r, &aw.writer, opts);
    };
    return .{ .out = try aw.toOwnedSlice(), .result = result };
}

const alphabet = ascii ++ targets ++ emoji ++ scripts ++ invalid;
const ascii = [_][]const u8{ "a", "Z", "1", " ", "!", "#", "\n", "\r\n", "\u{2029}" };
const targets = [_][]const u8{
    "\u{200D}",  "\u{200C}",  "\u{FE0F}",  "\u{FE00}", "\u{180B}", "\u{E0100}", "\u{E0067}", "\u{E0062}",
    "\u{E0031}", "\u{E007F}", "\u{E0001}", "\u{115F}", "\u{1160}", "\u{180E}",  "\u{200E}",  "\u{200F}",
    "\u{061C}",  "\u{FEFF}",  "\u{200B}",  "\u{202E}", "\u{2067}", "\u{00AD}",  "\u{3164}",
};
const emoji = [_][]const u8{ "\u{1F469}", "\u{1F4BB}", "\u{2764}", "\u{1F3F4}", "\u{1F3FD}", "\u{20E3}" };
const scripts = [_][]const u8{
    "\u{0627}", "\u{0628}", "\u{064E}", "\u{0647}", "\u{05E9}", "\u{05D5}", "\u{0915}", "\u{094D}",
    "\u{1100}", "\u{1161}", "\u{11A8}", "\u{D7B0}", "\u{845B}", "\u{1820}", "\u{1828}",
};
const invalid = [_][]const u8{ "\x80", "\xBF", "\xC0", "\xC2", "\xE1\x80", "\xED\xA0\x80", "\xF0\x9F", "\xF0\x82\x80\x8B", "\xF4\x90", "\xFF" };

fn randomInput(rand: std.Random, buf: *std.ArrayList(u8)) !void {
    buf.clearRetainingCapacity();
    const n = rand.uintLessThan(usize, 40);
    for (0..n) |_| try buf.appendSlice(testing.allocator, alphabet[rand.uintLessThan(usize, alphabet.len)]);
}

fn decodeAll(bytes: []const u8) ![]u21 {
    const ListSink = struct {
        list: std.ArrayList(u21) = .empty,

        pub fn emit(self: *@This(), cp: u21) !void {
            try self.list.append(testing.allocator, cp);
        }
    };
    var sink: ListSink = .{};
    errdefer sink.list.deinit(testing.allocator);
    var d: utf8.Decoder = .{};
    try d.feed(bytes, &sink);
    try d.finish(&sink);
    return sink.list.toOwnedSlice(testing.allocator);
}

fn expectSubsequence(sub: []const u21, seq: []const u21) !void {
    var i: usize = 0;
    for (seq) |cp| {
        if (i < sub.len and sub[i] == cp) i += 1;
    }
    try testing.expectEqual(sub.len, i);
}

test "ランダム入力での性質" {
    var prng: std.Random.DefaultPrng = .init(0x75736E);
    const rand = prng.random();
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);

    for (0..2000) |_| {
        try randomInput(rand, &input);
        const opts: Options = .{ .keep_leading_bom = rand.boolean() };

        const once = try cleanBytes(input.items, null, opts);
        defer once.deinit();

        const twice = try cleanBytes(once.out, null, opts);
        defer twice.deinit();
        try testing.expectEqualStrings(once.out, twice.out);
        try testing.expect(!twice.result.changed);

        for ([_]usize{ 1, 2, 3, 7 }) |n| {
            const chunked = try cleanBytes(input.items, n, opts);
            defer chunked.deinit();
            try testing.expectEqualStrings(once.out, chunked.out);
            try testing.expectEqual(once.result.changed, chunked.result.changed);
        }

        try testing.expect(std.unicode.utf8ValidateSlice(once.out));
        const in_cps = try decodeAll(input.items);
        defer testing.allocator.free(in_cps);
        const out_cps = try decodeAll(once.out);
        defer testing.allocator.free(out_cps);
        try expectSubsequence(out_cps, in_cps);

        try testing.expectEqual(!std.mem.eql(u8, input.items, once.out), once.result.changed);
    }
}

test "コーパス全体の出力が行ごとの Filter の結果と一致する" {
    const corpus = @import("corpus").text;
    const whole = try cleanBytes(corpus, null, .{});
    defer whole.deinit();
    try testing.expect(whole.result.changed);

    var in_lines = std.mem.splitScalar(u8, corpus, '\n');
    var out_lines = std.mem.splitScalar(u8, whole.out, '\n');
    while (in_lines.next()) |line| {
        const out_line = out_lines.next() orelse return error.TestUnexpectedResult;

        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var f: filter.Filter = .init(.{});
        var it = (try std.unicode.Utf8View.init(line)).iterator();
        while (it.nextCodepoint()) |cp| try f.push(cp, &aw.writer);
        try f.finish(&aw.writer);

        try testing.expectEqualStrings(aw.written(), out_line);
    }
    try testing.expectEqual(null, out_lines.next());
}
