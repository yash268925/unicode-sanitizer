const std = @import("std");
const tables = @import("ucd_tables.zig");

const Range = tables.Range;

pub fn isExtPict(cp: u21) bool {
    return inRanges(&tables.extended_pictographic, cp);
}

pub fn isTransparent(cp: u21) bool {
    return inRanges(&tables.transparent, cp);
}

pub fn isJoinContext(cp: u21) bool {
    return inRanges(&tables.join_context, cp);
}

pub fn isStrongRtl(cp: u21) bool {
    return inRanges(&tables.strong_rtl, cp);
}

pub fn isUnifiedIdeograph(cp: u21) bool {
    return inRanges(&tables.unified_ideograph, cp);
}

pub fn isDefaultIgnorable(cp: u21) bool {
    return inRanges(&tables.default_ignorable, cp);
}

/// (base, vs) が variation_pairs に載っているか。vs が VS でなければ false。
pub fn hasVariation(base: u21, vs: u21) bool {
    const index = vsIndex(vs) orelse return false;
    const key = (@as(u32, base) << 5) | index;
    const pairs: []const u32 = &tables.variation_pairs;
    var lo: usize = 0;
    var hi: usize = pairs.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (pairs[mid] < key) {
            lo = mid + 1;
        } else if (pairs[mid] > key) {
            hi = mid;
        } else return true;
    }
    return false;
}

fn vsIndex(vs: u21) ?u5 {
    return switch (vs) {
        0xFE00...0xFE0F => @intCast(vs - 0xFE00),
        0x180B...0x180D => @intCast(vs - 0x180B + 16),
        0x180F => 19,
        else => null,
    };
}

fn inRanges(ranges: []const Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

const testing = std.testing;

const all_ranges = [_][]const Range{
    &tables.extended_pictographic,
    &tables.transparent,
    &tables.join_context,
    &tables.strong_rtl,
    &tables.unified_ideograph,
    &tables.default_ignorable,
};

test "Range 表は昇順・非重複" {
    for (all_ranges) |ranges| {
        try testing.expect(ranges.len > 0);
        for (ranges, 0..) |r, i| {
            try testing.expect(r[0] <= r[1]);
            if (i > 0) try testing.expect(ranges[i - 1][1] < r[0]);
        }
    }
}

test "variation_pairs は狭義単調増加" {
    const pairs = tables.variation_pairs;
    try testing.expect(pairs.len > 0);
    for (1..pairs.len) |i| try testing.expect(pairs[i - 1] < pairs[i]);
    for (pairs) |p| try testing.expect(p & 0x1F <= 19);
}

fn disjoint(a: []const Range, b: []const Range) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (a[i][1] < b[j][0]) {
            i += 1;
        } else if (b[j][1] < a[i][0]) {
            j += 1;
        } else return false;
    }
    return true;
}

// 除去対象に入ると、next として参照した文字が 2 回目の処理で消えて冪等性が崩れる。
test "ext_pict・unified_ideograph・variation_pairs の基底は default_ignorable と交差しない" {
    try testing.expect(disjoint(&tables.extended_pictographic, &tables.default_ignorable));
    try testing.expect(disjoint(&tables.unified_ideograph, &tables.default_ignorable));
    for (tables.variation_pairs) |p| {
        try testing.expect(!isDefaultIgnorable(@intCast(p >> 5)));
    }
}

test "代表点" {
    try testing.expect(isExtPict(0x1F469));
    try testing.expect(isExtPict(0x2764));
    try testing.expect(!isExtPict(0x1F3FD));

    try testing.expect(isTransparent(0x1F3FD));
    try testing.expect(isTransparent(0x0301));
    try testing.expect(isTransparent(0x200D));

    try testing.expect(isJoinContext(0x0627));
    try testing.expect(isJoinContext(0x094D));
    try testing.expect(isJoinContext(0x0640));
    try testing.expect(isJoinContext(0x0E01));
    try testing.expect(!isJoinContext('a'));
    try testing.expect(!isJoinContext(0x05D0));
    try testing.expect(!isJoinContext(0x200D));

    try testing.expect(isStrongRtl(0x05D0));
    try testing.expect(isStrongRtl(0x0627));
    try testing.expect(!isStrongRtl(0x200F));
    try testing.expect(!isStrongRtl(0x061C));
    try testing.expect(!isStrongRtl('a'));
    try testing.expect(!isStrongRtl('1'));

    try testing.expect(isUnifiedIdeograph(0x845B));

    try testing.expect(hasVariation(0x2764, 0xFE0F));
    try testing.expect(hasVariation(0x349E, 0xFE00));
    try testing.expect(hasVariation(0x1820, 0x180B));
    try testing.expect(!hasVariation('A', 0xFE00));
    try testing.expect(!hasVariation(0x1F3F4, 0xFE0F));

    try testing.expect(isDefaultIgnorable(0x200B));
    try testing.expect(!isDefaultIgnorable(0x0301));
}

test "VS でない引数と表の端" {
    try testing.expect(!hasVariation(0x2764, 0x200D));
    try testing.expect(!hasVariation(0x2764, 0xFE10));
    try testing.expect(!isExtPict(0));
    try testing.expect(!isExtPict(0x10FFFF));
    for (all_ranges) |ranges| {
        try testing.expect(inRanges(ranges, ranges[0][0]));
        try testing.expect(inRanges(ranges, ranges[ranges.len - 1][1]));
    }
}
