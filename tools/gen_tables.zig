//! UCD のファイル群から src/ucd_tables.zig と testdata/emoji-test-sequences.txt を生成する。
//! 使い方: gen_tables <UCD ディレクトリ> <表の出力先> <絵文字フィクスチャの出力先>
//! 通常は `zig build gen -Ducd=<dir>` 経由で実行する(.claude/skills/ucd-tables/SKILL.md)。

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const n_code_points = 0x110000;
const Range = [2]u21;
const CpSet = std.bit_set.DynamicBitSetUnmanaged;

const max_fields = 8;

/// UCD のデータ行を 1 行ずつ欄に分ける。コメントと空行は飛ばす。
const Records = struct {
    lines: std.mem.SplitIterator(u8, .scalar),
    line_no: usize = 0,
    buf: [max_fields][]const u8 = undefined,

    fn init(text: []const u8) Records {
        return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
    }

    /// 返すスライスは次の呼び出しまで有効。max_fields を超える欄は捨てる。
    fn next(self: *Records) ?[]const []const u8 {
        while (self.lines.next()) |raw| {
            self.line_no += 1;
            if (splitFields(raw, &self.buf)) |fields| return fields;
        }
        return null;
    }
};

fn splitFields(raw: []const u8, buf: *[max_fields][]const u8) ?[]const []const u8 {
    const data = if (std.mem.indexOfScalar(u8, raw, '#')) |i| raw[0..i] else raw;
    if (std.mem.trim(u8, data, " \t\r").len == 0) return null;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, data, ';');
    while (it.next()) |field| {
        if (n == max_fields) break;
        buf[n] = std.mem.trim(u8, field, " \t\r");
        n += 1;
    }
    return buf[0..n];
}

fn parseCodePoint(s: []const u8) !u21 {
    if (s.len < 4 or s.len > 6) return error.InvalidCodePoint;
    const cp = std.fmt.parseInt(u21, s, 16) catch return error.InvalidCodePoint;
    if (cp >= n_code_points) return error.InvalidCodePoint;
    return cp;
}

/// `XXXX` または `XXXX..YYYY` を閉区間にする。
fn parseRange(s: []const u8) !Range {
    if (std.mem.indexOf(u8, s, "..")) |i| {
        const lo = try parseCodePoint(s[0..i]);
        const hi = try parseCodePoint(s[i + 2 ..]);
        if (lo > hi) return error.InvalidRange;
        return .{ lo, hi };
    }
    const cp = try parseCodePoint(s);
    return .{ cp, cp };
}

/// 空白区切りのコードポイント列を out に読む。
fn parseSequence(s: []const u8, out: []u21) ![]u21 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok| {
        if (n == out.len) return error.SequenceTooLong;
        out[n] = try parseCodePoint(tok);
        n += 1;
    }
    if (n == 0) return error.EmptySequence;
    return out[0..n];
}

/// 先頭行 `# <stem>-<version>.txt` から版を取り出す。
fn fileVersion(text: []const u8, stem: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    const first = std.mem.trimEnd(u8, text[0..end], "\r");
    const prefix = "# ";
    const suffix = ".txt";
    if (!std.mem.startsWith(u8, first, prefix) or !std.mem.endsWith(u8, first, suffix)) return null;
    const name = first[prefix.len .. first.len - suffix.len];
    if (name.len <= stem.len + 1 or !std.mem.startsWith(u8, name, stem) or name[stem.len] != '-') return null;
    return name[stem.len + 1 ..];
}

/// FE00..FE0F → 0..15、180B..180D → 16..18、180F → 19。
fn vsIndex(vs: u21) ?u5 {
    return switch (vs) {
        0xFE00...0xFE0F => @intCast(vs - 0xFE00),
        0x180B...0x180D => @intCast(vs - 0x180B + 16),
        0x180F => 19,
        else => null,
    };
}

fn newSet(gpa: Allocator) !CpSet {
    return CpSet.initEmpty(gpa, n_code_points);
}

fn addRange(set: *CpSet, r: Range) void {
    set.setRangeValue(.{ .start = r[0], .end = @as(usize, r[1]) + 1 }, true);
}

fn subtract(set: *CpSet, cut: CpSet) void {
    var it = cut.iterator(.{});
    while (it.next()) |cp| set.unset(cp);
}

