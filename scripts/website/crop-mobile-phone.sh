#!/bin/bash
# Crop the phone out of a still rendered by render-hero-video.mjs --target mobile (stage 440x900
# at 2x with 32px padding; the phone sits at 13,16 sized 414x868) and make its 58px rounded
# corners transparent, for the README. Usage: crop-mobile-phone.sh <mobile-still.png> <out.png>
set -euo pipefail
in=$1; out=$2
r=$((58*2)); w=828; h=1736; x=$(( (32+13)*2 )); y=$(( (32+16)*2 ))
ffmpeg -loglevel error -y -i "$in" -filter_complex "
[0:v]crop=${w}:${h}:${x}:${y},format=rgba[ph];
color=c=black@0:s=${w}x${h},format=gray,
geq=lum='if(lt(X,${r})*lt(Y,${r})*gt((X-${r})*(X-${r})+(Y-${r})*(Y-${r}),${r}*${r}),0,
          if(gt(X,W-1-${r})*lt(Y,${r})*gt((X-(W-1-${r}))*(X-(W-1-${r}))+(Y-${r})*(Y-${r}),${r}*${r}),0,
          if(lt(X,${r})*gt(Y,H-1-${r})*gt((X-${r})*(X-${r})+(Y-(H-1-${r}))*(Y-(H-1-${r})),${r}*${r}),0,
          if(gt(X,W-1-${r})*gt(Y,H-1-${r})*gt((X-(W-1-${r}))*(X-(W-1-${r}))+(Y-(H-1-${r}))*(Y-(H-1-${r})),${r}*${r}),0,255))))'[m];
[ph][m]alphamerge" -frames:v 1 "$out"
