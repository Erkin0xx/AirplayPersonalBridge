#!/usr/bin/env bash
# Fabrique les deux vidéos d'essai du calage image/son (ignorées par git, à régénérer) :
#   silent.mp4           30 s, mire testsrc, piste son FLAC au SILENCE NUMÉRIQUE STRICT (mesures muettes)
#   sync-flash-beep.mp4  120 s, flash blanc + bip 1 kHz de 66,7 ms toutes les 2 s, barre mobile
#                        (essai à l'œil, sur les enceintes ; bip calé à l'échantillon près)
#
#   scripts/video-sync/make-media.sh [dossier]   (défaut : à côté de ce script)
set -euo pipefail
OUT="${1:-$(cd "$(dirname "$0")" && pwd)}"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=640x360:rate=30:duration=30" \
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=48000" -t 30 \
  -c:v libx264 -pix_fmt yuv420p -profile:v baseline -c:a flac -strict -2 -movflags +faststart "$OUT/silent.mp4"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=0x202020:s=1280x720:r=30:d=120" \
  -f lavfi -i "color=c=0x40c0ff:s=40x80:r=30:d=120" \
  -f lavfi -i "aevalsrc='0.5*sin(2*PI*1000*t)*lt(mod(t\,2)\,0.0667)|0.5*sin(2*PI*1000*t)*lt(mod(t\,2)\,0.0667)':s=48000:d=120" \
  -filter_complex "[0:v][1:v]overlay=x='mod(t*320\,1240)':y=600:eval=frame,drawbox=x=0:y=0:w=1280:h=720:color=white:t=fill:enable='lt(mod(t\,2)\,0.0667)'[v]" \
  -map "[v]" -map "2:a" -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart "$OUT/sync-flash-beep.mp4"
# Le silence doit être strict : un seul octet distinct, 00.
test "$(ffmpeg -v error -i "$OUT/silent.mp4" -vn -f s16le - | od -An -tx1 -v | tr ' ' '\n' | grep -v '^$' | sort -u)" = "00"
echo "==> $OUT/silent.mp4, $OUT/sync-flash-beep.mp4"
