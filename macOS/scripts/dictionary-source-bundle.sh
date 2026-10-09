#!/bin/bash
# Corresponding-source bundle for the compiled dictionary resources: the verified
# pinned upstream inputs (GPL-3.0 rime-frost, rime-ice and emoji data, LGPL-3.0
# rime-easy-en, Apache-2.0 rime-pinyin-simp), InkFlow's generation recipe as
# committed at HEAD, the license texts and the manifest of the generated dictionary.
#   dictionary-source-bundle.sh OUTPUT.tar.gz [BUILD]
set -euo pipefail
cd "$(dirname "$0")/../.."
output=${1:?Usage: dictionary-source-bundle.sh OUTPUT.tar.gz [BUILD]}
build=${2:-}
case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
[[ "$output" == *.tar.gz && ! -e "$output" ]] || { echo 'Output must be a new .tar.gz path.' >&2; exit 1; }
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
commit=$(git rev-parse HEAD)
revision=$commit
[[ -z $(git status --porcelain --untracked-files=normal) ]] || revision+=-dirty
license_for() {
  case "$1" in
    gaboolic/rime-frost) echo 'GPL-3.0 (LICENSES/rime-frost.txt)' ;;
    iDvel/rime-ice) echo 'GPL-3.0 (LICENSES/rime-ice.txt)' ;;
    rime/rime-pinyin-simp) echo 'Apache-2.0 (LICENSES/pinyin-simp.txt)' ;;
    *) echo "No license mapping for dictionary source repository $1; update dictionary-source-bundle.sh." >&2; exit 1 ;;
  esac
}
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

bash macOS/scripts/dependencies.sh >/dev/null
bash Core/scripts/prepare-chinese.sh --sources-only >/dev/null 2>&1
name="InkFlow-$version-dictionary-source"
staging=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-source-bundle.XXXXXX")
trap 'rm -rf "$staging"' EXIT
root="$staging/$name"
mkdir -p "$root/upstream/dictionary-sources" "$root/upstream/deps" "$root/inkflow" "$root/LICENSES" "$root/generated"
bash Core/scripts/prepare-chinese.sh "$staging/chinese" >/dev/null
cp "$staging/chinese/dictionary-manifest.json" "$root/generated/"
content_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["contentVersion"])' "$root/generated/dictionary-manifest.json")

# InkFlow-authored recipe exactly as committed: generator, catalog, corrections,
# data snapshots, schemas, preparation scripts and documentation.
git archive --format=tar HEAD LICENSE NOTICE Core schemas macOS/Licenses macOS/DICTIONARIES.md macOS/DEPENDENCIES.md \
  docs/shared-dictionary-preparation.md macOS/scripts/dependencies.sh macOS/scripts/prepare-rime.sh \
  macOS/scripts/prepare-chinese.sh macOS/scripts/prepare-spelling.sh macOS/scripts/build-dictionary-generator.sh \
  macOS/scripts/snapshot-english-frequency.py | tar -xf - -C "$root/inkflow"
