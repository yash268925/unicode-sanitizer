const std = @import("std");
const Io = std.Io;
const props = @import("props.zig");
const utf8 = @import("utf8.zig");

pub const Options = struct {
    keep_leading_bom: bool = false,
};

/// 段階 1(無条件除去)と段階 2(文脈判定)の状態機械。
pub const Filter = struct {
    keep_leading_bom: bool,
    started: bool = false,
    prev: ?u21 = null,
    base: ?u21 = null,
    rtl_seen: bool = false,
    /// next を待っている C1/C5/C7/C8 の文字。
    pending: ?u21 = null,
    tag: TagRun = .{},
    removed: bool = false,

    pub fn init(opts: Options) Filter {
        return .{ .keep_leading_bom = opts.keep_leading_bom };
    }

    pub fn push(self: *Filter, cp: u21, w: *Io.Writer) Io.Writer.Error!void {
        const first = !self.started;
        self.started = true;
        if (!(first and cp == 0xFEFF and self.keep_leading_bom) and
            props.isDefaultIgnorable(cp) and !isContextual(cp))
        {
            self.removed = true;
            return;
        }

        if (self.pending) |p| {
            self.pending = null;
            try self.resolve(p, cp, w);
        }

        if (self.tag.state != .none) {
            if (isTag(cp)) return self.tagStep(cp, w);
            // 終端の E007F が来る前に run が途切れた。
            self.tag.state = .none;
            self.removed = true;
        }

        try self.classify(cp, w);
    }

    pub fn finish(self: *Filter, w: *Io.Writer) Io.Writer.Error!void {
        if (self.pending) |p| {
            self.pending = null;
            try self.resolve(p, null, w);
        }
        if (self.tag.state != .none) {
            self.tag.state = .none;
            self.removed = true;
        }
    }

    fn classify(self: *Filter, cp: u21, w: *Io.Writer) Io.Writer.Error!void {
        switch (cp) {
            0x200C, 0x200D => {
                if (self.prev != null and isJoiner(self.prev.?)) return self.drop();
                if (self.base != null and props.isJoinContext(self.base.?)) return self.emit(cp, w);
                self.pending = cp;
            },
            0x200E, 0x200F, 0x061C => {
                if (self.prev != null and isMark(self.prev.?)) return self.drop();
                if (self.rtl_seen) return self.emit(cp, w);
                self.pending = cp;
            },
            0x115F => self.pending = cp,
            0x1160 => {
                const p = self.prev orelse return self.drop();
                if (isHangulChoseong(p)) return self.emit(cp, w);
                self.drop();
            },
            0x180E => {
                const p = self.prev orelse return self.drop();
                if (p >= 0x1800 and p <= 0x18AF) {
                    self.pending = cp;
                } else self.drop();
            },
            0xFE00...0xFE0F, 0x180B...0x180D, 0x180F => {
                const p = self.prev orelse return self.drop();
                if (props.hasVariation(p, cp)) return self.emit(cp, w);
                self.drop();
            },
            0xE0100...0xE01EF => {
                const p = self.prev orelse return self.drop();
                if (props.isUnifiedIdeograph(p)) return self.emit(cp, w);
                self.drop();
            },
            0xE0020...0xE007F => {
                self.tag = .{ .state = if (self.prev == 0x1F3F4) .collecting else .discarding };
                if (self.tag.state == .discarding) self.removed = true;
                try self.tagStep(cp, w);
            },
            else => try self.emit(cp, w),
        }
    }

    /// pending 中は何も出力していないので、prev・base・rtl_seen は保留した時点のままである。
    fn resolve(self: *Filter, cp: u21, next: ?u21, w: *Io.Writer) Io.Writer.Error!void {
        const keep = if (next) |n| switch (cp) {
            0x200C, 0x200D => props.isJoinContext(n) or
                (cp == 0x200D and self.base != null and props.isExtPict(self.base.?) and props.isExtPict(n)),
            0x200E, 0x200F, 0x061C => props.isStrongRtl(n),
            0x115F => isHangulJungseong(n),
            0x180E => n == 0x1820 or n == 0x1821,
            else => unreachable,
        } else false;
        if (keep) try self.emit(cp, w) else self.drop();
    }

    fn tagStep(self: *Filter, cp: u21, w: *Io.Writer) Io.Writer.Error!void {
        const run = &self.tag;
        if (cp == 0xE007F) {
            const ok = run.state == .collecting and run.complete();
            run.state = .none;
            if (!ok) return self.drop();
            for (run.spec[0..run.len]) |c| try self.emit(0xE0000 + @as(u21, c), w);
            return self.emit(cp, w);
        }
        if (run.state == .discarding) return;
        const c: u8 = @intCast(cp - 0xE0000);
        if (run.accepts(c)) {
            run.spec[run.len] = c;
            run.len += 1;
        } else {
            run.state = .discarding;
            self.removed = true;
        }
    }

    fn emit(self: *Filter, cp: u21, w: *Io.Writer) Io.Writer.Error!void {
        try utf8.encode(cp, w);
        self.prev = cp;
        if (!props.isTransparent(cp)) self.base = cp;
        if (isParagraphSeparator(cp)) {
            self.rtl_seen = false;
        } else if (!self.rtl_seen and props.isStrongRtl(cp)) {
            self.rtl_seen = true;
        }
    }

    fn drop(self: *Filter) void {
        self.removed = true;
    }
};

