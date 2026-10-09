#!/bin/sh
# Brings a rendered video's sound to -14 LUFS with true peaks under -1.5 dBTP, the usual target for
# social video, in two passes (measure, then a linear correction). The picture is copied as is.
#   remotion/audio/master.sh <in.mp4> <out.mp4>
set -eu
in="$1"
out="$2"
target="I=-14:TP=-1.5:LRA=11"
stats=$(ffmpeg -hide_banner -nostats -i "${in}" -af "loudnorm=${target}:print_format=json" -f null - 2>&1 | sed -n '/^{/,/^}/p')
value() { printf '%s' "${stats}" | sed -n "s/.*\"$1\" : \"\\([^\"]*\\)\".*/\\1/p"; }
ffmpeg -hide_banner -v error -y -i "${in}" -c:v copy \
  -af "loudnorm=${target}:measured_I=$(value input_i):measured_TP=$(value input_tp):measured_LRA=$(value input_lra):measured_thresh=$(value input_thresh):offset=$(value target_offset):linear=true,aresample=48000" \
  -c:a aac -b:a 320k -movflags +faststart "${out}"
echo "mastered ${out}"
