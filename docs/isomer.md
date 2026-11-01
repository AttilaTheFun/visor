# Blue Visor: Visor on Isomer

> [!WARNING]
> **Very experimental.** These apps run on an experimental framework
> ([Isomer](https://github.com/AttilaTheFun/isomer)): their behaviour will
> change without notice, and nothing here is supported.

Blue Visor (com.LoganShire.VisorIsomer, the blue icon) is the same client as
red Visor — libraries/visor_client, visor_services and visor_ui, the same
SwiftUI source — carried by Isomer to the web, Android, Linux and Windows,
and to the iPhone as WebAssembly. It was its own repository, visor_isomer,
until 0.37. One release ships red and blue.

## The parts

- **Where `import SwiftUI` comes from.** `//:swift_ui`, `//:foundation`,
  `//:pasteboard` and `//:camera` choose per configuration: Apple's (and
  visor's own pasteboard and camera) where SwiftUI is Apple's; Isomer's on
  the web, Android, Linux and Windows, and in a feature compiled against
  Isomer's frameworks (`@isomer//apple/compiled:feature_on`). Blue's
  targets change platform, or enter that configuration, themselves: nothing
  is set on the command line.
- **libraries/visor_services_ffi**: the client's services (socket, HTTP,
  settings and the rest a host gives) as swift_ffi interfaces a host
  implements across a boundary: `SocketBridge`, `HttpBridge`,
  `SettingsBridge` and so on. `installBridgedVisorServices` reads them
  from the injected dependency dictionary (the browser, the iPhone's
  WasmView); `installVisorBridges` takes them directly (Android's Kotlin).
- **libraries/visor_pasteboard_isomer**, **libraries/visor_camera_isomer**:
  the defaults of `//:pasteboard` and `//:camera`, Isomer's `Clipboard` and
  `cameraCapture` where SwiftUI is Isomer's and visor's own libraries
  elsewhere.
- **applications/visor_web**: the browser. index.html implements the
  bridges over WebSocket, fetch and localStorage. Served at
  https://attilathefun.github.io/visor/app/: a release carries the site
  (`tools/isomer/package_site.sh`, attached to its draft) and
  .github/workflows/pages.yml puts it up beside the site when the release
  is published.
- **applications/visor_android**: VisorServices.kt implements the bridges
  over an SSL socket (a small RFC 6455 client of its own), HttpURLConnection
  and SharedPreferences.
- **applications/visor_isomer_ios**: blue on the iPhone and iPad, the client
  as a wasm reactor interpreted by WasmKit in a native iOS 18 shell
  (VisorIsomerServices.swift serves the bridges). Its reactor is built
  threaded (wasm32-unknown-wasip1-threads) and single-threaded; it runs the
  threaded one where WasmKit can make a shared memory.
- **applications/visor_isomer_compiled_ios**: the same client compiled
  natively against Isomer's frameworks (isomer's `isomer_compiled_feature`),
  drawn by Apple's SwiftUI through Isomer's WasmView; iOS 16. Its screens are
  held against red's (launch it with `-visor.fixture snapshot
  -visor.fixture.screen <screen>`).
- **applications/visor_client_linux**, **applications/visor_client_windows**:
  visor_services' native implementations compiled for that platform's
  Foundation. Built on those hosts; unverified from a Mac.
- **artwork/visor_isomer_icon**: blue's icon, from red's Icon Composer
  document.

## Building

Blue is built optimized (`-c opt`): an unoptimized wasm overflows Safari's
stack, and an unoptimized guest runs its frames several times slower. Red
builds with the default; the tools below pass `-c opt` themselves.

    bazel build -c opt //applications/visor_web:visor_web_site
    bazel build -c opt //applications/visor_android:visor_android_apk
    bazel build -c opt //applications/visor_isomer_ios --ios_multi_cpus=sim_arm64
    bazel build -c opt //applications/visor_isomer_compiled_ios --ios_multi_cpus=sim_arm64
    tools/isomer/package_site.sh    # visor-isomer-site.tar.gz, for a release

## Rules

- A person's own phone is not a test device: install a build there when
  they ask (tools/isomer/install_android.sh), read the version back, and
  stop. No launching, tapping or screenshots unless they explicitly ask.
  Test on the simulator and the emulator, which the harnesses below use.
- The guest is one source on every host (applications/visor_web/App.swift).
  Where AgentUI or visor choose by platform at compile time and the guest,
  built for WASI, must choose as the host's platform would, the host says
  so through a setting (`host.platform`) and the guest sets the choice in
  the environment (`suggestionsInPopover`).
- What the guest needs from its host (sockets, HTTP, settings, dictation,
  networks) goes through the bridges in libraries/visor_services_ffi, which
  each host implements (index.html on the web, VisorServices.kt on Android,
  VisorIsomerServices.swift on iOS).
- The web build is 32-bit (wasm32: `Int` is 32 bits, and `Int(Double)`
  traps out of range): the end-to-end test's stand-in server sends numbers
  a 32-bit client can't hold, and the client must survive them.

## CI

visor's CI (.github/workflows/ci.yml) builds and checks blue on every pull
request and every commit to main:
- `blue-web` (a Linux container of Visor's agent image leased from OS
  Server, tools/ci/container_blue_web.sh): the web client built and its
  tests run, then the end-to-end test, the transcript layout and the
  composer checks in headless Chromium (Playwright's arm64 build, pinned).
- The APK (arm64) is built in the `container` job's build, in a container
  of Visor's agent image (tools/ci/container_build.sh). The emulator flow and
  the Android transcript and composer checks are in the local CI for now.
- `blue-ios` (the release Mac, each commit to main only: its snapshots are
  proof-like): the WasmKit and compiled iPhone apps built for the
  simulator, and the snapshots of the iPhone in both orientations
  and of Mobile Safari, against tests/snapshots.

The harnesses take Chrome from `$CHROME` where it isn't at its usual place,
and `VISOR_SNAPSHOT_RUN_DIR` says where a snapshot run goes.

## Local CI

`tools/isomer/ci/local_ci.sh [--review DIR] [suite…]` runs blue's suites in
order and says each one's verdict: `test` (`bazel test //...`),
`snapshots`, `layout-web`, `composer-web`, `layout-android`,
`composer-android`, `android-flow` and `web-e2e`. It wants a clean tree and
a pushed HEAD, since its results are about that commit.

The screens and UI tests are the proof of a commit:
`tools/isomer/ci/publish_proof.py [--commit SHA] [--pull-request N] <run
dir>…` sends a run's targets (each a `manifest.json` beside its files) to
the review server through the review tooling's `publish-proof` (a checkout
at `REVIEWS_CHECKOUT`), with the server's Mac from `REVIEW_SERVER_HOST`.
With `--pull-request` the runs are kept with that pull request's head;
without, under the version they report.

