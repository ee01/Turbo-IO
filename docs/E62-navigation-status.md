# E-62 navigation implementation checkpoint

2026-10-31. Development checkpoint, not an installable navigation release.

## Current contract

Daily navigation has one Start action after route planning. It starts the phone
route and arms one lens START attempt on the first fresh guidance frame, subject
to compatibility, confirmed LifeLog pause and assistant release. There is no
separate lens enable or visual confirmation prompt. Physical observation remains
an acceptance activity.

LifeLog originally ON must pause without another choice dialog and restore after
confirmed exit. Originally OFF stays OFF. Same-value manual OFF, source changes,
unknown STOP outcomes and process recovery must never silently enable recording.

A final `导航去…` utterance is a navigation intent. ASR final and response completion
are not proof that the assistant released the glasses. Phone search/route start
and lens handoff must wait for the correlated workflow release. Home, unfolded,
foreground ownership and assistant gates in the firmware remain in force.

## Implemented and verified offline

- Restore the exact 37-file E-63 archive overlay as an independent commit. The
  ordinary arm64 ad-hoc library reproduces SHA-256
  `0ecf3b1c99a658853a640b8ef117dc83d341e8f219f2d627917cc3b22e19f431`.
- Separate `daily-navigation` and `tlc1-upgrade` build profiles. Actual linked
  daily library has no `_TIOOTA*` symbols; tool has no `_TNVStart`. Both retain
  archive source/settings. Tool catalogue has no navigation entry.
- Move native ACK routing out of the OTA conditional, retaining the original
  forwarding of non-owned official events.
- Validate exact TLC1 size/hash and distinct tool marker; reject daily/tool
  cross-use. Daily packaging does not patch the official upgrade route or carry
  candidate firmware. It writes a signed resource manifest with SDK/control
  availability recorded honestly.
- Wire daily UI Start to one native attempt, remove separate enable/confirmation,
  bind frames to route generation and original navigation callback time. Icon
  repainting does not refresh that time. Unknown location age remains null.
- Distinguish START pending / protocol confirmed / STOP pending / stopped /
  unknown outcome. ACK plus file success and submission correlation remain
  required. A STOP ACK reporting active is rejected.
- Add pure LifeLog policy with durable-before-pause journal callback, correlated
  observations, START rejection cleanup, timeout recovery and user-intent priority.
- Add final-only voice intent parsing and bounded correlated release gate.
- Audit exact upstream TLC1 ZIP and AP against stock; all 13 non-AP payloads
  match stock. Run archive/directory/flash/guard/feed suites without device IO.

## Incomplete production integration

The LifeLog policy and voice intent gate are extension components, **not a
verified official host bridge**. They are not yet connected to real switch
readback, user-intent observation, speech workflow release, or automatic AMap
search/route execution. No API name or selector presence is treated as proof of
that contract.

`TIONavigationCompatibilityStatus` therefore supplies no supported control
contract; the generated manifest records
`verifiedControlContractVersion: null`. The daily build cannot send experimental
START through `TNVStart`, even if someone edits deployment defaults or the
manifest. Original/unknown firmware stays disabled. This deliberate gate must be
replaced only alongside a verified bridge and its target-device evidence, not by
changing a flag or filling in an arbitrary contract string.

A user-supplied iOS key for `com.rayneo.venus.pub` is kept only in the local
keychain and a mode-0600 gitignored file. Source, manifests, logs and this
document do not contain it. Packaging accepts `--amap-key-file` and, on first
navigation open, copies a bundle-matched `TIOAMapPrivate.json` into the phone
keychain. The manifest still records no key.

The pinned SDK did not install. Search 9.8.1 still matches
`d11e0b418319c74abf5228611f678b58130eac791e267d6d6e3e7ec9f41b2007`. The official
Navi ALL archive now hashes to
`8264377eb68d414c046be96585957250cda15a7eabd16553842f53f98764f4b8` and contains
Navi V11.3.100 plus Foundation V1.9.4_20260904. The required pin remains Navi
11.2.100 / Foundation 1.9.1
(`044d444f915dc2822003e14ad5d096ae00677ee1495efa64c0dd4c400a70e075`).
`setup-amap.mjs` stopped. This checkpoint did not retarget the SDK, so no
AMap-enabled library was linked. Earlier arm64 checks remain `TIO_AMAP_ENABLED=0`.
These are development libraries, not a working phone-navigation IPA. There was
no signing, installation, firmware transmission or device-state change.

## Reproduction

From the repository root, Xcode 16.4 / iOS 18.5 SDK:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  TIO_BUILD_PROFILE=daily-navigation bash official-addon/build.sh embedded
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  TIO_BUILD_PROFILE=tlc1-upgrade bash official-addon/build.sh embedded
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash official-addon/test.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash firmware-research/strix-1.0.4.12/native-navigation/test-client.sh
node --test official-addon/package.test.mjs
uv run --project memory-sync-service --group dev pytest memory-sync-service/tests -q
```

A navigation build with AMap still needs the pinned Navi 11.2.100 and Foundation
1.9.1 archives. The current official Navi ALL URL no longer matches that pin;
do not substitute V11.3.100 / V1.9.4 without a separate compatibility review.
The iOS key stays in the private local file and is passed only as `--amap-key-file`.

The tool packaging option is `--experimental-ota TLC1 --firmware /absolute/exact.zip`;
it uses the TLC1 `ios-reference` implementation, its exact gate and historical
resource name `TurboWeReadCandidate.zip`. Daily packaging uses neither option.
The tool is not a replacement daily app or permission to flash.

## Acceptance tracking

| Item | Current evidence |
| --- | --- |
| C01 stock login/pairing/reconnection/official features | Not device tested |
| C02 stock phone navigation, no experimental START | Offline capability rejection; SDK/phone/device tests outstanding |
| C03 daily OTA isolation | Actual symbol and packaging rules checked; installed route/query/download untested |
| C04 overwrite/data continuity | Existing archive regression passes; signed overwrite/keychain/device untested |
| C05 compatibility/session isolation | Offline manifest/source/expiry/unsupported-contract and existing session tests; device untested |
| C06 physical lens display | Protocol tests only; no physical observation |
| C07 LifeLog pause/restore | Synthetic policy, 20 ON/OFF cycles; bridge and device collection untested |
| C08 upgrade guard | Exact TLC1 archive/directory/flash/guard/feed tests; device untested |
| C09 travel modes/background/weak location | Existing offline background and new freshness tests; SDK/road/device untested |
| C10 official model and real archive | Archive regressions only; target device untested |
| C11 firmware/recovery | Exact upstream ZIP/AP audit passes; actual device source/recovery applicability unknown |
| Voice navigation | Intent/release reducer tested; host lifecycle and search/route handoff incomplete |

## Firmware and recovery boundary

Audited TLC1-01 upstream candidate, unchanged ZIP (9,322,471 bytes):
`5e2b85acb9cd25e0b245838e665e39d291eae4aae640308f126718eb3185e519`.
AP: `bb3fee35ac7ff7f5b76295235323249634cdaf582069972d7b89cff4020f855d`.
This is existing TLC1, not a new firmware implementing voice navigation. Historical
upstream user feedback in the audit is not evidence about the present user's
hardware.

Actual flashing still needs the exact current device/firmware, package, power and
connection conditions, transfer completion criteria and a separately confirmed
recovery plan. Stock payload archive is not a rescue image; same-version reinstall
and downgrade are unverified. Loss of Bluetooth/OTA may remove the available
recovery path. No promise of one-click recovery or safe force-quit during OTA.
