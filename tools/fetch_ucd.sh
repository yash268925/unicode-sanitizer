#!/bin/sh
# 指定バージョンの UCD ファイル群を .ucd/<version>/ に平置きで取得する。
# 表の生成(zig build gen -Ducd=.ucd/<version>)の任意の補助であり、取得物はデータとしてのみ扱う。
set -eu

if [ $# -ne 1 ]; then
    echo "usage: $0 <unicode-version>   (e.g. $0 18.0.0)" >&2
    exit 2
fi

version=$1
base="https://www.unicode.org/Public/$version"
root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/.ucd/$version"
mkdir -p "$dest"

for path in \
    ucd/emoji/emoji-data.txt \
    ucd/emoji/emoji-variation-sequences.txt \
    ucd/StandardizedVariants.txt \
    ucd/Scripts.txt \
    ucd/PropList.txt \
    ucd/DerivedCoreProperties.txt \
    ucd/extracted/DerivedJoiningType.txt \
    ucd/extracted/DerivedCombiningClass.txt \
    ucd/extracted/DerivedBidiClass.txt \
    emoji/emoji-test.txt; do
    name=${path##*/}
    # 失敗時に途中までのファイルが完成品に見えて残らないよう、一時名で受けてから置き換える。
    curl --fail --silent --show-error --location --proto '=https' \
        --output "$dest/$name.part" "$base/$path"
    mv "$dest/$name.part" "$dest/$name"
done
