---
name: ucd-tables
description: usan の UCD 由来の表(src/ucd_tables.zig, testdata/emoji-test-sequences.txt)の生成器の仕様と、Unicode の版を更新する手順。表の再生成、tools/gen_tables.zig や build.zig の gen ステップの変更、Unicode の版の更新を行うときに使う。
---

# UCD 由来の表の生成と Unicode の更新

## 方式

Zig 製の生成器 `tools/gen_tables.zig` を `zig build gen -Ducd=<dir>` で実行し、生成物 `src/ucd_tables.zig` と `testdata/emoji-test-sequences.txt` をリポジトリに含める。通常のビルドでは生成しない。
どちらも手で編集しない。

理由: 通常のビルドにネットワークも UCD 原本(計 2 MB 強)も不要になり、Unicode 更新時の差分が生成物の diff としてレビューできる。
生成器を Zig で書くことで、ビルド・生成に必要なツールが Zig だけになる。ビルド・生成の必須手順に Python を含めない。
生成器自身はダウンロードしない。UCD ファイルはローカルに取得済みであることを前提とする。
生成器が Zig の std 変更で壊れたことに気づけるよう、生成器の単体テストは `-Ducd` の有無によらず通常の `zig build test` に含める。

## 入力ファイル

`https://www.unicode.org/Public/<version>/` 配下の 10 ファイル:

| ファイル | 使う内容 |
|---|---|
| `ucd/emoji/emoji-data.txt` | Extended_Pictographic, Emoji_Modifier |
| `ucd/emoji/emoji-variation-sequences.txt` | 絵文字の (基底, FE0E/FE0F) |
| `ucd/StandardizedVariants.txt` | (基底, FE00-FE0F / 180B-180D / 180F)。第 3 欄の文脈は無視し、組を重複排除する |
| `ucd/Scripts.txt` | Script(Inherited と、join_context の Script 群) |
| `ucd/PropList.txt` | Unified_Ideograph |
| `ucd/DerivedCoreProperties.txt` | Default_Ignorable_Code_Point |
| `ucd/extracted/DerivedJoiningType.txt` | Joining_Type |
| `ucd/extracted/DerivedCombiningClass.txt` | ccc=9 |
| `ucd/extracted/DerivedBidiClass.txt` | Bidi_Class R/AL(明示行のみ。`@missing` の既定値は使わない) |
| `emoji/emoji-test.txt` | テスト用の絵文字フィクスチャ |

18.0.0 から emoji データは `Public/<version>/emoji/` にある(旧来の `Public/emoji/<major>.<minor>/` は 404)。
`emoji-data.txt` と `emoji-variation-sequences.txt` は `Public/<version>/ucd/emoji/` にある。

生成器は `-Ducd` で渡されたディレクトリの直下にこれら 10 ファイルが平置きで並んでいる前提で読む(サブディレクトリ構造は持たない)。

## 生成器の処理

- 生成器の引数は「UCD ディレクトリ、出力 1(表)、出力 2(絵文字フィクスチャ)」の 3 つ。
- 解析: 行の `#` 以降を捨て、`;` で分割し、各欄を trim する。第 1 欄は `XXXX` か `XXXX..YYYY`。
  StandardizedVariants と emoji-variation-sequences は第 1 欄が空白区切りの 2 コードポイント。
- 集合はコードポイント全域(0x110000)のビット集合で持ち、和・差を取ってから昇順にレンジ化する。Script は全域の配列(Script 番号)で持つ。
- 各集合の定義は filter-rules skill の「用語」による。
  - join_context は「Script 集合を導出 → その Script の全レンジ ∪ 個々の Joining_Type D/L/R/C 文字 → Default_Ignorable を差し引く」の順で作る。
  - strong_rtl は DerivedBidiClass.txt の第 2 欄が `R` か `AL` の明示行から作り、Default_Ignorable を差し引く。
- `testdata/emoji-test-sequences.txt`: `emoji-test.txt` のデータ行(`;` を含む非コメント行)の第 1 欄を文字列にして 1 行 1 シーケンスで書く。全ステータス(fully/minimally/unqualified/component)を含める。末尾は改行。
- 成功時に stderr へ何も出さない。stderr に出力があると、build runner は成功時でも `failed command: ...` という行を添えて表示し、紛らわしい。

