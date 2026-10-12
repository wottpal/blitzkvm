#!/bin/zsh
# replay.sh CLIP OUT.png MODE [ENV=VALUE ...]
# Replays a recorded stream (bench.py/kvmd.py recordings are Annex-B H.265)
# through the app's own renderer and writes its snapshot:
#   MODE 1x  pixel for pixel, a 960x540-point view (1920x1080 pixels)
#   MODE 2x  Actual Size on a Retina screen, a 1500x1000-point view: the
#            snapshot shows 1x pixels [210, 1710) x [40, 1040) enlarged 2x
# ENV assignments go to the app (BLITZKVM_UPSCALER=fsr, BLITZKVM_CHROMA=bicubic,
# BLITZKVM_GPU_TIMING=1). Needs `make -C macos app` and ffmpeg.
set -e
here=${0:A:h}; macos=$here/../../macos
clip=$1; out=$2; mode=$3; shift 3
tmp=$(mktemp -d)
ffmpeg -v error -y -i $clip -c copy -bsf:v hevc_metadata=aud=insert -f hevc $tmp/clip.h265
(cd $here/../.. && go build -o $tmp/emulator-serve ./test/emulator-serve)
$tmp/emulator-serve serve --listen 127.0.0.1:18093 --width 1920 --height 1080 --fps 60 --replay-h265 $tmp/clip.h265 >/dev/null 2>&1 &
pid=$!
trap "kill $pid 2>/dev/null" EXIT
sleep 3
if [[ $mode == 2x ]]; then args=(--scale actualSize --window-size 1500x1022); else args=(--scale pixelExact --window-size 960x562); fi
env "$@" "$macos/build/BlitzKVM.app/Contents/MacOS/BlitzKVM" --device 127.0.0.1:18093 --selftest 5 --view-only $args --snapshot $out > $tmp/report.json 2>&1 || true
grep -q '"presentedFrames" : 0,' $tmp/report.json && { echo "no frames presented (emulator not ready?)"; exit 1; }
echo "wrote $out"