cp macOS/Licenses/* "$root/LICENSES/"

sources="$root/SOURCES.tsv"
printf 'component\tlicense\torigin\tbundled path\tsha256\tbytes\n' > "$sources"
record() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(sha256 "$root/$4")" "$(wc -c < "$root/$4" | tr -d ' ')" >> "$sources"; }
# Chinese dictionary catalog inputs, byte-verified against the pinned catalog.
build/dictionary-generator sources | while IFS=$'\t' read -r id sha bytes url; do
  repository=$(printf '%s' "$url" | sed -E 's|https://raw.githubusercontent.com/([^/]+/[^/]+)/.*|\1|')
  cp "build/dictionary-sources/$id.yaml" "$root/upstream/dictionary-sources/$id.yaml"
  printf '%s  %s\n' "$sha" "$root/upstream/dictionary-sources/$id.yaml" | shasum -a 256 -c - >/dev/null
  record "Chinese dictionary source $id" "$(license_for "$repository")" "$url" "upstream/dictionary-sources/$id.yaml"
done
# Pinned archives and files that dependencies.sh downloads and verifies.
deps=$(sed -nE 's/^fetch ([^ ]+) ([0-9a-f]{64}) (https:[^ ]+)$/\1 \2 \3/p' Core/scripts/resource-dependencies.sh)
for file in pinyin.tar.gz english.tar.gz emoji.txt; do
  url=$(printf '%s\n' "$deps" | awk -v f="$file" '$1 == f {print $3}')
  [[ -n "$url" ]] || { echo "resource-dependencies.sh no longer fetches $file." >&2; exit 1; }
  cp "build/deps/$file" "$root/upstream/deps/$file"
  case "$file" in
    pinyin.tar.gz) record 'Legacy compatibility dictionary (rime/rime-pinyin-simp repository archive)' 'Apache-2.0 (LICENSES/pinyin-simp.txt)' "$url" "upstream/deps/$file" ;;
    english.tar.gz) record 'English dictionary input (BlindingDark/rime-easy-en repository archive)' 'LGPL-3.0 with GPL-3.0 (LICENSES/easy-en-LGPL-3.0.txt, easy-en-GPL-3.0.txt)' "$url" "upstream/deps/$file" ;;
    emoji.txt) record 'Emoji conversion table (iDvel/rime-ice opencc/emoji.txt)' 'GPL-3.0 (LICENSES/rime-ice.txt)' "$url" "upstream/deps/$file" ;;
  esac
done
record 'Technical English selection from iDvel/rime-ice en_dicts/en_ext.dict.yaml (104 spellings) plus InkFlow-maintained spellings' \
  'GPL-3.0 (LICENSES/rime-ice.txt, technology-english-NOTICE.txt)' \
  'https://github.com/iDvel/rime-ice/blob/569ff3bc65dd4aec0a26b33c49c8bbdfa8b5fd57/en_dicts/en_ext.dict.yaml' \
  inkflow/Core/Data/english-technology.tsv
record 'wordfreq 3.1.1 en/large Zipf snapshot for easy-en spellings' 'CC BY-SA 4.0 (LICENSES/wordfreq.txt)' \
  'https://github.com/rspeer/wordfreq' inkflow/Core/Data/english-wordfreq.tsv
for opencc in STPhrases.txt STCharacters.txt; do
  record "OpenCC simplified-to-traditional data $opencc" 'Apache-2.0 (LICENSES/opencc.txt)' \
    "https://github.com/BYVoid/OpenCC/blob/556ed22496d650bd0b13b6c163be9814637970ae/data/dictionary/$opencc" "inkflow/schemas/opencc/$opencc"
done
record 'InkFlow Chinese corrections and curated additions' 'Apache-2.0 (inkflow/LICENSE)' "https://github.com/nervouna/InkFlow/tree/$commit" inkflow/Core/config/chinese-overrides.tsv
record 'InkFlow English admission policy' 'Apache-2.0 (inkflow/LICENSE)' "https://github.com/nervouna/InkFlow/tree/$commit" inkflow/Core/config/english-overrides.tsv
record 'InkFlow pinned source catalog' 'Apache-2.0 (inkflow/LICENSE)' "https://github.com/nervouna/InkFlow/tree/$commit" inkflow/Core/config/chinese-sources.json

cat > "$root/README.md" <<README
# InkFlow $version dictionary corresponding source

InkFlow version $version${build:+ (build $build)}, repository commit \`$revision\`.
Generated Chinese dictionary content version \`$content_version\` (see \`generated/dictionary-manifest.json\`).

The InkFlow app ships compiled Rime dictionaries derived from third-party data. This
archive is the corresponding source for that data: the exact pinned upstream inputs,
InkFlow's modifications and generation recipe, and the license texts. InkFlow's own
material is Apache-2.0; third-party data keeps its own license. Compiling a dictionary
does not change those obligations.

## Contents

- \`upstream/dictionary-sources/\`: the pinned Rime Frost, Rime Ice and compatibility
  dictionary files the Chinese generator reads, byte-identical to the verified downloads.
- \`upstream/deps/\`: the pinned rime-pinyin-simp and rime-easy-en repository archives and
  the Rime Ice emoji table, as fetched by \`inkflow/Core/scripts/resource-dependencies.sh\`.
- \`inkflow/\`: the generation recipe at the commit above: the Rust generator
  (\`Core/Portable/dictionary\`), its Swift wrapper (\`Core/Sources/InkFlowDomain\`), the source
  catalog, corrections and admission policy (\`Core/config\`), the wordfreq snapshot and technical-English selection (\`Core/Data\`),
  schemas and OpenCC data (\`schemas\`), preparation scripts and documentation.
- \`LICENSES/\`: license texts and per-source notices, identical to the app's bundled
  \`Resources/Licenses\`.
- \`SOURCES.tsv\`: every input with its license, origin, bundled path, SHA-256 and size.
- \`SHA256SUMS\`: digests of every file in this archive.

Modifications are described in \`LICENSES/chinese-dictionaries-NOTICE.txt\`,
\`LICENSES/technology-english-NOTICE.txt\`, \`inkflow/macOS/DICTIONARIES.md\` and
\`inkflow/Core/Portable/licenses.md\`.

## Rebuilding the shipped dictionaries

On a Mac with the Swift and pinned Rust toolchains, from \`inkflow/\`:

\`\`\`sh
mkdir -p build/deps build/dictionary-sources
cp ../upstream/deps/* build/deps/
cp ../upstream/dictionary-sources/* build/dictionary-sources/
bash macOS/scripts/dependencies.sh        # fetches the remaining librime build inputs
bash Core/scripts/prepare-rime.sh build/shared-rime
\`\`\`

\`build/shared-rime\` then holds the same source dictionaries, schemas and spelling
profiles the app compiles. The complete application source for this version is the
repository at the commit above (https://github.com/nervouna/InkFlow).
README
(cd "$root" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | sed 's|^\./||' | xargs shasum -a 256 > SHA256SUMS)
mkdir -p "$(dirname "$output")"
tar -czf "$output" -C "$staging" --uid 0 --gid 0 --uname root --gname root "$name"
echo "Wrote $output ($name, $content_version)"
