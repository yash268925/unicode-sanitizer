---
name: cli-behavior
description: usan の CLI の振る舞い(オプション、エラー表示、終了コード、検査モード)の正本。CLI のオプションやエラー処理、終了コードを変えるとき、src/main.zig を変えるときに使う。
---

# usan の CLI の振る舞い

- 使い方: `usan [OPTION]... [FILE]...`。FILE が無いか `-` なら stdin。複数 FILE は順に処理して連結出力する(cat と同じ)。
- オプション:
  - `-s` / `--scan-only`: 検査モード。stdout に何も出さない。入力の全体を最後まで処理し、除去(filter-rules skill の段階 1・段階 2 のいずれか)または U+FFFD への置換が 1 件でも起きたかを終了コードで返す。
  - `-h` / `--help`: 使い方を stdout に出して終了コード 0。
  - `-V` / `--version`: ツールの版(build.zig.zon の `.version`)と UCD の版(`ucd_tables.unicode_version`)を stdout に出して終了コード 0。
  - `--`: 以降の引数をすべてファイル名として扱う。
  - オプションは FILE の後に置いてもよい(`usan a.txt -s` は検査モードになる)。
  - 短いオプションはまとめて書けない(`-sh` は不明なオプションとして扱う)。
  - それ以外の `-` で始まる引数(`-` 単独を除く)は `usan: unrecognized option '<引数>'` と使い方を stderr に出して終了コード 2。
- 終了コード(diff と同じ体系。1 は検査モードでしか使わない):

| コード | 通常(フィルタ)モード | 検査モード |
|---|---|---|
| 0 | 正常終了(除去の有無によらない) | 除去・置換が 1 件も無かった |
| 1 | 使わない | 除去・置換が 1 件以上あった |
| 2 | I/O エラーまたは使い方の誤り | I/O エラーまたは使い方の誤り(1 より優先) |

- 読めないファイルは `usan: <path>: <エラー名>`(例: `usan: x.txt: FileNotFound`)を stderr に出して次の入力へ進み、最後に終了コード 2。
- stdout の書き込み失敗: 原因が `error.BrokenPipe`(`usan big.txt | head` など)なら何も出さず終了コード 0(ただし、それまでに読めない入力があれば 2)。それ以外は `usan: write error: <エラー名>` を出して終了コード 2。
- 引数の確保に失敗した(OutOfMemory など)ときは `usan: <エラー名>` を stderr に出して終了コード 2。
  main からエラーを返すと start コードが終了コード 1 にするため、main はエラーを返さず `std.process.exit` で終える。
- 検査モードでも全入力を最後まで処理する。stderr に出すのはエラーだけで、検出箇所は出さない。
  出力先は破棄用の Writer(`std.Io.Writer.Discarding`)にし、先頭 BOM の判定(filter-rules skill の P5)もフィルタモードと同じ基準で行う。
