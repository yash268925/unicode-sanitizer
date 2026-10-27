const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe_mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "usan",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const test_step = b.step("test", "Run unit tests");
    addE2eTests(b, test_step, exe);
    // @embedFile はモジュールのディレクトリ外を読めないため、コーパスを包む .zig を生成して import させる。
    const corpus_files = b.addWriteFiles();
    _ = corpus_files.addCopyFile(b.path("testdata/corpus.txt"), "corpus.txt");
    const corpus_zig = corpus_files.add("corpus.zig", "pub const text = @embedFile(\"corpus.txt\");\n");
    // exe のビルドがテスト用コーパスに依存しないよう、テストは別モジュールでビルドする。
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", build_options);
    test_mod.addAnonymousImport("corpus", .{ .root_source_file = corpus_zig });
    const exe_tests = b.addTest(.{ .root_module = test_mod });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    const gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/gen_tables.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const gen_tests = b.addTest(.{ .root_module = gen_mod });
    test_step.dependOn(&b.addRunArtifact(gen_tests).step);

    const gen_step = b.step("gen", "Regenerate src/ucd_tables.zig from UCD (-Ducd=DIR)");
    if (b.option([]const u8, "ucd", "UCD directory")) |dir| {
        const gen_exe = b.addExecutable(.{
            .name = "gen_tables",
            .root_module = gen_mod,
        });
        const run = b.addRunArtifact(gen_exe);
        run.addDirectoryArg(b.graph.cwdRelativePath(dir));
        const tables = run.addOutputFileArg("ucd_tables.zig");
        const fixture = run.addOutputFileArg("emoji-test-sequences.txt");
        const usf = b.addUpdateSourceFiles();
        usf.addCopyFileToSource(tables, "src/ucd_tables.zig");
        usf.addCopyFileToSource(fixture, "testdata/emoji-test-sequences.txt");
        gen_step.dependOn(&usf.step);
    } else {
        gen_step.dependOn(&b.addFail("zig build gen requires -Ducd=<UCD directory>").step);
    }
}

