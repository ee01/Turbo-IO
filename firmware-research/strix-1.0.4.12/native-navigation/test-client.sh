#!/bin/bash
# Protocol and transport tests only. No firmware archive, SDK or device needed.
set -euo pipefail
cd "$(dirname "$0")/phone"
mkdir -p ../work
output=$(mktemp -d "$PWD/../work/client-tests.XXXXXX")
common=(display_runtime.c display_client.c display_carrier.c DisplayDelta.c DisplayNavigation.m DisplayReplyObserver.m DisplayPhoneSession.m DisplayPhoneTransport.m DisplayDiagnostics.m ImageUpload.m ImageUploadTransport.m ExperimentalOTA.m ExperimentalOTAGuard.m ExperimentalOTAFlash.m nav_runtime.c NativeNavigation.m TNVTransport.m)
for name in DisplayDelta DisplayDeltaSession DisplayDiagnostics DisplayFramePacing DisplayNavigation DisplayPhone DisplayReplyObserver DisplayTaskBinding ImageUpload ImageUploadTransport NativeNavigation; do
  xcrun --sdk macosx clang -fobjc-arc -fmodules -Wall -Wextra -Wno-unused-parameter -Wno-incompatible-pointer-types -DTIO_DISPLAY_DIAGNOSTICS=1 -framework Foundation "${common[@]}" "${name}Tests.m" -o "$output/$name"
  "$output/$name"
done
echo 'PASS native client protocol/transport suites; synthetic data, no device IO'