/// tag spec `([a-z]{2}|[0-9]{3})[a-z0-9]{1,4}` を 1 文字ずつ検査する。
const TagRun = struct {
    state: enum { none, collecting, discarding } = .none,
    spec: [7]u8 = undefined,
    len: u8 = 0,

    fn accepts(self: *const TagRun, c: u8) bool {
        const lower = c >= 'a' and c <= 'z';
        const digit = c >= '0' and c <= '9';
        if (self.len == 0) return lower or digit;
        const prefix: u8 = if (self.spec[0] <= '9') 3 else 2;
        if (self.len < prefix) return if (prefix == 3) digit else lower;
        return self.len < prefix + 4 and (lower or digit);
    }

    fn complete(self: *const TagRun) bool {
        if (self.len == 0) return false;
        const prefix: u8 = if (self.spec[0] <= '9') 3 else 2;
        return self.len > prefix;
    }
};

fn isContextual(cp: u21) bool {
    return switch (cp) {
        0x200C, 0x200D, 0x200E, 0x200F, 0x061C => true,
        0xFE00...0xFE0F, 0x180B...0x180F, 0xE0100...0xE01EF => true,
        0xE0020...0xE007F, 0x115F, 0x1160 => true,
        else => false,
    };
}

fn isTag(cp: u21) bool {
    return cp >= 0xE0020 and cp <= 0xE007F;
}

fn isJoiner(cp: u21) bool {
    return cp == 0x200C or cp == 0x200D;
}

fn isMark(cp: u21) bool {
    return cp == 0x200E or cp == 0x200F or cp == 0x061C;
}

fn isHangulChoseong(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115E) or (cp >= 0xA960 and cp <= 0xA97C);
}

fn isHangulJungseong(cp: u21) bool {
    return (cp >= 0x1161 and cp <= 0x11A7) or (cp >= 0xD7B0 and cp <= 0xD7C6);
}

fn isParagraphSeparator(cp: u21) bool {
    return switch (cp) {
        0x0A, 0x0D, 0x1C...0x1E, 0x85, 0x2029 => true,
        else => false,
    };
}

const testing = std.testing;

const Filtered = struct {
    aw: Io.Writer.Allocating,
    removed: bool,

    fn deinit(self: *Filtered) void {
        self.aw.deinit();
    }
};

fn filterAll(input: []const u21, opts: Options) !Filtered {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    var f: Filter = .init(opts);
    for (input) |cp| try f.push(cp, &aw.writer);
    try f.finish(&aw.writer);
    return .{ .aw = aw, .removed = f.removed };
}

fn expectFilterOpts(input: []const u21, expected: []const u21, opts: Options) !void {
    var got = try filterAll(input, opts);
    defer got.deinit();
    var want: Io.Writer.Allocating = .init(testing.allocator);
    defer want.deinit();
    for (expected) |cp| try utf8.encode(cp, &want.writer);
    try testing.expectEqualStrings(want.written(), got.aw.written());
    try testing.expectEqual(!std.mem.eql(u21, input, expected), got.removed);
}

fn expectFilter(input: []const u21, expected: []const u21) !void {
    try expectFilterOpts(input, expected, .{});
}

fn expectSame(input: []const u21) !void {
    try expectFilter(input, input);
}

fn tags(comptime spec: []const u8) [spec.len]u21 {
    var out: [spec.len]u21 = undefined;
    for (spec, 0..) |c, i| out[i] = 0xE0000 + @as(u21, c);
    return out;
}

