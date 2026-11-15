#!/bin/sh
# Compiles the fx classes into a scratch sclang and runs the click test.
# Needs sclang, scsynth and a JACK server (pipewire-jack is enough).
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
# the test plugin is not a .sc file in the repo, so norns does not compile it
cp "$here/FxTestLegacy.sc.txt" "$work/FxTestLegacy.sc"
cat > "$work/conf.yaml" <<EOF
includePaths:
    - $here/../lib
    - $work
excludePaths: []
postInlineWarnings: false
EOF
QT_QPA_PLATFORM=offscreen timeout 120 sclang -l "$work/conf.yaml" "$here/click_test.scd"
status=$?
rm -rf "$work"
exit $status