## End-to-end test (the web client against a server)

`tools/isomer/e2e/run.py` builds the web client, serves it beside a stand-in
Visor Server (`stub_server.py`: `/api/hello`, the WebSocket login →
`welcome`, ping/pong, the calls a sessions list makes) and loads it in
headless Chrome: both stub sessions must be listed with no failed request
and nothing uncaught (`page_check.js`). `run.py <directory>` tests a site
already built (a published copy). The stub's numbers are the ones a 32-bit
client can't hold (token counts and revisions past 2^31, a count past exact
doubles, negatives, fractions).

It runs three roads: the stub's WebSocket; the upgrade refused with 501
(`--no-websocket`, a reverse proxy that passes no WebSockets), when the list
must still appear by polling (`GET /api/sessions?since=`, held by the stub
while nothing changed; `/stub/stats` proves the polls happened); and no shim
and nothing saved, when the page, served by the stub itself, must find the
server at its own origin. `run.py --review <dir>` also runs it in a
landscape window and records each road, writing `ui-test` manifests.

`tools/isomer/uitests/android_flow.py --review <dir>` is the Android UI test:
on the emulator (or a leased lab phone, `ANDROID_SERIAL`), in portrait and
in landscape, it does what a reader does on the snapshot fixture (the
sessions list, a session opened, its details opened and closed, New
Session, a question answered), each step recorded with its last screen. Its
checks read the UI dump as XML (`uiautomator dump --windows` where a popup
must be seen): a button's `enabled` is on the clickable node above the words
Compose puts in it. It expects a running emulator (local_ci.sh boots one).

`tools/isomer/e2e/transcript_layout_check.js` and `composer_check.js`
(headless Chrome, a 390-point window by device emulation) and their Android
twins in tools/isomer/uitests check the transcript's code blocks and
pictures and AgentUI's composer typed into.

## Snapshot tests

`tools/isomer/snapshots/snapshots.py run [--targets …] [--screens …]`
screenshots every screen of the fixture mode (`fixture=snapshot`,
`fixture.screen=<screen>`: a canned computer, sessions and transcript at a
fixed clock) and compares each with tests/snapshots/<target>/<screen>.png,
painting changed pixels red in a diff (report.html); it exits 1 when
anything changed. `snapshots.py accept <run dir> [--targets …] [--screens …]`
makes captures the references: accept only what changed, and commit them
with the change that moved them. `VISOR_SNAPSHOT_BAZEL_FLAGS` adds Bazel
flags (an `--override_module` to test an unpinned dependency); the Android
flow takes it too.

- `web-mobile`: the web client in Mobile Safari on the harness's own
  simulator, `visor-snapshots`, made if missing and shut down after.
- `ios`, `ios-landscape`: blue's iPhone app (applications/visor_isomer_ios),
  pictured by tests/isomer_ios_fixture, an XCUITest that takes the fixture's
  screens as red's own probe takes red's, on an iPhone 17 with iOS 27 and the
  same status bar, a simulator its runner makes and deletes. Filed as target
  `ios` in each orientation, so a review server can hold each picture
  against red's.
- `android`: the hermetic emulator (emulator-5554, booted if none).
- `android-lab`, `android-lab-landscape`: a leased lab phone, only inside a
  lease (`ANDROID_SERIAL` and the lab's adb from it), with references of
  their own.
- `red-ios`, `web-desktop`, `macos`: red's app on the iPhone simulator, and
  desktop Safari and the Mac app on a Mac leased from oss (`oss machine`,
  with the computer's key or token), released when the run ends.
  Safari's site goes to the guest, and safaridriver's port comes back, over
  the run's SSH connection; the Mac app's window is cropped from the
  machine's own screenshot. The guest's look is dark, said outright.

Never another session's simulator or emulator: the harness uses its own.