test "振る舞いの例" {
    try expectSame(&.{ 0x0627, 0x200C, 0x0628 });
    try expectFilter(&.{ 0x0061, 0x200D, 0x0062 }, &.{ 0x0061, 0x0062 });
    try expectSame(&.{ 0x0995, 0x09CD, 0x200D, 0x09B7 });
    try expectSame(&.{ 0x09B0, 0x200D, 0x09CD, 0x09AF });
    try expectSame(&.{ 0x0647, 0x200D, 0x0020 });
    try expectSame(&.{ 0x0628, 0x064E, 0x200D, 0x0628 });
    try expectSame(&.{ 0x0061, 0x200D, 0x0E01 });
    try expectFilter(&.{ 0x0647, 0x200D, 0x200C, 0x200D, 0x200C, 0x0628 }, &.{ 0x0647, 0x200D, 0x0628 });
    try expectFilter(&.{ 0x1F469, 0x200D, 0x200D, 0x1F4BB }, &.{ 0x1F469, 0x200D, 0x1F4BB });
    try expectFilter(&.{ 0x1F469, 0x200D, 0x0061 }, &.{ 0x1F469, 0x0061 });
    try expectSame(&.{ 0x2764, 0xFE0F, 0x200D, 0x1F525 });
    try expectFilter(&.{ 0x2764, 0xFE0F, 0xFE0F }, &.{ 0x2764, 0xFE0F });
    try expectSame(&.{ 0x0023, 0xFE0F, 0x20E3 });
    try expectSame(&.{ 0x349E, 0xFE00 });
    try expectFilter(&.{ 0x0041, 0xFE00 }, &.{0x0041});
    try expectSame(&.{ 0x845B, 0xE0100 });
    try expectFilter(&.{ 0x0041, 0xE0100 }, &.{0x0041});
    try expectSame(&.{ 0x1820, 0x180B });
    try expectSame(&.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F });
    try expectFilter(
        &.{ 0x1F3F4, 0xFE0F, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F },
        &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0073, 0xE0063, 0xE0074, 0xE007F },
    );
    try expectFilter(&(.{0x1F3F4} ++ tags("gbabcdefg") ++ .{0xE007F}), &.{0x1F3F4});
    try expectFilter(&.{ 0x1F3F4, 0xE0067, 0xE0062 }, &.{0x1F3F4});
    try expectFilter(&(.{0x0065} ++ tags("HELLO") ++ .{0xE007F}), &.{0x0065});
    try expectSame(&.{ 0x115F, 0x1161 });
    try expectFilter(&.{ 0x115F, 0x1160 }, &.{});
    try expectSame(&.{ 0x1828, 0x180E, 0x1820 });
    try expectSame(&.{ 0x05E9, 0x05DC, 0x05D5, 0x05DD, 0x0021, 0x200F });
    try expectSame(&.{ 0x200F, 0x05E9, 0x05DC, 0x05D5, 0x05DD });
    try expectSame(&.{ 0x05E9, 0x0020, 0x0043, 0x002B, 0x002B, 0x200E, 0x0020, 0x05D4 });
    try expectFilter(&.{ 0x0061, 0x0064, 0x006D, 0x200F, 0x0069, 0x006E }, &.{ 0x0061, 0x0064, 0x006D, 0x0069, 0x006E });
    try expectFilter(&.{ 0x05E9, 0x200F, 0x200E }, &.{ 0x05E9, 0x200F });
    try expectFilter(&.{ 0x05E9, 0x000A, 0x0061, 0x200F, 0x0062 }, &.{ 0x05E9, 0x000A, 0x0061, 0x0062 });
    try expectFilter(&.{ 0x200F, 0x0031, 0x0032, 0x0033, 0x0020, 0x05E9 }, &.{ 0x0031, 0x0032, 0x0033, 0x0020, 0x05E9 });
    try expectFilterOpts(&.{ 0xFEFF, 0x0061 }, &.{ 0xFEFF, 0x0061 }, .{ .keep_leading_bom = true });
    try expectFilterOpts(&.{ 0xFEFF, 0x0061 }, &.{0x0061}, .{ .keep_leading_bom = false });
    try expectFilter(&.{ 0x0061, 0xFEFF, 0x0062 }, &.{ 0x0061, 0x0062 });
    try expectFilter(&.{ 0x0061, 0x200B, 0x200D, 0x0062 }, &.{ 0x0061, 0x0062 });
}

test "P1-P8 は無条件に除去される" {
    const cases = [_]u21{ 0x202E, 0x2067, 0x200B, 0x2060, 0x00AD, 0x034F, 0xFEFF, 0x3164, 0xFFA0, 0x17B4, 0x1BCA0, 0x1D173, 0xFFF0, 0xE0001, 0xE0FFF };
    for (cases) |cp| {
        try expectFilter(&.{ 'a', cp, 'b' }, &.{ 'a', 'b' });
        try expectFilter(&.{cp}, &.{});
    }
    // 先頭 BOM を残すのは最初の 1 文字目だけ。
    try expectFilterOpts(&.{ 0x0061, 0xFEFF }, &.{0x0061}, .{ .keep_leading_bom = true });
    try expectFilterOpts(&.{ 0x200B, 0xFEFF }, &.{}, .{ .keep_leading_bom = true });
}

