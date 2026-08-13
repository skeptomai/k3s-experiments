#!/usr/bin/env bash
# Check if a Pelagos release newer than MIN_VERSION exists that references all required issues.
#
# Usage: watch-pelagos-release.sh <min-version> <issue> [issue ...]
# Exit 0: qualifying release found — prints tag and URL
# Exit 1: not yet — prints current latest tag
#
# Example: watch-pelagos-release.sh v0.65.65 482 483 484

set -euo pipefail

MIN_VERSION="${1:?Usage: $0 <min-version> <issue> [issue ...]}"
shift
REQUIRED_ISSUES=("$@")

if [[ ${#REQUIRED_ISSUES[@]} -eq 0 ]]; then
    echo "ERROR: at least one issue number required" >&2
    exit 2
fi

# semver → integer (supports up to major/minor/patch < 1000)
ver_int() {
    local v="${1#v}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$v"
    echo $(( major * 1000000 + minor * 1000 + patch ))
}

MIN_INT=$(ver_int "$MIN_VERSION")

# Fetch up to 10 recent release tags (newest first)
mapfile -t TAGS < <(
    gh release list --repo pelagos-containers/pelagos --limit 10 --json tagName \
        --jq '.[].tagName' 2>/dev/null
)

if [[ ${#TAGS[@]} -eq 0 ]]; then
    echo "NOT YET: could not fetch releases" >&2
    exit 1
fi

for tag in "${TAGS[@]}"; do
    tag_int=$(ver_int "$tag" 2>/dev/null) || continue
    [[ $tag_int -le $MIN_INT ]] && continue

    # Newer tag found — check release notes mention all required issues
    body=$(gh release view "$tag" --repo pelagos-containers/pelagos --json body \
        --jq '.body' 2>/dev/null) || continue

    all_found=true
    missing=()
    for issue in "${REQUIRED_ISSUES[@]}"; do
        if ! echo "$body" | grep -qE "(#|issues/)${issue}([^0-9]|$)"; then
            all_found=false
            missing+=("#${issue}")
        fi
    done

    if [[ "$all_found" == "true" ]]; then
        url=$(gh release view "$tag" --repo pelagos-containers/pelagos \
            --json url --jq '.url' 2>/dev/null)
        echo "FOUND: $tag"
        echo "URL:   $url"
        echo ""
        echo "$body" | head -30
        exit 0
    else
        echo "NOT YET: $tag exists but missing fixes for: ${missing[*]}"
        exit 1
    fi
done

echo "NOT YET: latest is ${TAGS[0]} (no release newer than ${MIN_VERSION})"
exit 1
