#!/bin/sh
# Compiles the fx classes into a scratch sclang and runs the click test.
# Needs sclang, scsynth and a JACK server (pipewire-jack is enough).
here=$(cd "$(dirname "$0")" && pwd)
conf=$(mktemp --suffix=.yaml)
cat > "$conf" <<EOF
includePaths:
    - $here/../lib
    - $here/classes
excludePaths: []
postInlineWarnings: false
EOF
QT_QPA_PLATFORM=offscreen timeout 90 sclang -l "$conf" "$here/click_test.scd"
status=$?
rm -f "$conf"
exit $status
