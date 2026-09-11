#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test termination-tests build/termination-tests
termination_root=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-termination.XXXXXX")
trap 'rm -rf "$termination_root"' EXIT
probe="$termination_root/Termination Probe.app"
mkdir -p "$probe/Contents/MacOS"
cp build/termination-tests "$probe/Contents/MacOS/TerminationProbe"
cat > "$probe/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.damao.inkflow.tests.termination</string>
<key>CFBundleExecutable</key><string>TerminationProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.3-test</string>
<key>CFBundleVersion</key><string>42</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
for mode in success dictionary-failure store-failure disabled; do
  mkdir "$termination_root/$mode"
  "$probe/Contents/MacOS/TerminationProbe" "$termination_root/$mode" "$mode" "$PWD/build/InkFlow.app/Contents/Resources/Rime"
  case "$mode" in
    dictionary-failure) printf 'drain-start\ndenied-retry\ndrain-start\ndrain-end\nengine-stop\nstore-close\nwill-terminate\n' ;;
    store-failure) printf 'drain-start\ndrain-end\nengine-stop\nstore-failed\ndenied-retry\nstore-close\nwill-terminate\n' ;;
    *) printf 'drain-start\ndrain-end\nengine-stop\nstore-close\nwill-terminate\n' ;;
  esac > "$termination_root/expected"
  diff -u "$termination_root/expected" "$termination_root/$mode/trace"
  if [[ "$mode" != disabled ]]; then
    [[ $(sqlite3 "$termination_root/$mode/quality.sqlite3" 'select status from recording_runs') == closed ]]
  fi
  echo "PASS native termination: $mode (15s subprocess timeout)"
done