fn addE2eTests(b: *std.Build, test_step: *std.Build.Step, exe: *std.Build.Step.Compile) void {
    const corpus_expected = @embedFile("testdata/corpus.expected.txt");
    const emoji_sequences = @embedFile("testdata/emoji-test-sequences.txt");

    const corpus_stdin = b.addRunArtifact(exe);
    corpus_stdin.setName("e2e corpus via stdin");
    corpus_stdin.setStdIn(.{ .lazy_path = b.path("testdata/corpus.txt") });
    corpus_stdin.expectStdOutEqual(corpus_expected);
    test_step.dependOn(&corpus_stdin.step);

    const corpus_file = b.addRunArtifact(exe);
    corpus_file.setName("e2e corpus via file argument");
    corpus_file.addFileArg(b.path("testdata/corpus.txt"));
    corpus_file.expectStdOutEqual(corpus_expected);
    test_step.dependOn(&corpus_file.step);

    const emoji = b.addRunArtifact(exe);
    emoji.setName("e2e RGI emoji unchanged");
    emoji.addFileArg(b.path("testdata/emoji-test-sequences.txt"));
    emoji.expectStdOutEqual(emoji_sequences);
    test_step.dependOn(&emoji.step);

    const missing = b.addRunArtifact(exe);
    missing.setName("e2e missing file");
    missing.addArg("testdata/no-such-file");
    missing.expectExitCode(2);
    missing.expectStdErrEqual("usan: testdata/no-such-file: FileNotFound\n");
    test_step.dependOn(&missing.step);

    const missing_then_next = b.addRunArtifact(exe);
    missing_then_next.setName("e2e missing file then next input");
    missing_then_next.addArg("testdata/no-such-file");
    missing_then_next.addFileArg(b.path("testdata/emoji-test-sequences.txt"));
    missing_then_next.expectExitCode(2);
    missing_then_next.expectStdOutEqual(emoji_sequences);
    missing_then_next.expectStdErrEqual("usan: testdata/no-such-file: FileNotFound\n");
    test_step.dependOn(&missing_then_next.step);

    const bogus = b.addRunArtifact(exe);
    bogus.setName("e2e unknown option");
    bogus.addArg("--bogus");
    bogus.expectExitCode(2);
    bogus.expectStdErrMatch("usan: unrecognized option '--bogus'\n");
    test_step.dependOn(&bogus.step);

    const version = b.addRunArtifact(exe);
    version.setName("e2e --version");
    version.addArg("--version");
    version.expectExitCode(0);
    test_step.dependOn(&version.step);

    const bom_stdin = b.addRunArtifact(exe);
    bom_stdin.setName("e2e leading BOM kept");
    bom_stdin.setStdIn(.{ .bytes = "\u{FEFF}a" });
    bom_stdin.expectStdOutEqual("\u{FEFF}a");
    test_step.dependOn(&bom_stdin.step);

    const bom_twice = b.addRunArtifact(exe);
    bom_twice.setName("e2e BOM of second input removed");
    bom_twice.addFileArg(b.path("testdata/bom.txt"));
    bom_twice.addFileArg(b.path("testdata/bom.txt"));
    bom_twice.expectStdOutEqual("\u{FEFF}aa");
    test_step.dependOn(&bom_twice.step);

    const bom_after_empty = b.addRunArtifact(exe);
    bom_after_empty.setName("e2e BOM after empty input kept");
    bom_after_empty.setStdIn(.{ .bytes = "" });
    bom_after_empty.addArg("-");
    bom_after_empty.addFileArg(b.path("testdata/bom.txt"));
    bom_after_empty.expectStdOutEqual("\u{FEFF}a");
    test_step.dependOn(&bom_after_empty.step);

    const bom_after_missing = b.addRunArtifact(exe);
    bom_after_missing.setName("e2e BOM after missing file kept");
    bom_after_missing.addArg("testdata/no-such-file");
    bom_after_missing.addFileArg(b.path("testdata/bom.txt"));
    bom_after_missing.expectExitCode(2);
    bom_after_missing.expectStdOutEqual("\u{FEFF}a");
    bom_after_missing.expectStdErrEqual("usan: testdata/no-such-file: FileNotFound\n");
    test_step.dependOn(&bom_after_missing.step);

    for ([_][]const u8{ "-s", "--scan-only" }) |flag| {
        const scan_corpus = b.addRunArtifact(exe);
        scan_corpus.setName(b.fmt("e2e {s} corpus found", .{flag}));
        scan_corpus.addArg(flag);
        scan_corpus.setStdIn(.{ .lazy_path = b.path("testdata/corpus.txt") });
        scan_corpus.expectExitCode(1);
        scan_corpus.expectStdOutEqual("");
        test_step.dependOn(&scan_corpus.step);

        const scan_emoji = b.addRunArtifact(exe);
        scan_emoji.setName(b.fmt("e2e {s} RGI emoji clean", .{flag}));
        scan_emoji.addArg(flag);
        scan_emoji.addFileArg(b.path("testdata/emoji-test-sequences.txt"));
        scan_emoji.expectExitCode(0);
        scan_emoji.expectStdOutEqual("");
        test_step.dependOn(&scan_emoji.step);

        const scan_invalid = b.addRunArtifact(exe);
        scan_invalid.setName(b.fmt("e2e {s} invalid UTF-8 found", .{flag}));
        scan_invalid.addArg(flag);
        scan_invalid.setStdIn(.{ .bytes = "a\xffb" });
        scan_invalid.expectExitCode(1);
        scan_invalid.expectStdOutEqual("");
        test_step.dependOn(&scan_invalid.step);

        const scan_missing = b.addRunArtifact(exe);
        scan_missing.setName(b.fmt("e2e {s} missing file wins over found", .{flag}));
        scan_missing.addArg(flag);
        scan_missing.addArg("testdata/no-such-file");
        scan_missing.addFileArg(b.path("testdata/corpus.txt"));
        scan_missing.expectExitCode(2);
        scan_missing.expectStdOutEqual("");
        scan_missing.expectStdErrEqual("usan: testdata/no-such-file: FileNotFound\n");
        test_step.dependOn(&scan_missing.step);

        const scan_bom = b.addRunArtifact(exe);
        scan_bom.setName(b.fmt("e2e {s} leading BOM clean", .{flag}));
        scan_bom.addArg(flag);
        scan_bom.addFileArg(b.path("testdata/bom.txt"));
        scan_bom.expectExitCode(0);
        test_step.dependOn(&scan_bom.step);

        const scan_bom_twice = b.addRunArtifact(exe);
        scan_bom_twice.setName(b.fmt("e2e {s} BOM of second input found", .{flag}));
        scan_bom_twice.addArg(flag);
        scan_bom_twice.addFileArg(b.path("testdata/bom.txt"));
        scan_bom_twice.addFileArg(b.path("testdata/bom.txt"));
        scan_bom_twice.expectExitCode(1);
        test_step.dependOn(&scan_bom_twice.step);

        const scan_bom_after_empty = b.addRunArtifact(exe);
        scan_bom_after_empty.setName(b.fmt("e2e {s} BOM after empty input clean", .{flag}));
        scan_bom_after_empty.addArg(flag);
        scan_bom_after_empty.setStdIn(.{ .bytes = "" });
        scan_bom_after_empty.addArg("-");
        scan_bom_after_empty.addFileArg(b.path("testdata/bom.txt"));
        scan_bom_after_empty.expectExitCode(0);
        test_step.dependOn(&scan_bom_after_empty.step);
    }
}
