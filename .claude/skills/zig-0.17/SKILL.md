---
name: zig-0.17
description: Zig 0.17 の std や build システムの API の注意点(std.process.Init, std.Io の Reader/Writer, ファイル操作, build.zig, build.zig.zon)。usan の Zig のコードや build.zig, build.zig.zon を書くときに使う。
---

# Zig 0.17 の注意点

- エントリポイントは `pub fn main(init: std.process.Init)`。`init.io` が `std.Io`、`init.gpa` が汎用アロケータ、
  引数は `try init.minimal.args.toSlice(init.arena.allocator())`。
- stdout は **必ず** `std.Io.File.Writer.initStreaming(.stdout(), io, &buf)` で作る。
  `.init`(positional モード)では `>>` でリダイレクトした既存ファイルの先頭が上書きされる(データ破壊)。
  stdin とファイル入力も `std.Io.File.Reader.initStreaming(file, io, &buf)` でよい。
- 読み取りループは「`r.buffered()` を処理 → `r.toss(n)` → `r.fillMore()`(`error.EndOfStream` で終了)」の順にする。
  先に `fillMore()` を呼ぶと、`std.Io.Reader.fixed(...)` のように最初から全データがバッファにある Reader で、処理前に EndOfStream になる。
  `readSliceShort` はバッファが埋まるか EOF まで戻らないので、対話的なパイプで出力が遅れる。使わない。
- 書き込み失敗は `error.WriteFailed` として返り、原因は `File.Writer` の `err` フィールド(`?Error`)に入る。
  `| head` で閉じられると `error.BrokenPipe` になり、未処理だと `error: WriteFailed` が stderr に出て終了コード 1 になる。
- ファイルは `std.Io.Dir.cwd().openFile(io, path, .{})`、閉じるのは `file.close(io)`。
  ディレクトリは `Io.Dir.cwd().openDir(io, path, .{})` → `dir.close(io)`。ファイル全体の読み込みは `dir.readFileAlloc(io, name, gpa, .limited(n))`。
  書き出しは `Io.Dir.cwd().createFile(io, path, .{})` + `File.Writer.initStreaming`。
- 生成器で使っている API: `std.bit_set.DynamicBitSetUnmanaged.initEmpty(gpa, 0x110000)` / `setRangeValue(.{ .start, .end }, true)` / `isSet`、
  `std.ArrayList(T)` は `.empty` で初期化し `append(gpa, x)` / `deinit(gpa)`、`std.mem.sort(T, items, {}, lessThan)`、
  `std.fmt.parseInt(u21, s, 16)`、`std.mem.splitScalar` / `trim` / `indexOfScalar`、`print` の `{X:0>4}`。
- テストでは `var r: std.Io.Reader = .fixed(bytes);` と `var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);`(`&aw.writer`、`aw.written()`、`aw.deinit()`)が使える。
  検査モードの出力先は `std.Io.Writer.Discarding.init(&buf)` の `.writer`。
- `std.unicode.utf8Encode(c: u21, out: []u8) !u3` がある(サロゲートで error)。
- `print` の `{t}` でエラー名・enum タグ名を出せる。`std.process.exit(u8)`。
- build.zig: `b.addExecutable(.{ .name, .root_module = b.createModule(.{ ... }) })`、`b.addTest(.{ .root_module = ... })`、
  Run ステップの `setStdIn(.{ .lazy_path = b.path(...) })` / `setStdIn(.{ .bytes = ... })`、`addFileArg(b.path(...))`、
  `expectStdOutEqual(@embedFile("..."))`、`expectExitCode(u8)`。gen ステップの形は ucd-tables skill の「build.zig での組み方」。
- `@embedFile` はモジュールのディレクトリ外を読めない。テストからコーパスを読むために、build.zig はコーパスを包む .zig を生成して import させている。
- build.zig.zon: `.name` は enum リテラル(`.usan`)。`.fingerprint` は任意の値だとエラーになり、エラーメッセージが正しい値を提示する(`0x0` を入れて一度 `zig build` すると得られる)。`.minimum_zig_version = "0.17.0"`。
- 配列の反復 `[_]T{x} ** n` はコンパイルエラーになる。`@splat(x)` を使う。
- 二分探索は `std.sort.binarySearch` を使わず、自前の数行のループで書いている(API 変更に強くするため)。