## 生成物 `src/ucd_tables.zig` の形

```zig
pub const unicode_version = "18.0.0";
pub const Range = [2]u21; // 閉区間 [lo, hi]
pub const extended_pictographic = [_]Range{ ... };
pub const transparent = [_]Range{ ... };
pub const join_context = [_]Range{ ... };
pub const strong_rtl = [_]Range{ ... };
pub const unified_ideograph = [_]Range{ ... };
pub const default_ignorable = [_]Range{ ... };
pub const variation_pairs = [_]u32{ ... }; // (base << 5) | vs_index の昇順
```

- 各 Range 配列は昇順・非重複・隣接マージ済み。props.zig は自前の二分探索で引く。
- vs_index: FE00..FE0F → 0..15、180B..180D → 16..18、180F → 19。props の `hasVariation` は VS でない引数に false を返す。
- `unicode_version` は `Scripts.txt` の先頭行(`# Scripts-18.0.0.txt`)から取る。先頭行に版を持つ他の 6 ファイル(`PropList`, `DerivedCoreProperties`, `StandardizedVariants`, `DerivedJoiningType`, `DerivedCombiningClass`, `DerivedBidiClass`)の版がこれと一致しなければ失敗する(版の混在を防ぐ)。
  emoji 系 3 ファイルは先頭行に版を持たない(`# emoji-data.txt`)ので検査しない。
- 先頭コメントに UCD バージョン、生成コマンド、「生成物のため手で編集しない」、Unicode License V3(`LICENSES/Unicode-3.0.txt`。`https://www.unicode.org/license.txt` の本文)への参照を書く。
- `zig fmt --check` を通る書式で出力する。

UCD 18.0.0 での規模(マージ後のレンジ数): Extended_Pictographic 156、transparent 32、join_context 354、strong_rtl 138、Unified_Ideograph 16、Default_Ignorable_Code_Point 17、variation_pairs 2179 組。表全体で約 14 KB。
`testdata/emoji-test-sequences.txt` は 5244 行。版を上げたらこれらの数の変化を差分レビューの目安にする。

## build.zig での組み方

```zig
const gen_step = b.step("gen", "Regenerate src/ucd_tables.zig from UCD (-Ducd=DIR)");
if (b.option([]const u8, "ucd", "UCD directory")) |dir| {
    const run = b.addRunArtifact(gen_exe); // gen_exe は .target = b.graph.host でビルド
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
```

`-Ducd` は `zig build` を実行したカレントディレクトリからの相対パスか絶対パス。`-Ducd` が無ければ gen ステップはメッセージを出して失敗する。

## Unicode の更新手順

1. 新しい版の UCD ファイルを `.ucd/<version>/` に取得する(`.ucd/` は .gitignore 済み)。補助スクリプトを使うか、上記 10 ファイルを平置きで手で置く。

   ```sh
   tools/fetch_ucd.sh 18.0.0
   ```

   `fetch_ucd.sh` は HTTP 失敗時に非 0 で終了し、途中までのファイルを完成品として残さない。取得物は信頼しない入力として扱い、実行しない。

2. 表を再生成する。UCD ファイルの版が混在していると失敗する。

   ```sh
   zig build gen -Ducd=.ucd/18.0.0
   ```

3. `zig build test` を通す。生成物の差分(`src/ucd_tables.zig`)をレビューしてからコミットする。
   再度 `zig build gen` を実行しても差分が出ないこと(出力は決定的である)。キャッシュを使わない再実行は `--cache-dir` に新しいディレクトリを渡すと確かめられる。
   `zig fmt --check src/ucd_tables.zig tools` も通ること。

4. 版を上げると規則の前提が崩れていないかも確かめる。
   - ext_pict・Unified_Ideograph・variation_pairs の基底が Default_Ignorable と交差しないこと(props.zig のテストで検査される)。
   - 新しい IVD の全シーケンスの基底が Unified_Ideograph で、使用 VS が E0100..E01EF に収まること(filter-rules skill の C3)。
   - `.claude/skills/testing/reference_model.py` で生成器の出力を検算し、コーパスと emoji-test.txt の結果が変わらないこと(testing skill の「参照モデル」)。
