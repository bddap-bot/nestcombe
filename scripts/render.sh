#!/usr/bin/env bash
# Plays a demo script, or replays a session record, on the desktop renderer under a virtual display:
# render.sh SCRIPT.json|CHUNK.jsonl OUT_DIR [ENGINE_ARGS...]
# A record (any chunk of a session) is seen from its recorded head, or from CAIRNFOLD_CAMERA=PATH.json's camera path, until
# it runs out (docs/replay.md), wearing the player's own avatar files from CAIRNFOLD_AVATARS, the avatars folder pulled off
# the device that recorded it.
# Recording a movie records the game's own audio mix too: render.sh SCRIPT OUT --write-movie OUT/x.avi --fixed-fps 30
# CAIRNFOLD_QUIT_AFTER: game seconds before it quits (120 for a script). CAIRNFOLD_TIMEOUT: wall seconds before it is
# killed (1800). CAIRNFOLD_ICD: the Vulkan driver's ICD file (the NVIDIA one).
set -euo pipefail
source=$(realpath "$1")
out=$(realpath -m "$2")
shift 2
mkdir -p "$out"
if [[ $source == *.jsonl ]]; then
  play=(--replay "$source")
  if [ -n "${CAIRNFOLD_QUIT_AFTER:-}" ]; then play+=(--quit-after "$CAIRNFOLD_QUIT_AFTER"); fi
else
  play=(--script "$source" --quit-after "${CAIRNFOLD_QUIT_AFTER:-120}")
fi
if [ -n "${CAIRNFOLD_AVATARS:-}" ]; then play+=(--avatars "$(realpath "$CAIRNFOLD_AVATARS")"); fi
if [ -n "${CAIRNFOLD_CAMERA:-}" ]; then play+=(--camera "$(realpath "$CAIRNFOLD_CAMERA")"); fi
cd "$(dirname "$0")/../game"
display=:$((100 + RANDOM % 800))
Xvfb "$display" -screen 0 3840x2160x24 -nolisten tcp &
xvfb=$!
trap 'kill $xvfb 2>/dev/null || true' EXIT
for _ in $(seq 50); do [ -e "/tmp/.X11-unix/X${display#:}" ] && break; sleep 0.1; done
export DISPLAY=$display
export VK_ICD_FILENAMES=${CAIRNFOLD_ICD:-/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json}
timeout "${CAIRNFOLD_TIMEOUT:-1800}" godot4 --path . --resolution 1600x1200 --xr-mode off "$@" -- --desktop "${play[@]}" --capture-dir "$out" --metrics "$out/metrics.json"
