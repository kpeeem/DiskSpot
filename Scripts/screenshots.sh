#!/bin/zsh
set -eu
project=${0:A:h:h}
home=/Users/Shared/alex
if [[ -e $home ]]; then echo "$home already exists"; exit 1; fi
work=$(mktemp -d)
pid=""
trap '[[ -n $pid ]] && kill $pid 2>/dev/null; rm -rf "$home" "$work"; sleep 3; rm -rf "$home"' EXIT INT TERM
python3 -I "$project/Scripts/demo-home.py" "$home" ru
app="$project/build/DiskSpot-Debug.app/Contents/MacOS/DiskSpot"
for shot in diskspot cleanup; do
    extra=()
    select=$home/Developer
    [[ $shot == cleanup ]] && extra=(--cleanup) && select=$home/Library/Caches
    CFFIXED_USER_HOME="$home" DISKSPOT_FOLDER="$home" DISKSPOT_DEMO=1 DISKSPOT_SNAPSHOT="$work/$shot" DISKSPOT_SELECT="$select" \
        "$app" "${extra[@]}" 2>"$work/$shot.log" &
    pid=$!
    for _ in {1..120}; do
        grep -q '^done' "$work/$shot.log" && break
        sleep 1
    done
    kill $pid; wait $pid 2>/dev/null || true
    pid=""
    last=$(ls -t "$work/$shot"-*.png | head -1)
    sips -s format jpeg -s formatOptions 82 -Z 1800 "$last" --out "$project/Docs/$shot.jpg" >/dev/null
done
ls -l "$project/Docs"
