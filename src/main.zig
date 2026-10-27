const std = @import("std");
const Io = std.Io;
const File = Io.File;
const build_options = @import("build_options");
const clean = @import("clean.zig");
const ucd_tables = @import("ucd_tables.zig");

const usage =
    \\Usage: usan [OPTION]... [FILE]...
    \\Remove invisible and deceptive Unicode characters from FILE(s) and write to stdout.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -s, --scan-only  write nothing; report through the exit status
    \\                   whether anything would be removed or replaced
    \\  -h, --help       display this help and exit
    \\  -V, --version    output version information and exit
    \\  --               treat all following arguments as FILE
    \\
    \\Exit status: 0 on success, 2 on I/O error or invalid usage.
    \\With --scan-only: 0 if nothing was found, 1 if something was found,
    \\2 on I/O error or invalid usage.
    \\
;

const Config = struct {
    paths: []const []const u8,
    scan_only: bool,
};

const Command = union(enum) {
    help,
    version,
    bad_option: []const u8,
    run: Config,
};

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) !Command {
    var paths: std.ArrayList([]const u8) = .empty;
    var only_paths = false;
    var scan_only = false;
    for (args) |arg| {
        if (only_paths or arg.len < 2 or arg[0] != '-') {
            try paths.append(arena, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            only_paths = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--scan-only")) {
            scan_only = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            return .version;
        } else {
            return .{ .bad_option = arg };
        }
    }
    if (paths.items.len == 0) try paths.append(arena, "-");
    return .{ .run = .{ .paths = paths.items, .scan_only = scan_only } };
}

pub fn main(init: std.process.Init) void {
    const io = init.io;
    const arena = init.arena.allocator();

    var err_buf: [1024]u8 = undefined;
    var stderr_writer: File.Writer = .initStreaming(.stderr(), io, &err_buf);
    const stderr = &stderr_writer.interface;
    // .init(positional モード)だと >> でリダイレクトした既存ファイルの先頭を上書きする。
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_writer: File.Writer = .initStreaming(.stdout(), io, &out_buf);

    // main からエラーを返すと start コードが終了コード 1 にするが、1 は検査モードの「検出あり」専用である。
    const args = init.minimal.args.toSlice(arena) catch |err| fatal(stderr, err);
    const command = parseArgs(arena, args[1..]) catch |err| fatal(stderr, err);
    const status: u8 = switch (command) {
        .help => writeOut(&stdout_writer, stderr, usage, .{}),
        .version => writeOut(&stdout_writer, stderr, "usan {s} (Unicode {s})\n", .{
            build_options.version,
            ucd_tables.unicode_version,
        }),
        .bad_option => |arg| blk: {
            stderr.print("usan: unrecognized option '{s}'\n" ++ usage, .{arg}) catch {};
            break :blk 2;
        },
        .run => |config| if (config.scan_only)
            runScan(io, config, stderr)
        else
            runFilter(io, config, &stdout_writer, stderr),
    };
    stderr.flush() catch {};
    std.process.exit(status);
}

fn fatal(stderr: *Io.Writer, err: anyerror) noreturn {
    stderr.print("usan: {t}\n", .{err}) catch {};
    stderr.flush() catch {};
    std.process.exit(2);
}

fn writeOut(out: *File.Writer, stderr: *Io.Writer, comptime fmt: []const u8, args: anytype) u8 {
    out.interface.print(fmt, args) catch return writeFailed(out, stderr);
    out.interface.flush() catch return writeFailed(out, stderr);
    return 0;
}

/// 下流が先に閉じた(`| head` など)のは正常な終わり方として扱う。
fn writeFailed(out: *File.Writer, stderr: *Io.Writer) u8 {
    const err: anyerror = out.err orelse error.WriteFailed;
    if (err == error.BrokenPipe) return 0;
    stderr.print("usan: write error: {t}\n", .{err}) catch {};
    return 2;
}

fn runFilter(io: Io, config: Config, out: *File.Writer, stderr: *Io.Writer) u8 {
    var status: u8 = 0;
    for (config.paths) |path| {
        // P5: 先頭の BOM を残すのは、まだ何も出力していないときだけ。
        // initStreaming なので logicalPos はファイル上の位置ではなく、この Writer が書いたバイト数である。
        const opts: clean.Options = .{ .keep_leading_bom = out.logicalPos() == 0 };
        _ = filterOne(io, path, opts, &out.interface, stderr) catch |err| switch (err) {
            // BrokenPipe でも、それまでの入力エラーの 2 は残す。
            error.WriteFailed => return @max(status, writeFailed(out, stderr)),
            error.InputFailed => status = 2,
        };
    }
    return status;
}

fn runScan(io: Io, config: Config, stderr: *Io.Writer) u8 {
    var discard_buf: [4096]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&discard_buf);
    var found = false;
    var input_failed = false;
    for (config.paths) |path| {
        const opts: clean.Options = .{ .keep_leading_bom = discarding.fullCount() == 0 };
        const result = filterOne(io, path, opts, &discarding.writer, stderr) catch |err| switch (err) {
            error.WriteFailed => unreachable, // Discarding は書き込みに失敗しない。
            error.InputFailed => {
                input_failed = true;
                continue;
            },
        };
        if (result.changed) found = true;
    }
    if (input_failed) return 2;
    return @intFromBool(found);
}

fn filterOne(io: Io, path: []const u8, opts: clean.Options, out: *Io.Writer, stderr: *Io.Writer) error{ WriteFailed, InputFailed }!clean.Result {
    const is_stdin = std.mem.eql(u8, path, "-");
    const file: File = if (is_stdin) .stdin() else Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        stderr.print("usan: {s}: {t}\n", .{ path, err }) catch {};
        return error.InputFailed;
    };
    defer if (!is_stdin) file.close(io);

    var in_buf: [64 * 1024]u8 = undefined;
    var reader: File.Reader = .initStreaming(file, io, &in_buf);
    return clean.run(&reader.interface, out, opts) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        // clean.run は EndOfStream を内部で終端として扱うので、型の上でだけ現れる。
        error.EndOfStream => unreachable,
        error.ReadFailed => {
            const cause: anyerror = reader.err orelse error.ReadFailed;
            stderr.print("usan: {s}: {t}\n", .{ path, cause }) catch {};
            return error.InputFailed;
        },
    };
}

test {
    _ = @import("clean.zig");
    _ = @import("filter.zig");
    _ = @import("props.zig");
    _ = @import("utf8.zig");
}