test "C1 ZWJ / ZWNJ" {
    try expectSame(&.{ 0x0628, 0x200D });
    try expectSame(&.{ 0x200C, 0x0628 });
    try expectSame(&.{ 0x0915, 0x094D, 0x200C });
    try expectFilter(&.{ 0x0061, 0x200C, 0x0062 }, &.{ 0x0061, 0x0062 });
    try expectFilter(&.{ 0x0061, 0x200D }, &.{0x0061});
    try expectFilter(&.{0x200D}, &.{});
    try expectFilter(&.{ 0x1F469, 0x200C, 0x1F4BB }, &.{ 0x1F469, 0x1F4BB });
    try expectSame(&.{ 0x1F469, 0x1F3FD, 0x200D, 0x1F4BB });
    try expectFilter(&.{ 0x0628, 0x200D, 0x200D }, &.{ 0x0628, 0x200D });
}

test "C2 VS1-16 / FVS" {
    try expectFilter(&.{0xFE0F}, &.{});
    try expectFilter(&.{ 0x1F3F4, 0xFE0F }, &.{0x1F3F4});
    try expectFilter(&.{ 0x0061, 0x180B }, &.{0x0061});
}

test "C3 VS17-256" {
    try expectSame(&.{ 0x845B, 0xE01EF });
    try expectFilter(&.{0xE0100}, &.{});
}

test "C4 TAG" {
    try expectSame(&(.{0x1F3F4} ++ tags("123ab") ++ .{0xE007F}));
    try expectSame(&(.{0x1F3F4} ++ tags("1234567") ++ .{0xE007F}));
    try expectSame(&(.{0x1F3F4} ++ tags("gbabcd") ++ .{0xE007F}));
    try expectFilter(&(.{0x1F3F4} ++ tags("gb") ++ .{0xE007F}), &.{0x1F3F4});
    try expectFilter(&(.{0x1F3F4} ++ tags("12345678") ++ .{0xE007F}), &.{0x1F3F4});
    try expectFilter(&(.{0x1F3F4} ++ tags("12abc") ++ .{0xE007F}), &.{0x1F3F4});
    try expectFilter(&(.{0x1F3F4} ++ tags("GBENG") ++ .{0xE007F}), &.{0x1F3F4});
    try expectFilter(&.{ 0x1F3F4, 0xE007F }, &.{0x1F3F4});
    try expectFilter(&.{ 0x1F3F4, 0xE0067, 0xE0062, 0x0061, 0xE0065, 0xE007F }, &.{ 0x1F3F4, 0x0061 });
    // 段階 1 で消える文字は run を分断しない。
    try expectFilter(
        &.{ 0x1F3F4, 0xE0067, 0xE0001, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F },
        &.{ 0x1F3F4, 0xE0067, 0xE0062, 0xE0065, 0xE006E, 0xE0067, 0xE007F },
    );
    // 終端した後の run は新しい run として判定される(prev は E007F)。
    try expectFilter(
        &(.{0x1F3F4} ++ tags("gbeng") ++ .{0xE007F} ++ tags("gbeng") ++ .{0xE007F}),
        &(.{0x1F3F4} ++ tags("gbeng") ++ .{0xE007F}),
    );
}

test "C5 / C6 ハングルフィラー" {
    try expectSame(&.{ 0x115F, 0xD7B0 });
    try expectFilter(&.{ 0x115F, 0x0061 }, &.{0x0061});
    try expectFilter(&.{0x115F}, &.{});
    try expectSame(&.{ 0x1100, 0x1160 });
    try expectSame(&.{ 0xA97C, 0x1160 });
    try expectFilter(&.{ 0x0061, 0x1160 }, &.{0x0061});
    try expectFilter(&.{0x1160}, &.{});
}

test "C7 モンゴル MVS" {
    try expectSame(&.{ 0x1828, 0x180E, 0x1821 });
    try expectFilter(&.{ 0x0061, 0x180E, 0x1820 }, &.{ 0x0061, 0x1820 });
    try expectFilter(&.{ 0x1828, 0x180E, 0x1822 }, &.{ 0x1828, 0x1822 });
    try expectFilter(&.{ 0x1828, 0x180E }, &.{0x1828});
}

