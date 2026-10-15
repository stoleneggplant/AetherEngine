#!/bin/bash
set -euo pipefail
TASK_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TASK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/aether-partial-controls.XXXXXX")
trap 'rm -f "$TASK_TMP"/*.mp4; rmdir "$TASK_TMP"' EXIT
bash "$TASK_ROOT/Scripts/test-h264-partial-composition.sh"
# Reproducible public solid-colour/tone fixture. Keep an 8-second valid head, then remove
# only composition offsets; never duplicate any real source media into a test artifact.
ffmpeg -hide_banner -loglevel error -n \
  -f lavfi -i 'color=c=blue:s=96x64:r=30:d=24' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=24' \
  -c:v libx264 -preset fast -pix_fmt yuv420p -g 30 -bf 2 \
  -x264-params 'scenecut=0:b-adapt=0' -c:a aac -video_track_timescale 90000 \
  -metadata comment='Aether synthetic timestamp fixture' -movflags +faststart "$TASK_TMP/healthy.mp4"
ruby "$TASK_ROOT/Scripts/tests/make-partial-ctts-fixture.rb" "$TASK_TMP/healthy.mp4" "$TASK_TMP/partial.mp4"
bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" \
  "$TASK_TMP/partial.mp4" 0 10 0 6 22
ruby "$TASK_ROOT/Scripts/tests/make-partial-ctts-fixture.rb" "$TASK_TMP/healthy.mp4" "$TASK_TMP/middle.mp4" middle
bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" \
  "$TASK_TMP/middle.mp4" 0 10 0 6 14 22
# A uniform one-second GOP cannot reach the ceiling of a policy that holds a sequence, so it also
# cannot show that ceiling gone. This one is scene-cut shaped: a 30-picture zero-offset sequence
# confirms, and the 420-picture sequence behind it is the case that used to end the session.
ffmpeg -hide_banner -loglevel error -n \
  -f lavfi -i 'color=c=green:s=96x64:r=30:d=40' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=40' \
  -c:v libx264 -preset fast -pix_fmt yuv420p -g 3000 -bf 2 \
  -x264-params 'scenecut=0:b-adapt=0' \
  -force_key_frames 'expr:eq(n,0)+eq(n,150)+eq(n,300)+eq(n,330)+eq(n,750)' \
  -c:a aac -video_track_timescale 90000 \
  -metadata comment='Aether synthetic timestamp fixture' -movflags +faststart "$TASK_TMP/healthy-scenecut.mp4"
ruby "$TASK_ROOT/Scripts/tests/make-partial-ctts-fixture.rb" \
  "$TASK_TMP/healthy-scenecut.mp4" "$TASK_TMP/variable.mp4" tail 300 1200 1200
bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" "$TASK_TMP/variable.mp4" 0 12 0

# Entire missing-offset head with a decode cadence change, plus its untouched healthy control.
python3 "$TASK_ROOT/Scripts/tests/make-missing-head-fixture.py" "$TASK_TMP"
bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" "$TASK_TMP/missing-head.mp4" 0 1.5 0 20 40
bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" "$TASK_TMP/healthy-head.mp4" 0

# Hierarchical B pictures: forward distance 3, declared backward depth 2. The healthy twin
# supplies an exact PTS oracle for both a damaged tail and a damaged middle with recovery.
python3 "$TASK_ROOT/Scripts/tests/make-missing-head-fixture.py" "$TASK_TMP" --partial-hierarchical
AETHER_TIMESTAMP_HEALTHY_TWIN="$TASK_TMP/healthy-b3.mp4" \
  bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" "$TASK_TMP/tail-b3.mp4" 0 12 0 6 22
AETHER_TIMESTAMP_HEALTHY_TWIN="$TASK_TMP/healthy-b3.mp4" \
  bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" "$TASK_TMP/middle-b3.mp4" 0 12 0 6 18 22
bash "$TASK_ROOT/Scripts/test-h264-partial-composition-runtime.sh" "$TASK_TMP/healthy-b3.mp4" 0
