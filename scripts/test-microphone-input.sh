#!/bin/bash
# Pure production validator only: no AVAudioEngine, device capture or app data.
set -euo pipefail
mic_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
mic_test_dir="$(mktemp -d -t parrot-mic-regression)"
trap 'rm -rf "$mic_test_dir"' EXIT
cp "$mic_repo_root/scripts/microphone-regression.swift" "$mic_test_dir/main.swift"
swiftc -swift-version 5 "$mic_repo_root/Parrot/Services/MicrophoneInputFormat.swift" \
  "$mic_test_dir/main.swift" -o "$mic_test_dir/microphone-tests"
"$mic_test_dir/microphone-tests"
