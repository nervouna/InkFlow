#!/bin/bash
# Called with the verified artifact from this main workflow run.
set -euo pipefail
version=${1:?Expected version}
revision=${2:?Expected commit}
cd "${3:?Expected asset directory}"
tag="linux-v$version"
binary="InkFlow-$version-linux-aarch64"
source="InkFlow-$version-linux-source.tar.xz"
files=("$binary.tar.xz" "$source" SHA256SUMS-linux)
sha256sum --strict -c SHA256SUMS-linux
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# A tag (including an existing published release) is never moved or reused.
gh api "repos/$GH_REPO/git/matching-refs/tags/$tag" > "$scratch/refs.json"
if jq -e --arg ref "refs/tags/$tag" 'any(.[]; .ref == $ref)' "$scratch/refs.json" > /dev/null; then
  echo "Tag $tag already exists. Choose a new Linux version." >&2
  exit 1
fi
gh api --paginate "repos/$GH_REPO/releases?per_page=100" \
  --jq ".[] | select(.tag_name == \"$tag\") | [.draft, .target_commitish] | @tsv" > "$scratch/existing"
if [[ -s "$scratch/existing" ]]; then
  if [[ $(cat "$scratch/existing") != $'true\t'"$revision" ]]; then
    echo "$tag belongs to a different commit or a published release." >&2
    exit 1
  fi
else
  cat > "$scratch/notes.md" <<NOTES
适用于 ARM64 Omarchy / Hyprland，使用 Fcitx5。源码提交为 \`$revision\`。

下载安装包 \`$binary.tar.xz\` 和 \`SHA256SUMS-linux\`，在同一目录执行：

\`\`\`sh
sha256sum --check --ignore-missing SHA256SUMS-linux &&
  tar -xf $binary.tar.xz &&
  python3 $binary/install.py install $binary
\`\`\`

对应源码见同页的 \`$source\`。[Linux 安装、更新与回滚说明](https://github.com/$GH_REPO/blob/$revision/Linux/README.md)
NOTES
  gh release create "$tag" --draft --latest=false --target "$revision" \
    --title "InkFlow Linux $version · ARM64 Omarchy" --notes-file "$scratch/notes.md"
fi
# Rerunning the failed draft job uses the same Actions artifact. Keep already uploaded bytes.
gh release view "$tag" --json assets > "$scratch/assets.json"
for file in "${files[@]}"; do
  state=$(jq -r --arg name "$file" '.assets[] | select(.name == $name) | .state' "$scratch/assets.json")
  case "$state" in
    uploaded) continue ;;
    # GitHub may reserve the name with an empty "starter" asset after an interrupted upload.
    starter) gh release upload "$tag" "$file" --clobber ;;
    "") gh release upload "$tag" "$file" ;;
    *) echo "Unexpected asset state for $file: $state" >&2
       exit 1 ;;
  esac
done
mkdir "$scratch/download"
gh release download "$tag" --dir "$scratch/download"
for file in "${files[@]}"; do
  cmp "$file" "$scratch/download/$file"
done
gh release view "$tag" --json url,isDraft,targetCommitish > "$scratch/draft.json"
jq -e --arg sha "$revision" '.isDraft and .targetCommitish == $sha' "$scratch/draft.json" > /dev/null
jq -r '.url' "$scratch/draft.json" >> "$GITHUB_STEP_SUMMARY"