test "C8 Bidi マーク" {
    try expectSame(&.{ 0x061C, 0x0627 });
    try expectSame(&.{ 0x0627, 0x0020, 0x061C });
    try expectFilter(&.{ 0x0061, 0x061C }, &.{0x0061});
    try expectFilter(&.{ 0x200E, 0x200F, 0x05E9 }, &.{ 0x200F, 0x05E9 });
    try expectFilter(&.{ 0x05E9, 0x2029, 0x200E, 0x0061 }, &.{ 0x05E9, 0x2029, 0x0061 });
    try expectSame(&.{ 0x05E9, 0x0061, 0x0062, 0x200E });
}

test "next は段階 1 で除去される文字を飛ばした次の文字" {
    try expectFilter(&.{ 0x0061, 0x200D, 0x200B, 0x0E01 }, &.{ 0x0061, 0x200D, 0x0E01 });
    try expectFilter(&.{ 0x1F469, 0x200D, 0xFEFF, 0x1F4BB }, &.{ 0x1F469, 0x200D, 0x1F4BB });
    try expectFilter(&.{ 0x200F, 0x00AD, 0x05E9 }, &.{ 0x200F, 0x05E9 });
    try expectFilter(&.{ 0x115F, 0x034F, 0x1161 }, &.{ 0x115F, 0x1161 });
    try expectFilter(&.{ 0x1828, 0x180E, 0xFEFF, 0x1820 }, &.{ 0x1828, 0x180E, 0x1820 });
}

test "保留中の文字と tag run" {
    // next が TAG なら保留は除去され、tag run は保留より前の文字を prev として判定される。
    try expectFilter(
        &(.{ 0x1F3F4, 0x200D } ++ tags("gbeng") ++ .{0xE007F}),
        &(.{0x1F3F4} ++ tags("gbeng") ++ .{0xE007F}),
    );
    try expectFilter(&.{ 0x1F3F4, 0xE0067, 0x200D }, &.{0x1F3F4});
}

fn expectPushed(f: *Filter, aw: *Io.Writer.Allocating, cp: u21, expected: []const u21) !void {
    try f.push(cp, &aw.writer);
    var want: Io.Writer.Allocating = .init(testing.allocator);
    defer want.deinit();
    for (expected) |c| try utf8.encode(c, &want.writer);
    try testing.expectEqualStrings(want.written(), aw.written());
}

test "C1(1)(2)・C8(1)(2) で決まる場合は next を待たずに出力する" {
    {
        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var f: Filter = .init(.{});
        try expectPushed(&f, &aw, 0x0628, &.{0x0628});
        try expectPushed(&f, &aw, 0x200D, &.{ 0x0628, 0x200D });
    }
    {
        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var f: Filter = .init(.{});
        try expectPushed(&f, &aw, 0x05E9, &.{0x05E9});
        try expectPushed(&f, &aw, 0x0021, &.{ 0x05E9, 0x0021 });
        try expectPushed(&f, &aw, 0x200F, &.{ 0x05E9, 0x0021, 0x200F });
    }
    {
        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var f: Filter = .init(.{});
        try expectPushed(&f, &aw, 0x0061, &.{0x0061});
        try expectPushed(&f, &aw, 0x200D, &.{0x0061});
        try expectPushed(&f, &aw, 0x0E01, &.{ 0x0061, 0x200D, 0x0E01 });
    }
}

test "対象外の文字はそのまま通す" {
    try expectSame(&.{ 0x0065, 0x0301, 0x1F1EF, 0x1F1F5, 0x00A0, 0x3000, 0x0000, 0x0085, 0x2028, 0xE000, 0xFFFE, 0xFFFC, 0x000D, 0x000A });
}

test "コーパスの各行" {
    const corpus = @import("corpus").text;
    var changed: [18]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, corpus, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len < 2 or !std.ascii.isDigit(line[0]) or !std.ascii.isDigit(line[1])) continue;
        const n = try std.fmt.parseInt(usize, line[0..2], 10);
        count += 1;

        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        var f: Filter = .init(.{});
        var it = (try std.unicode.Utf8View.init(line)).iterator();
        while (it.nextCodepoint()) |cp| try f.push(cp, &aw.writer);
        try f.finish(&aw.writer);

        changed[n] = !std.mem.eql(u8, line, aw.written());
        try testing.expectEqual(changed[n], f.removed);
    }
    try testing.expectEqual(17, count);
    for (1..18) |n| {
        const expected = switch (n) {
            10, 12, 13, 14, 15 => false,
            else => true,
        };
        try testing.expectEqual(expected, changed[n]);
    }
}
