const std = @import("std");
const Io = std.Io;

pub const replacement: u21 = 0xFFFD;

/// sink は `emit(cp: u21) !void` を持つ値(通常はポインタ)。
pub const Decoder = struct {
    cp: u21 = 0,
    /// 残りの継続バイト数。0 ならシーケンスの途中ではない。
    need: u2 = 0,
    /// 次の継続バイトとして許される範囲(Table 3-7)。
    lo: u8 = 0x80,
    hi: u8 = 0xBF,
    replaced: bool = false,

    pub fn feed(self: *Decoder, bytes: []const u8, sink: anytype) !void {
        for (bytes) |b| try self.byte(b, sink);
    }

    pub fn finish(self: *Decoder, sink: anytype) !void {
        if (self.need != 0) {
            self.need = 0;
            try self.replace(sink);
        }
    }

    fn byte(self: *Decoder, b: u8, sink: anytype) !void {
        if (self.need != 0) {
            if (b >= self.lo and b <= self.hi) {
                self.cp = (self.cp << 6) | (b & 0x3F);
                self.need -= 1;
                self.lo = 0x80;
                self.hi = 0xBF;
                if (self.need == 0) try sink.emit(self.cp);
                return;
            }
            // 検出を起こしたバイトは捨てずに新しいシーケンスの先頭として読み直す。
            self.need = 0;
            try self.replace(sink);
        }
        switch (b) {
            0x00...0x7F => try sink.emit(b),
            0xC2...0xDF => self.start(b & 0x1F, 1, 0x80, 0xBF),
            0xE0 => self.start(0, 2, 0xA0, 0xBF),
            0xE1...0xEC, 0xEE...0xEF => self.start(b & 0x0F, 2, 0x80, 0xBF),
            0xED => self.start(0x0D, 2, 0x80, 0x9F),
            0xF0 => self.start(0, 3, 0x90, 0xBF),
            0xF1...0xF3 => self.start(b & 0x07, 3, 0x80, 0xBF),
            0xF4 => self.start(0x04, 3, 0x80, 0x8F),
            else => try self.replace(sink),
        }
    }

    fn start(self: *Decoder, cp: u21, need: u2, lo: u8, hi: u8) void {
        self.cp = cp;
        self.need = need;
        self.lo = lo;
        self.hi = hi;
    }

    fn replace(self: *Decoder, sink: anytype) !void {
        self.lo = 0x80;
        self.hi = 0xBF;
        self.replaced = true;
        try sink.emit(replacement);
    }
};

/// cp はサロゲートでないこと(Decoder の出力は常に満たす)。
pub fn encode(cp: u21, w: *Io.Writer) Io.Writer.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
    try w.writeAll(buf[0..n]);
}

const testing = std.testing;

const TestSink = struct {
    list: std.ArrayList(u21) = .empty,

    fn emit(self: *TestSink, cp: u21) !void {
        try self.list.append(testing.allocator, cp);
    }
};

const Decoded = struct {
    cps: []u21,
    replaced: bool,
};

/// mask のビット i が立っていれば bytes[i] の直後で入力を区切る。
fn decodeSplit(bytes: []const u8, mask: u64) !Decoded {
    var sink: TestSink = .{};
    errdefer sink.list.deinit(testing.allocator);
    var d: Decoder = .{};
    var begin: usize = 0;
    for (0..bytes.len) |i| {
        if (i + 1 == bytes.len or (mask >> @intCast(i)) & 1 != 0) {
            try d.feed(bytes[begin .. i + 1], &sink);
            begin = i + 1;
        }
    }
    try d.finish(&sink);
    return .{ .cps = try sink.list.toOwnedSlice(testing.allocator), .replaced = d.replaced };
}

/// 16 バイト以下なら 2^(len-1) 通りのすべての区切り方で、それより長ければ
/// 区切り 1 か所の全位置と 1 バイトずつで、同じ結果になることを確かめる。
fn expectDecode(bytes: []const u8, expected: []const u21, replaced: bool) !void {
    std.debug.assert(bytes.len <= 64);
    if (bytes.len <= 16) {
        const splits: u64 = if (bytes.len <= 1) 1 else @as(u64, 1) << @intCast(bytes.len - 1);
        var mask: u64 = 0;
        while (mask < splits) : (mask += 1) try expectDecodeSplit(bytes, mask, expected, replaced);
    } else {
        try expectDecodeSplit(bytes, 0, expected, replaced);
        try expectDecodeSplit(bytes, std.math.maxInt(u64), expected, replaced);
        for (0..bytes.len - 1) |i| try expectDecodeSplit(bytes, @as(u64, 1) << @intCast(i), expected, replaced);
    }
}

fn expectDecodeSplit(bytes: []const u8, mask: u64, expected: []const u21, replaced: bool) !void {
    const got = try decodeSplit(bytes, mask);
    defer testing.allocator.free(got.cps);
    try testing.expectEqualSlices(u21, expected, got.cps);
    try testing.expectEqual(replaced, got.replaced);
}

test "不正 UTF-8 は maximal subpart ごとに U+FFFD になる" {
    try expectDecode(
        &.{ 0x61, 0xF1, 0x80, 0x80, 0xE1, 0x80, 0xC2, 0x62, 0x80, 0x63, 0x80, 0xBF, 0x64 },
        &.{ 0x61, 0xFFFD, 0xFFFD, 0xFFFD, 0x62, 0xFFFD, 0x63, 0xFFFD, 0xFFFD, 0x64 },
        true,
    );
    try expectDecode(&.{ 0xF0, 0x80, 0x80 }, &.{ 0xFFFD, 0xFFFD, 0xFFFD }, true);
    try expectDecode(&.{ 0xE1, 0x80 }, &.{0xFFFD}, true);
    try expectDecode(&.{ 0xED, 0xA0, 0x80 }, &.{ 0xFFFD, 0xFFFD, 0xFFFD }, true);
    try expectDecode(&.{ 0xC0, 0xAF }, &.{ 0xFFFD, 0xFFFD }, true);
    try expectDecode(&.{ 0xF4, 0x90, 0x80, 0x80 }, &.{ 0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD }, true);
    try expectDecode(&.{ 0xF0, 0x9F, 0x98 }, &.{0xFFFD}, true);
}

test "境界値が往復する" {
    const cps = [_]u21{ 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF };
    var buf: [cps.len * 4]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    for (cps) |cp| {
        var one_buf: [4]u8 = undefined;
        var one: Io.Writer = .fixed(&one_buf);
        try encode(cp, &one);
        try expectDecode(one.buffered(), &.{cp}, false);
        try encode(cp, &w);
    }
    try expectDecode(w.buffered(), &cps, false);
}

test "正当な入力では replaced が偽のまま" {
    try expectDecode("", &.{}, false);
    try expectDecode("a\u{200D}\u{1F469}", &.{ 0x61, 0x200D, 0x1F469 }, false);
}
