# usan

usan はテキストから不可視の文字や紛らわしい書式制御文字を取り除くフィルタである。Zig 0.17.0 で書かれ、判定に使う文字の性質は UCD から生成した表による。

開発用の情報(判定規則、CLI の振る舞い、テスト、表の生成、Zig の注意点)は下記の skill にある。作業に応じて呼び出す。

## skill

| skill | 呼び出す場面 |
|---|---|
| `filter-rules` | 除去規則を変えるとき。src/filter.zig, src/clean.zig, src/utf8.zig, src/props.zig を変えるとき |
| `cli-behavior` | オプション・エラー表示・終了コードを変えるとき。src/main.zig を変えるとき |
| `testing` | テストの追加、期待値の更新、規則変更や UCD 更新の検算(参照モデル `.claude/skills/testing/reference_model.py`)のとき |
| `ucd-tables` | 表の再生成、tools/gen_tables.zig の変更、Unicode の版の更新のとき |
| `zig-0.17` | Zig のコードや build.zig, build.zig.zon を書くとき |

`filter-rules`(判定規則)と `cli-behavior`(CLI の振る舞い)が usan の振る舞いの正本である。
規則・オプション・終了コードを変えるときは先にこれらを読み、変更後もこれらを正しく保つ。
コードやテストの期待値がこれと食い違う場合は、どちらが正しいかを確かめてから両方をそろえる。

README.md は利用者向けの要約である。規則や CLI を変えたら README の該当箇所もそろえる。

## モジュール構成

```
build.zig / build.zig.zon
src/main.zig         CLI。引数解析、入力ファイルの順次処理、エラー表示、終了コード
src/clean.zig        パイプライン。Io.Reader → utf8.Decoder → filter.Filter → Io.Writer
src/utf8.zig         ストリーミング UTF-8 デコーダ(maximal subpart ごとの U+FFFD 置換)と 1 文字のエンコード
src/filter.zig       段階 1 + 段階 2 の状態機械。I/O に依存しない
src/props.zig        生成表に対する判定関数
src/ucd_tables.zig   生成物(リポジトリに含める。手で編集しない)
tools/gen_tables.zig UCD → src/ucd_tables.zig と testdata/emoji-test-sequences.txt を生成(zig build gen で実行)
tools/fetch_ucd.sh   指定バージョンの UCD ファイル群を .ucd/<version>/ に curl で取得する補助(生成の必須手順ではない)
testdata/            e2e 用の期待値ファイル等
testdata/corpus.txt  テストコーパス(build.zig から参照する。複製しない)
LICENSES/Unicode-3.0.txt    UCD 由来の表のための Unicode License V3
```

役割の分担:

- `utf8.Decoder`: `feed(bytes, sink)` で 1 文字ごとに `sink.emit(cp)` を呼ぶ。`finish(sink)` で EOF 時の未完分を処理する。内部状態は数バイト。
  U+FFFD への置換を 1 回でも行ったかを `replaced: bool` で保持する。
- `filter.Filter`: `init(.{ .keep_leading_bom = bool })`、`push(cp, w)`、`finish(w)`。O(1) メモリ。1 文字でも捨てたら `removed` が真になる。内部の組み方は filter-rules skill の「状態機械(filter.zig)の組み方」。
- `clean.run(r, w, opts) !Result`: 1 入力を最後まで処理し、チャンクごとに `w.flush()` する(対話的なパイプで出力を遅らせないため)。
  入力終了時に `Decoder.finish` → `Filter.finish` の順に呼ぶ。`Result.changed` は `Decoder.replaced or Filter.removed` で、検査モードの判定に使う。
- `props`: `isExtPict`, `isTransparent`, `isJoinContext`, `isStrongRtl`, `isUnifiedIdeograph`, `isDefaultIgnorable`, `hasVariation(base, vs)`。
- `main`: 入力ごとに Filter を作り直す。stdout への出力が 0 バイトのときだけ `keep_leading_bom` を真にする。

## コマンド

```sh
zig build                          # zig-out/bin/usan
zig build -Doptimize=ReleaseSmall  # 小さいリリースビルド
zig build test                     # 単体テスト、生成器のテスト、e2e テスト
zig fmt --check build.zig src tools
zig build gen -Ducd=.ucd/18.0.0    # 表の再生成(ucd-tables skill)
```

ReleaseSmall + strip のバイナリは 300 KB 未満を目安とする(空の main で約 50 KB、`std.process.Init` とファイル I/O で約 180 KB、表を足して 250 KB 程度)。
