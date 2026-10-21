#!/bin/bash
# Fails if a relative Markdown link in the repository points to a missing file.
set -euo pipefail
cd "$(dirname "$0")/.."
status=0
while IFS= read -r md; do
  dir=$(dirname "$md")
  # [text](target) where target is not a URL or an anchor
  { grep -oE '\]\([^)#:]+(#[^)]*)?\)' "$md" || true; } | sed -E 's/^\]\(([^)#]+).*/\1/' | while IFS= read -r target; do
    [[ -e "$dir/$target" ]] || { echo "$md: broken link -> $target"; exit 1; }
  done || status=1
done < <(git ls-files --cached --others --exclude-standard '*.md' 2>/dev/null || find . -name '*.md' -not -path './.build/*')
exit $status