/// 集合を昇順・非重複・隣接マージ済みのレンジ列にする。
fn toRanges(gpa: Allocator, set: CpSet) ![]Range {
    var out: std.ArrayList(Range) = .empty;
    errdefer out.deinit(gpa);
    var cp: usize = 0;
    while (cp < set.bit_length) : (cp += 1) {
        if (!set.isSet(cp)) continue;
        const lo = cp;
        while (cp + 1 < set.bit_length and set.isSet(cp + 1)) cp += 1;
        try out.append(gpa, .{ @intCast(lo), @intCast(cp) });
    }
    return out.toOwnedSlice(gpa);
}

fn lessThanU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

/// 昇順に並べて重複を除く。
fn sortUnique(items: []u32) []u32 {
    std.mem.sort(u32, items, {}, lessThanU32);
    var n: usize = 0;
    for (items) |x| {
        if (n > 0 and items[n - 1] == x) continue;
        items[n] = x;
        n += 1;
    }
    return items[0..n];
}

const Tables = struct {
    unicode_version: []const u8,
    extended_pictographic: []const Range,
    transparent: []const Range,
    join_context: []const Range,
    strong_rtl: []const Range,
    unified_ideograph: []const Range,
    default_ignorable: []const Range,
    variation_pairs: []const u32,
};

fn writeRanges(w: *Io.Writer, name: []const u8, ranges: []const Range) !void {
    try w.print("\npub const {s} = [_]Range{{\n", .{name});
    for (ranges) |r| try w.print("    .{{ 0x{X:0>4}, 0x{X:0>4} }},\n", .{ r[0], r[1] });
    try w.writeAll("};\n");
}

