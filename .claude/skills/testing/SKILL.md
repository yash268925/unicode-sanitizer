---
name: testing
description: usan のテスト方針(単体・性質・e2e テスト)、テストコーパスと期待値の作り方、Python の参照モデル。テストの追加、testdata/ の期待値の更新、規則変更や UCD 更新の結果の検算を行うときに使う。
---

# usan のテスト

## テスト方針

すべて `zig build test` で実行される。

1. **単体テスト**(各モジュールの `test` ブロック)
   - utf8: filter-rules skill の不正 UTF-8 表、全長(1-4 バイト)の正当例、境界値(U+007F/0080/07FF/0800/D7FF/E000/FFFF/10000/10FFFF)の往復、
     入力を 1 バイトずつ・任意位置で分割して与えても結果が同じこと。`replaced` フラグ。
   - props: 生成表が昇順・非重複(`variation_pairs` は狭義単調増加)であること、ext_pict・unified_ideograph・variation_pairs の基底が default_ignorable と交差しないこと(冪等性の前提)、代表点の判定。
   - filter: filter-rules skill の「振る舞いの例」の全行、P1-P8 各 1 例、C1-C8 の残す/除去の両方。`removed` フラグ。コーパスの各行。
   - gen_tables: UCD の行解析(コメント・空行・`..` 範囲・単一値)、レンジのマージ、集合の差、出力の書式。
2. **パイプラインの性質テスト**(clean.zig。乱数は固定シードの `std.Random.DefaultPrng`)
   ASCII・改行・各対象文字・絵文字・アラビア文字・ヘブライ文字・デーヴァナーガリー・ハングル字母・不正バイトから成るアルファベットでランダム入力を作り、次を確認する。
   - 冪等性: `clean(clean(x)) == clean(x)`。
   - チャンク不変性: 読み取りバッファを 1〜数バイトにしても結果が同じ。
   - 出力は正当な UTF-8 で、復号後の入力(不正部分を U+FFFD にしたもの)の部分列である。
   - `Result` が真であることと「出力 ≠ 入力」が一致する。
3. **e2e**(build.zig の `addE2eTests` で Run ステップとして登録する)
   - コーパスを stdin で/ファイル引数で与え `testdata/corpus.expected.txt` と一致。
   - `testdata/emoji-test-sequences.txt` を与え、入力と完全一致(RGI 絵文字が壊れない)。
   - 検査モード: コーパスで終了コード 1・stdout 空、`testdata/emoji-test-sequences.txt` で終了コード 0・stdout 空、不正 UTF-8 だけを含む入力で 1、存在しないファイルとの組み合わせで 2。`-s` と `--scan-only` の両方。
   - 存在しないファイルで終了コード 2、不正オプションで 2。読めないファイルの後も次の入力を処理する。
   - 先頭 BOM(`testdata/bom.txt` は `EF BB BF 61` の 4 バイト): 最初の入力では残り、前の入力が何かを出力した後の入力では消える。前の入力が空・読めない場合は残る。検査モードでも同じ基準で判定する。

## コーパスと期待値

`testdata/corpus.txt` は 17 行で、各行の先頭 2 文字がケース番号である。各行の不可視文字(U+ 表記):
01 `200D` / 02 `200C` / 03 `200B` / 04 `2060` / 05 `00AD` / 06 `202E 202C` / 07 `2067 2069` /
08 `E0048..E007F`(先行文字 `e`)/ 09 `E0020..E007F`(先行文字 `e`)/ 10 `2764 FE0F` / 11 `E0100`, `E0101`(先行 `A`, `B`)/
12 `1F469 200D 1F4BB`, `1F468 200D 1F469 200D 1F467` / 13 `1F469 1F3FD 200D 1F4BB` /
14 `1F3F4 E0067 E0062 E0065 E006E E0067 E007F` / 15 `0301` / 16 `FEFF`(行中)/ 17 `034F`。

01-09, 11, 16, 17 の 12 行だけが変化し、10, 12-15 は無変化である。

`testdata/corpus.expected.txt` は usan 自身では作らず、独立した手順で作る。
コーパスの各行のうち先頭 2 文字が `01`-`09`, `11`, `16`, `17` の行から
U+00AD, 034F, 200B-200D, 202A-202E, 2060, 2066-2069, FEFF, E0000-E007F, E0100-E01EF を削除し、他の行はそのまま書く(`python3 -I` の 1 回限りのコマンドなど)。
作り直したら、コーパスとの差分が 12 行であることを確かめる。

## 参照モデル

`reference_model.py`(この skill のディレクトリにある)は filter-rules skill の判定規則を行単位・非ストリーミングで書いた Python の簡易版である。正本は filter-rules skill で、ビルド・表生成の手順には使わない。
規則を変えたときや UCD の版を上げたときに、Zig 実装とは独立に結果を検算するために使う。

```sh
python3 -I .claude/skills/testing/reference_model.py <UCD_DIR> testdata/corpus.txt <UCD_DIR>/emoji-test.txt
```

UCD_DIR には ucd-tables skill の「入力ファイル」を平置きする(`.ucd/<version>/`)。
表のレンジ数、コーパスで変化した行、emoji-test.txt のうち変化したシーケンス数、各種用例(ペルシア語 ZWNJ、インド系の ZWJ、IVS、keycap、モンゴル FVS/MVS など)の結果を出力する。
UCD 18.0.0 では、コーパスは上記 12 行だけが変化し、emoji-test.txt の全 5244 シーケンスが無変化、用例はラテン文字の ZWNJ や情報埋め込みの例など除去すべきものだけが変化する。
規則を変えたら参照モデルも同じように直し、filter-rules skill・Zig 実装と一致させる。
