#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

output="$PWD/.build/ui-review"
sample_home="$PWD/.build/ui-review-home"
mkdir -p "$output" "$sample_home"

name="${1:-}"
if [ -z "$name" ]; then
  echo "Usage: $0 <screen-name|all|--list>" >&2
  exit 2
fi
if [ "$name" = "--list" ]; then
  find "$output" -maxdepth 1 -name '*.png' -print | sed 's|.*/||; s|\.png$||' | sort
  exit 0
fi

if [ "$name" = "all" ]; then
  rm -f "$output"/*.png
  env CFFIXED_USER_HOME="$sample_home" ZERA_RENDER_SCREENS="$output" \
    swift test --filter 'ScreenRenderTests/(testRenderEveryScreen|testRenderPopulatedStates)'
  echo "Screens: $output"
  open "$output"
else
  name="${name%.png}"
  rm -f "$output/$name.png"
  env CFFIXED_USER_HOME="$sample_home" ZERA_RENDER_SCREENS="$output" ZERA_RENDER_ONLY="$name" \
    swift test --filter 'ScreenRenderTests/(testRenderEveryScreen|testRenderPopulatedStates)'
  if [ ! -f "$output/$name.png" ]; then
    echo "Unknown screen: $name (run $0 --list after rendering all screens)" >&2
    exit 1
  fi
  echo "Screen: $output/$name.png"
  open "$output/$name.png"
fi