fn writeTables(w: *Io.Writer, t: Tables) !void {
    try w.print(
        \\// 生成物のため手で編集しない。
        \\// 生成元: Unicode Character Database {s}
        \\// 生成コマンド: zig build gen -Ducd=<UCD ディレクトリ>(生成器は tools/gen_tables.zig)
        \\// UCD 由来のデータであり、Unicode License V3(LICENSES/Unicode-3.0.txt)に従う。
        \\
        \\pub const unicode_version = "{s}";
        \\pub const Range = [2]u21; // 閉区間 [lo, hi]
        \\
    , .{ t.unicode_version, t.unicode_version });
    try writeRanges(w, "extended_pictographic", t.extended_pictographic);
    try writeRanges(w, "transparent", t.transparent);
    try writeRanges(w, "join_context", t.join_context);
    try writeRanges(w, "strong_rtl", t.strong_rtl);
    try writeRanges(w, "unified_ideograph", t.unified_ideograph);
    try writeRanges(w, "default_ignorable", t.default_ignorable);
    try w.writeAll(
        \\
        \\/// (base << 5) | vs_index の昇順。
        \\/// vs_index: FE00..FE0F → 0..15、180B..180D → 16..18、180F → 19。
        \\pub const variation_pairs = [_]u32{
        \\
    );
    for (t.variation_pairs) |p| try w.print("    0x{X:0>7},\n", .{p});
    try w.writeAll("};\n");
}

/// emoji-test.txt のデータ行の第 1 欄を 1 行 1 シーケンスの UTF-8 で書く。
fn writeEmojiFixture(w: *Io.Writer, emoji_test: []const u8) !void {
    var recs: Records = .init(emoji_test);
    while (recs.next()) |f| {
        if (f.len < 2) continue;
        var seq_buf: [32]u21 = undefined;
        const seq = try parseSequence(f[0], &seq_buf);
        for (seq) |cp| {
            var utf8: [4]u8 = undefined;
            const n = try std.unicode.utf8Encode(cp, &utf8);
            try w.writeAll(utf8[0..n]);
        }
        try w.writeByte('\n');
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("gen_tables: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Ucd = struct {
    io: Io,
    dir: Io.Dir,
    arena: Allocator,

    fn read(self: Ucd, name: []const u8) []const u8 {
        return self.dir.readFileAlloc(self.io, name, self.arena, .limited(16 << 20)) catch |err|
            fatal("{s}: {t}", .{ name, err });
    }
};

fn parseRangeOrDie(name: []const u8, line_no: usize, s: []const u8) Range {
    return parseRange(s) catch |err| fatal("{s}:{d}: {t}", .{ name, line_no, err });
}

/// 第 2 欄が value に一致する行のコードポイントを集める。
fn propertySet(gpa: Allocator, name: []const u8, text: []const u8, value: []const u8) !CpSet {
    var set = try newSet(gpa);
    var recs: Records = .init(text);
    while (recs.next()) |f| {
        if (f.len < 2 or !std.mem.eql(u8, f[1], value)) continue;
        addRange(&set, parseRangeOrDie(name, recs.line_no, f[0]));
    }
    return set;
}

/// Script 番号の表。番号 0 は Unknown(Scripts.txt に載らないコードポイント)。
const ScriptMap = struct {
    of_cp: []u8,
    names: std.ArrayList([]const u8),

    fn index(self: ScriptMap, name: []const u8) ?u8 {
        for (self.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return @intCast(i);
        }
        return null;
    }
};

fn loadScripts(gpa: Allocator, name: []const u8, text: []const u8) !ScriptMap {
    var map: ScriptMap = .{ .of_cp = try gpa.alloc(u8, n_code_points), .names = .empty };
    @memset(map.of_cp, 0);
    try map.names.append(gpa, "Unknown");
    var recs: Records = .init(text);
    while (recs.next()) |f| {
        if (f.len < 2) continue;
        const r = parseRangeOrDie(name, recs.line_no, f[0]);
        const sc = map.index(f[1]) orelse blk: {
            if (map.names.items.len > std.math.maxInt(u8)) fatal("{s}: too many scripts", .{name});
            try map.names.append(gpa, f[1]);
            break :blk @as(u8, @intCast(map.names.items.len - 1));
        };
        @memset(map.of_cp[r[0] .. @as(usize, r[1]) + 1], sc);
    }
    return map;
}

fn addPairs(gpa: Allocator, pairs: *std.ArrayList(u32), name: []const u8, text: []const u8) !void {
    var recs: Records = .init(text);
    while (recs.next()) |f| {
        var buf: [2]u21 = undefined;
        const seq = parseSequence(f[0], &buf) catch |err| fatal("{s}:{d}: {t}", .{ name, recs.line_no, err });
        if (seq.len != 2) fatal("{s}:{d}: expected 2 code points", .{ name, recs.line_no });
        const vs = vsIndex(seq[1]) orelse
            fatal("{s}:{d}: unexpected variation selector {X:0>4}", .{ name, recs.line_no, seq[1] });
        try pairs.append(gpa, (@as(u32, seq[0]) << 5) | vs);
    }
}

fn generate(gpa: Allocator, ucd: Ucd) !Tables {
    const scripts_txt = ucd.read("Scripts.txt");
    const version = fileVersion(scripts_txt, "Scripts") orelse
        fatal("Scripts.txt: first line does not carry a version", .{});
    const versioned = [_][]const u8{
        "PropList",
        "DerivedCoreProperties",
        "StandardizedVariants",
        "DerivedJoiningType",
        "DerivedCombiningClass",
        "DerivedBidiClass",
    };
    var texts: [versioned.len][]const u8 = undefined;
    for (versioned, &texts) |stem, *text| {
        const name = try std.fmt.allocPrint(ucd.arena, "{s}.txt", .{stem});
        text.* = ucd.read(name);
        const v = fileVersion(text.*, stem) orelse fatal("{s}: first line does not carry a version", .{name});
        if (!std.mem.eql(u8, v, version)) fatal("{s}: version {s} differs from Scripts.txt ({s})", .{ name, v, version });
    }
    const prop_list, const core_props, const std_variants, const joining, const ccc, const bidi = texts;
    const emoji_data = ucd.read("emoji-data.txt");
    const emoji_vs = ucd.read("emoji-variation-sequences.txt");

    const di = try propertySet(gpa, "DerivedCoreProperties.txt", core_props, "Default_Ignorable_Code_Point");
    const ext_pict = try propertySet(gpa, "emoji-data.txt", emoji_data, "Extended_Pictographic");
    const unified = try propertySet(gpa, "PropList.txt", prop_list, "Unified_Ideograph");

    const scripts = try loadScripts(gpa, "Scripts.txt", scripts_txt);
    const inherited = scripts.index("Inherited") orelse fatal("Scripts.txt: no Inherited script", .{});

    var transparent = try propertySet(gpa, "emoji-data.txt", emoji_data, "Emoji_Modifier");
    for (scripts.of_cp, 0..) |sc, cp| {
        if (sc == inherited) transparent.set(cp);
    }

    var join_scripts: [256]bool = @splat(false);
    var join_context = try newSet(gpa);
    {
        var recs: Records = .init(joining);
        while (recs.next()) |f| {
            if (f.len < 2 or f[1].len != 1 or std.mem.indexOfScalar(u8, "DLRC", f[1][0]) == null) continue;
            const r = parseRangeOrDie("DerivedJoiningType.txt", recs.line_no, f[0]);
            addRange(&join_context, r);
            for (scripts.of_cp[r[0] .. @as(usize, r[1]) + 1]) |sc| join_scripts[sc] = true;
        }
    }
    {
        var recs: Records = .init(ccc);
        while (recs.next()) |f| {
            if (f.len < 2 or !std.mem.eql(u8, f[1], "9")) continue;
            const r = parseRangeOrDie("DerivedCombiningClass.txt", recs.line_no, f[0]);
            for (scripts.of_cp[r[0] .. @as(usize, r[1]) + 1]) |sc| join_scripts[sc] = true;
        }
    }
    join_scripts[0] = false;
    join_scripts[inherited] = false;
    if (scripts.index("Common")) |common| join_scripts[common] = false;
    for (scripts.of_cp, 0..) |sc, cp| {
        if (join_scripts[sc]) join_context.set(cp);
    }
    subtract(&join_context, di);

    var strong_rtl = try propertySet(gpa, "DerivedBidiClass.txt", bidi, "R");
    var al = try propertySet(gpa, "DerivedBidiClass.txt", bidi, "AL");
    strong_rtl.setUnion(al);
    al.deinit(gpa);
    subtract(&strong_rtl, di);

    var pairs: std.ArrayList(u32) = .empty;
    try addPairs(gpa, &pairs, "StandardizedVariants.txt", std_variants);
    try addPairs(gpa, &pairs, "emoji-variation-sequences.txt", emoji_vs);

    return .{
        .unicode_version = version,
        .extended_pictographic = try toRanges(gpa, ext_pict),
        .transparent = try toRanges(gpa, transparent),
        .join_context = try toRanges(gpa, join_context),
        .strong_rtl = try toRanges(gpa, strong_rtl),
        .unified_ideograph = try toRanges(gpa, unified),
        .default_ignorable = try toRanges(gpa, di),
        .variation_pairs = sortUnique(pairs.items),
    };
}

fn writeOutput(gpa: Allocator, io: Io, path: []const u8, comptime writeFn: anytype, arg: anytype) void {
    var aw: Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeFn(&aw.writer, arg) catch |err| fatal("{s}: {t}", .{ path, err });
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch |err|
        fatal("{s}: {t}", .{ path, err });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // 表の構築で確保するものは終了まで保持するので、すべて arena に置く。
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 4) fatal("usage: gen_tables <ucd-dir> <tables-out> <emoji-fixture-out>", .{});

    var dir = Io.Dir.cwd().openDir(io, args[1], .{}) catch |err| fatal("{s}: {t}", .{ args[1], err });
    defer dir.close(io);
    const ucd: Ucd = .{ .io = io, .dir = dir, .arena = arena };

    const tables = generate(arena, ucd) catch |err| fatal("{t}", .{err});
    writeOutput(arena, io, args[2], writeTables, tables);
    writeOutput(arena, io, args[3], writeEmojiFixture, ucd.read("emoji-test.txt"));
}

const testing = std.testing;

test "splitFields skips comments and blank lines" {
    var buf: [max_fields][]const u8 = undefined;
    try testing.expect(splitFields("", &buf) == null);
    try testing.expect(splitFields("   \r", &buf) == null);
    try testing.expect(splitFields("# 0041 ; X", &buf) == null);
    const f = splitFields("0041..005A    ; L # L&  [26] LATIN", &buf).?;
    try testing.expectEqual(@as(usize, 2), f.len);
    try testing.expectEqualStrings("0041..005A", f[0]);
    try testing.expectEqualStrings("L", f[1]);
    const g = splitFields("0023 FE0E  ; text style;  # (1.1) NUMBER SIGN\r", &buf).?;
    try testing.expectEqual(@as(usize, 3), g.len);
    try testing.expectEqualStrings("0023 FE0E", g[0]);
    try testing.expectEqualStrings("text style", g[1]);
    try testing.expectEqualStrings("", g[2]);
}

test "Records counts lines" {
    var recs: Records = .init("# header\n\n0041 ; A\n# x\n0042..0043 ; B\n");
    try testing.expectEqualStrings("A", recs.next().?[1]);
    try testing.expectEqual(@as(usize, 3), recs.line_no);
    try testing.expectEqualStrings("B", recs.next().?[1]);
    try testing.expectEqual(@as(usize, 5), recs.line_no);
    try testing.expect(recs.next() == null);
}

test "parseRange accepts single values and ranges" {
    try testing.expectEqual(Range{ 0x41, 0x41 }, try parseRange("0041"));
    try testing.expectEqual(Range{ 0x1F3FB, 0x1F3FF }, try parseRange("1F3FB..1F3FF"));
    try testing.expectEqual(Range{ 0, 0x10FFFF }, try parseRange("0000..10FFFF"));
    try testing.expectError(error.InvalidRange, parseRange("0042..0041"));
    try testing.expectError(error.InvalidCodePoint, parseRange("110000"));
    try testing.expectError(error.InvalidCodePoint, parseRange("41"));
    try testing.expectError(error.InvalidCodePoint, parseRange("00G1"));
    try testing.expectError(error.InvalidCodePoint, parseRange("0041.."));
}

test "parseSequence" {
    var buf: [4]u21 = undefined;
    try testing.expectEqualSlices(u21, &.{ 0x1F469, 0x200D, 0x1F4BB }, try parseSequence("1F469 200D  1F4BB", &buf));
    try testing.expectError(error.EmptySequence, parseSequence("  ", &buf));
    try testing.expectError(error.SequenceTooLong, parseSequence("0041 0041 0041 0041 0041", &buf));
}

test "fileVersion" {
    try testing.expectEqualStrings("18.0.0", fileVersion("# Scripts-18.0.0.txt\n# Date", "Scripts").?);
    try testing.expectEqualStrings("18.0.0", fileVersion("# PropList-18.0.0.txt\r\n", "PropList").?);
    try testing.expect(fileVersion("# emoji-data.txt\n", "emoji-data") == null);
    try testing.expect(fileVersion("# PropList-18.0.0.txt\n", "Scripts") == null);
    try testing.expect(fileVersion("Scripts-18.0.0.txt\n", "Scripts") == null);
}

test "vsIndex" {
    try testing.expectEqual(@as(?u5, 0), vsIndex(0xFE00));
    try testing.expectEqual(@as(?u5, 15), vsIndex(0xFE0F));
    try testing.expectEqual(@as(?u5, 16), vsIndex(0x180B));
    try testing.expectEqual(@as(?u5, 18), vsIndex(0x180D));
    try testing.expectEqual(@as(?u5, 19), vsIndex(0x180F));
    try testing.expectEqual(@as(?u5, null), vsIndex(0x180E));
    try testing.expectEqual(@as(?u5, null), vsIndex(0xE0100));
}

test "toRanges merges adjacent ranges and subtract removes points" {
    const gpa = testing.allocator;
    var set = try newSet(gpa);
    defer set.deinit(gpa);
    addRange(&set, .{ 0x10, 0x1F });
    addRange(&set, .{ 0x20, 0x22 });
    addRange(&set, .{ 0x21, 0x30 });
    addRange(&set, .{ 0x40, 0x40 });
    addRange(&set, .{ 0x10FFFE, 0x10FFFF });

    var cut = try newSet(gpa);
    defer cut.deinit(gpa);
    addRange(&cut, .{ 0x18, 0x19 });
    addRange(&cut, .{ 0x40, 0x41 });
    subtract(&set, cut);

    const ranges = try toRanges(gpa, set);
    defer gpa.free(ranges);
    try testing.expectEqualSlices(Range, &.{
        .{ 0x10, 0x17 },
        .{ 0x1A, 0x30 },
        .{ 0x10FFFE, 0x10FFFF },
    }, ranges);
}

test "sortUnique" {
    var items = [_]u32{ 5, 1, 3, 1, 5, 2 };
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3, 5 }, sortUnique(&items));
}

