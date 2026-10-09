#!/bin/bash
# Records every screen as transparent clips and stills, with Zera, into renders/zera-screens.
# Usage: scripts/render-clips.sh [clip-prefix,clip-prefix…]   e.g. scripts/render-clips.sh 06,23
# Windows appear on screen while it records: leave the Mac alone for a few minutes.
set -euo pipefail
cd "$(dirname "$0")/.."

out="$PWD/renders/zera-screens"
sample_home="${TMPDIR:-/tmp}/zera-clips-home"
rm -rf "$sample_home"
mkdir -p "$out" "$sample_home"

version="${ZERA_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"

env ZERA_CLIPS_VERSION="$version" CFFIXED_USER_HOME="$sample_home" ZERA_CLIPS="$out" ZERA_CLIPS_WORK="${TMPDIR:-/tmp}" ${1:+ZERA_CLIPS_ONLY="$1"} \
  swift test --filter 'ScreenClipsTests/testRecordClips'
echo "Renders: $out"
