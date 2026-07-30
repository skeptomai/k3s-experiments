#!/usr/bin/env bash
# Convert a Markdown file with Mermaid diagrams to PDF.
#
# Usage: md-to-pdf.sh <input.md> [output.pdf]
#
# Mermaid fenced blocks are rendered to PNG via mmdc (--width 3200 --scale 3)
# and substituted as inline images before pandoc/lualatex produces the PDF.
# Output defaults to <input>.pdf alongside the source file.
set -euo pipefail

INPUT="${1:-}"
if [[ -z "$INPUT" ]]; then
    echo "Usage: $0 <input.md> [output.pdf]" >&2
    exit 1
fi
INPUT="$(realpath "$INPUT")"
if [[ ! -f "$INPUT" ]]; then
    echo "Error: file not found: $INPUT" >&2
    exit 1
fi

OUTPUT="${2:-${INPUT%.md}.pdf}"
OUTPUT="$(realpath "$OUTPUT")"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "==> Rendering Mermaid diagrams..."
python3 - "$INPUT" "$TMPDIR" <<'PYEOF'
import re, sys, os

src = open(sys.argv[1]).read()
tmpdir = sys.argv[2]
diagrams = []

def replace(m):
    idx = len(diagrams)
    diagrams.append(m.group(1))
    return f'![]({tmpdir}/diagram-{idx}.png)'

replaced = re.sub(r'```mermaid\n(.*?)```', replace, src, flags=re.DOTALL)

for idx, code in enumerate(diagrams):
    mmd = f'{tmpdir}/diagram-{idx}.mmd'
    open(mmd, 'w').write(code)

open(f'{tmpdir}/input.md', 'w').write(replaced)
print(f'found {len(diagrams)} diagram(s)')
PYEOF

# Render each .mmd to .png
COUNT=0
for MMD in "$TMPDIR"/diagram-*.mmd; do
    [[ -f "$MMD" ]] || continue
    PNG="${MMD%.mmd}.png"
    mmdc -i "$MMD" -o "$PNG" --width 3200 --scale 3 -q
    echo "    rendered $(basename "$PNG") ($(du -h "$PNG" | cut -f1))"
    COUNT=$((COUNT + 1))
done
[[ $COUNT -eq 0 ]] && echo "    (no mermaid blocks found)"

echo "==> Converting to PDF with pandoc + lualatex..."
pandoc "$TMPDIR/input.md" \
    -o "$OUTPUT" \
    --pdf-engine=lualatex \
    -V geometry:margin=1in \
    -V colorlinks=true \
    -V linkcolor=blue \
    -V "monofont=JetBrainsMono Nerd Font" \
    --highlight-style=tango

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo "==> Done: $OUTPUT ($SIZE)"