test "writeTables output" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeTables(&aw.writer, .{
        .unicode_version = "1.2.3",
        .extended_pictographic = &.{.{ 0xA9, 0xA9 }},
        .transparent = &.{},
        .join_context = &.{},
        .strong_rtl = &.{.{ 0x10800, 0x10FFF }},
        .unified_ideograph = &.{},
        .default_ignorable = &.{},
        .variation_pairs = &.{(0x2764 << 5) | 15},
    });
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "pub const unicode_version = \"1.2.3\";\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const extended_pictographic = [_]Range{\n    .{ 0x00A9, 0x00A9 },\n};\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    .{ 0x10800, 0x10FFF },\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const variation_pairs = [_]u32{\n    0x004EC8F,\n};\n") != null);
}

test "writeEmojiFixture" {
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeEmojiFixture(&aw.writer,
        \\# group: Smileys
        \\
        \\1F600                                                  ; fully-qualified     # 😀 E1.0 grinning face
        \\263A                                                   ; unqualified         # ☺ E0.6 smiling face
        \\1F469 200D 1F4BB                                       ; fully-qualified     # 👩‍💻 E4.0 woman technologist
        \\
        \\#EOF
        \\
    );
    try testing.expectEqualStrings("\u{1F600}\n\u{263A}\n\u{1F469}\u{200D}\u{1F4BB}\n", aw.written());
}
