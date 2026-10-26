#!/usr/bin/env python3
"""Screenshot regression tests for Visor across its targets.

Each target opens each screen of visor's fixture mode (a canned computer,
sessions and transcript with a fixed clock: the `fixture` / `fixture.screen`
settings) and takes a screenshot; the captures are compared with the
references committed under tests/snapshots/<target>/<screen>.png, and changed
pixels are painted red in a diff next to them (report.html).

  tools/isomer/snapshots/snapshots.py run [--targets a,b] [--screens x,y]   capture + compare
  tools/isomer/snapshots/snapshots.py accept <run dir> [--targets] [--screens]   captures become the references

Targets:
  web-mobile   the web client in Mobile Safari, on an iOS simulator
  ios          blue's iPhone app (the WasmKit one), on an iPhone 17 with iOS 27,
               pictured by tests/isomer_ios_fixture as red's CI pictures red's, so
               the review server holds each picture against red's (parity)
  ios-landscape  the same, on its side (filed as target ios, landscape)
  red-ios      red Visor's iOS app on web-mobile's simulator, for a look at
               red beside blue here (not published: red's runs are its own)
  android      the Android app, on the hermetic emulator (booted if none)
  android-lab  the Android app on the device lab's phone, inside a lease:
               `device-lab run --device pixel-3a -- tools/isomer/snapshots/snapshots.py
               run --targets android-lab` (ANDROID_SERIAL and the lab's adb
               from the lease); its own references, the phone's screen size;
               held in portrait, however the phone lies
  android-lab-landscape  the same, held in landscape (references of its own)
  web-desktop  the web client in desktop Safari, on a Mac leased from oss
               (`visor machine` in a Visor session, `oss machine` outside
               one), driven by safaridriver there
  macos        the macOS app, on the same lease, its window cropped from the
               machine's screenshot

Nothing here touches this Mac's own screen: Safari and the Mac app run on the
leased Mac, the iOS targets in the simulator, Android in the emulator or the lab's
phone (never a person's own). Exit status is
1 when anything changed or failed, so a merge can be held on it.
"""
import argparse, atexit, functools, http.server, json, os, plistlib, re, shlex, shutil, socket, subprocess, sys, threading, time, urllib.request, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, HERE)
import pngdiff

REFERENCES = os.path.join(ROOT, "tests", "snapshots")
TARGETS = ["web-mobile", "ios", "ios-landscape", "android", "web-desktop", "macos"]
SCREENS = ["sessions", "chat", "inspector", "models", "search", "connect", "goal", "earlier", "question", "new-session", "commands"]
IOS_BUNDLE = "com.LoganShire.VisorClient.iOS"
ANDROID_PACKAGE = "com.loganshire.visor"
# The harness's own simulator, by name: made if missing, booted for the run and
# shut down after it. Never whatever happens to be booted, which can be
# another session's device.
SIMULATOR_NAME = os.environ.get("VISOR_SNAPSHOT_SIMULATOR", "visor-snapshots")
SIMULATOR_TYPE = os.environ.get("VISOR_SNAPSHOT_SIMULATOR_TYPE", "iPhone 17 Pro")
# desktop Safari's site on this Mac's loopback and safaridriver's port here,
# both carried to and from the leased Mac over SSH
WEB_DESKTOP_PORT = int(os.environ.get("VISOR_SNAPSHOT_WEB_PORT", "8791"))
WEB_DRIVER_PORT = int(os.environ.get("VISOR_SNAPSHOT_DRIVER_PORT", "4444"))
# Safari's bottom toolbar on the iPhone simulator, in screenshot pixels.
SAFARI_TOOLBAR = int(os.environ.get("VISOR_SNAPSHOT_SAFARI_TOOLBAR", "300"))
# The emulator's status bar (24dp at 2.625x), in screenshot pixels.
ANDROID_STATUS_BAR = int(os.environ.get("VISOR_SNAPSHOT_ANDROID_STATUS_BAR", "80"))
SETTLE = float(os.environ.get("VISOR_SNAPSHOT_SETTLE", "8"))

def log(*parts): print("[snapshots]", *parts, flush=True)

# Each screen's recording (its launch and settle) beside its capture, as
# <screen>.mp4, with --record. Off by default: snapshots are reviewed as
# pictures, recordings come from the UI tests only (2026-10-17).
RECORD = False

class SimulatorRecording:
    """`simctl io recordVideo` for one screen: started before the screen is
    opened, stopped (SIGINT, which finishes the file) after its capture."""
    def __init__(self, udid, out):
        self.out = out
        self.process = subprocess.Popen(["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", out],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if RECORD else None
        if self.process: time.sleep(1)
    def stop(self):
        if not self.process: return
        self.process.send_signal(2)
        try: self.process.wait(timeout=20)
        except subprocess.TimeoutExpired: self.process.kill()

class AndroidRecording:
    """`screenrecord` on the device for one screen, at half the screen's size
    (a phone's encoder may refuse its full one), pulled beside the capture."""
    REMOTE = "/sdcard/visor-snapshot.mp4"
    def __init__(self, a, out, seconds):
        self.a, self.out, self.process = a, out, None
        if not RECORD: return
        size = re.search(r"(\d+)x(\d+)", sh(a + ["shell", "wm", "size"], check=False).stdout or "")
        half = f"{int(size.group(1)) // 2 // 2 * 2}x{int(size.group(2)) // 2 // 2 * 2}" if size else "540x960"
        self.process = subprocess.Popen(a + ["shell", "screenrecord", "--time-limit", str(int(seconds)), "--size", half, self.REMOTE],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
    def stop(self):
        if not self.process: return
        try: self.process.wait(timeout=30)
        except subprocess.TimeoutExpired: self.process.kill()
        time.sleep(1)
        sh(self.a + ["pull", self.REMOTE, self.out], check=False)
        sh(self.a + ["shell", "rm", "-f", self.REMOTE], check=False)

def remove(path):
    """Removes a directory copied out of Bazel's (read-only) outputs."""
    if os.path.exists(path):
        subprocess.run(["chmod", "-R", "u+w", path], check=False)
        shutil.rmtree(path, ignore_errors=True)

def sh(cmd, check=True, **kw):
    return subprocess.run(cmd, shell=isinstance(cmd, str), check=check, text=True, capture_output=True, cwd=kw.pop("cwd", ROOT), **kw)

# Extra Bazel flags for every build (e.g. an --override_module to test a
# change to a dependency before it is pinned).
EXTRA_FLAGS = os.environ.get("VISOR_SNAPSHOT_BAZEL_FLAGS", "").split()

def bazel_output(target, *flags, suffix=""):
    flags = (*flags, *EXTRA_FLAGS)
    sh(["bazel", "build", *flags, target])
    files = sh(["bazel", "cquery", *flags, "--output=files", target]).stdout.split()
    return next(os.path.join(ROOT, f) for f in files if f.endswith(suffix))

# --- the web site, served on the loopback (to a simulator, or the leased Mac over SSH)

def serve(directory, host, port):
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def end_headers(self):
            self.send_header("Cache-Control", "no-store"); super().end_headers()
        def log_message(self, *args): pass
        extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map, ".wasm": "application/wasm", ".js": "text/javascript"}
    # A backlog past socketserver's 5: the page asks for a dozen runtime
    # modules at once, and a reset one leaves it blank with no error.
    class Server(http.server.ThreadingHTTPServer):
        request_queue_size = 128
    server = Server((host, port), functools.partial(Quiet, directory=directory))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server

@functools.lru_cache(None)
def web_site():
    site = bazel_output("//applications/visor_web:visor_web_site", "-c", "opt")
    copy = "/tmp/visor-snapshot-site"
    remove(copy)
    shutil.copytree(site, copy)
    return copy

def web_url(base, screen):
    return f"{base}/?fixture=snapshot&screen={screen}&t={int(time.time() * 1000)}"

# --- the iOS simulator (the harness's own, booted once per run)

_simulator = None

def simulator():
    global _simulator
    if _simulator:
        return _simulator
    listing = json.loads(sh("xcrun simctl list -j").stdout)
    all_devices = [d for runtime in listing["devices"].values() for d in runtime if d.get("isAvailable")]
    device = next((d for d in all_devices if d["name"] == SIMULATOR_NAME), None)
    if device is None:
        kind = next(t["identifier"] for t in listing["devicetypes"] if t["name"] == SIMULATOR_TYPE)
        runtime = [r for r in listing["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]][-1]["identifier"]
        log(f"creating the simulator {SIMULATOR_NAME} ({SIMULATOR_TYPE})")
        udid = sh(["xcrun", "simctl", "create", SIMULATOR_NAME, kind, runtime]).stdout.strip()
        state = "Shutdown"
    else:
        udid, state = device["udid"], device["state"]
    if state != "Booted":
        sh(["xcrun", "simctl", "boot", udid])
        atexit.register(lambda: sh(["xcrun", "simctl", "shutdown", udid], check=False))
    sh(["xcrun", "simctl", "bootstatus", udid, "-b"])
    sh(["xcrun", "simctl", "ui", udid, "appearance", "light"])
    sh(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
        "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
        "--batteryState", "charged", "--batteryLevel", "100"])
    _simulator = udid
    return udid

class WebMobile:
    describe = {"app": "Visor Isomer", "device": "Mobile Safari, iOS simulator (iPhone 17 Pro)", "orientation": "portrait"}

    def prepare(self):
        self.udid = simulator()
        self.server = serve(web_site(), "127.0.0.1", 8791)
        # One load to warm Safari up: the first load of a fresh site (the
        # wasm compiled, the modules fetched) outlasts the settle and came
        # out blank.
        sh(["xcrun", "simctl", "openurl", self.udid, web_url("http://localhost:8791", "sessions")])
        time.sleep(SETTLE * 2)
    def capture(self, screen, out):
        recording = SimulatorRecording(self.udid, out[:-4] + ".mp4")
        sh(["xcrun", "simctl", "openurl", self.udid, web_url("http://localhost:8791", screen)])
        time.sleep(SETTLE)
        # The display's mask (its corners and the Dynamic Island) drawn black:
        # unmasked, the island shows or not with whatever the system is doing.
        sh(["xcrun", "simctl", "io", self.udid, "screenshot", "--mask=black", out])
        recording.stop()
        # The page only: Safari's toolbar (its tab count grows with every
        # capture, and a load-progress line comes and goes) is not the app.
        pngdiff.crop_bottom(out, SAFARI_TOOLBAR)
    def finish(self):
        self.server.shutdown()

class RedIOS:
    # Red Visor, the reference blue is held to.
    describe = {"app": "Visor", "device": "iOS simulator (iPhone 17 Pro)", "orientation": "portrait"}

    def prepare(self):
        self.udid = simulator()
        # Launched after Safari, the app shows a "◀ Safari" back link.
        sh(["xcrun", "simctl", "terminate", self.udid, "com.apple.mobilesafari"], check=False)
        ipa = bazel_output("//applications/visor_ios:visor_ios", "--ios_multi_cpus=sim_arm64", suffix=".ipa")
        unpacked = "/tmp/visor-snapshot-ios"
        remove(unpacked)
        zipfile.ZipFile(ipa).extractall(unpacked)
        app = os.path.join(unpacked, "Payload", next(n for n in os.listdir(os.path.join(unpacked, "Payload")) if n.endswith(".app")))
        with open(os.path.join(app, "Info.plist"), "rb") as f:
            info = plistlib.load(f)
        self.version = f'{info.get("CFBundleShortVersionString", "?")} ({info.get("CFBundleVersion", "?")})'
        sh(["xcrun", "simctl", "install", self.udid, app])
    def capture(self, screen, out):
        recording = SimulatorRecording(self.udid, out[:-4] + ".mp4")
        sh(["xcrun", "simctl", "launch", "--terminate-running-process", self.udid, IOS_BUNDLE,
            "-visor.fixture", "snapshot", "-visor.fixture.screen", screen])
        # The whole settle: a sheet's Liquid Glass buttons are still easing
        # in at half of it.
        time.sleep(SETTLE)
        # The display's mask (its corners and the Dynamic Island) drawn black:
        # unmasked, the island shows or not with whatever the system is doing.
        sh(["xcrun", "simctl", "io", self.udid, "screenshot", "--mask=black", out])
        recording.stop()
    def finish(self):
        sh(["xcrun", "simctl", "terminate", self.udid, IOS_BUNDLE], check=False)

class IOS:
    """Blue's iPhone app, its fixture screens pictured by tests/isomer_ios_fixture
    (an XCUITest that takes them as red's probe takes red's) on a
    simulator the test's runner makes for the run and deletes after: an
    iPhone 17 on iOS 27 with red's CI status bar, so each picture can be
    held against red's same-named one. One test run pictures every screen;
    `capture` hands each picture over."""
    describe = {"app": "Visor Isomer", "device": "iOS simulator (iPhone 17, iOS 27)", "orientation": "portrait"}
    # What the review store files it as: red's iPhone runs are target ios
    # in each orientation.
    manifest_target = "ios"
    case = "BlueFixtureShots/testFixtureScreens"
    pictures = "/private/tmp/visor_isomer_fixture"

    def prepare(self):
        remove(self.pictures)
        done = subprocess.run(["bazel", "test", "-c", "opt", "--ios_multi_cpus=sim_arm64", *EXTRA_FLAGS,
                               "//tests/isomer_ios_fixture:fixture_shots", "--spawn_strategy=local", "--nocache_test_results",
                               "--test_output=errors", f"--test_filter={self.case}",
                               # No simulator diagnostics gathered after the
                               # test (minutes, and read as a hang).
                               "--test_arg=--xcodebuild_args=-collect-test-diagnostics", "--test_arg=--xcodebuild_args=never"],
                              cwd=ROOT, capture_output=True, text=True)
        self.log = done.stdout + done.stderr
        simulator = os.path.join(self.pictures, "simulator.txt")
        if os.path.exists(simulator):
            log(f"{self.manifest_target} fixture simulator: {open(simulator).read().strip()}")
        if done.returncode != 0:
            log("ios fixture probe failed:", " | ".join(l for l in self.log.splitlines() if "error:" in l and "warning" not in l)[-600:])
            if not os.path.isdir(self.pictures):
                raise RuntimeError("the fixture probe took no pictures")
    def capture(self, screen, out):
        picture = os.path.join(self.pictures, f"fixture-{screen}.png")
        if not os.path.exists(picture):
            raise RuntimeError(f"no picture of {screen}")
        shutil.copy(picture, out)
    def check(self, screen):
        # The probe's own check: the search's matches in messages came.
        if screen == "search" and "the search found no messages" in self.log:
            return ["the search found no messages"]
        return []
    def finish(self):
        pass

class IOSLandscape(IOS):
    describe = {**IOS.describe, "orientation": "landscape"}
    case = "BlueFixtureShots/testFixtureScreensLandscape"

# --- the Android emulator

def adb():
    found = sh(f"find -L \"$(bazel info output_base)/external\" -maxdepth 4 -path '*androidsdk*platform-tools*' -name adb -type f 2>/dev/null | head -1").stdout.strip()
    return found or "adb"

class Android:
    describe = {"app": "Visor Isomer", "device": "Android emulator (API 34)", "orientation": "portrait"}

    def prepare(self):
        self.adb = adb()
        devices = [l for l in sh([self.adb, "devices"]).stdout.splitlines()[1:] if l.strip().endswith("device")]
        # Its own emulator only (5554): another session's (on another port)
        # is that session's, however it was found.
        emulators = [l.split()[0] for l in devices if l.startswith("emulator-5554")]
        self.started = None
        if not emulators:
            # The hermetic emulator, headless (never a physical phone: its
            # screen and state are its owner's, not the test's).
            self.started = subprocess.Popen(["bazel", "run", "@isomer//tools/android/emulator", "--", "-no-window", "-no-audio", "-port", "5554"],
                                            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for _ in range(200):
                time.sleep(3)
                out = sh([self.adb, "-s", "emulator-5554", "shell", "getprop", "sys.boot_completed"], check=False).stdout.strip()
                if out == "1": break
            emulators = ["emulator-5554"]
        self.serial = emulators[0]
        self.status_bar = ANDROID_STATUS_BAR
        self.setup()

    def setup(self):
        a = [self.adb, "-s", self.serial, "shell"]
        sh(a + ["cmd", "uimode", "night", "no"])
        # A fixed status bar (System UI demo mode): 9:41, Wi-Fi and a full battery.
        # The cellular network is hidden, since the emulator draws a shown one
        # differently from run to run, and the whole sequence goes twice, a few
        # seconds apart, since SystemUI may still be settling just after boot.
        sh(a + ["settings", "put", "global", "sysui_demo_allowed", "1"])
        for attempt in range(2):
            if attempt: time.sleep(4)
            for extras in (["-e", "command", "exit"], ["-e", "command", "enter"],
                           ["-e", "command", "clock", "-e", "hhmm", "0941"],
                           ["-e", "command", "battery", "-e", "level", "100", "-e", "plugged", "false"],
                           ["-e", "command", "network", "-e", "wifi", "show", "-e", "level", "4", "-e", "fully", "true"],
                           ["-e", "command", "network", "-e", "mobile", "hide"],
                           ["-e", "command", "network", "-e", "nosim", "hide"],
                           ["-e", "command", "notifications", "-e", "visible", "false"]):
                sh(a + ["am", "broadcast", "-a", "com.android.systemui.demo"] + extras)
        apk = bazel_output("//applications/visor_android:visor_android_apk", "-c", "opt", suffix=".apk")
        if apk.endswith("_unsigned.apk"):
            apk = apk.replace("_unsigned.apk", ".apk")
        sh([self.adb, "-s", self.serial, "install", "-r", apk])
    def capture(self, screen, out):
        recording = AndroidRecording([self.adb, "-s", self.serial], out[:-4] + ".mp4", SETTLE + 2)
        sh([self.adb, "-s", self.serial, "shell", "am", "start", "-S", "-n", f"{ANDROID_PACKAGE}/.MainActivity",
            "--es", "fixture", "snapshot", "--es", "fixture.screen", screen])
        time.sleep(SETTLE)
        with open(out, "wb") as f:
            subprocess.run([self.adb, "-s", self.serial, "exec-out", "screencap", "-p"], stdout=f, check=True)
        recording.stop()
        # Below the status bar: its icons redraw between runs even in demo mode.
        pngdiff.crop_top(out, self.status_bar)
    def check(self, screen):
        """What the screen must show besides its picture: for `earlier`, the
        page of earlier rows has come in above and the rows that were there
        are still on screen (rows put in above leave the reader where they
        were). Returns the problems found."""
        if screen != "earlier":
            return []
        a = [self.adb, "-s", self.serial]
        sh(a + ["shell", "uiautomator", "dump", "/sdcard/visor-snapshot-ui.xml"], check=False)
        dump = sh(a + ["shell", "cat", "/sdcard/visor-snapshot-ui.xml"], check=False).stdout
        problems = []
        for text in ("Earlier row 199", "Start on this.", "Drafted the notes for 2.4 with the three fixes."):
            if f'text="{text}"' not in dump:
                problems.append(f"{text!r} is not on screen")
        return problems
    def finish(self):
        sh([self.adb, "-s", self.serial, "shell", "am", "broadcast", "-a", "com.android.systemui.demo", "-e", "command", "exit"], check=False)
        if self.started:
            sh([self.adb, "-s", self.serial, "emu", "kill"], check=False)

class AndroidLab(Android):
    describe = {"app": "Visor Isomer", "device": "Pixel 3a, Android 12 (device lab)", "orientation": "portrait"}

    """The device lab's phone, leased by `device-lab run`, which sets
    ANDROID_SERIAL and points adb at the lab (ADB_SERVER_SOCKET). Never an
    emulator, never a phone without a lease. The lab resets the phone and
    takes the app off it when the lease ends. Held in `rotation` (0
    portrait, 1 landscape) with the sensor off, whichever way the phone lies
    on the desk: portrait is the one that matters, landscape is checked too."""
    rotation = 0

    def prepare(self):
        self.adb = adb()
        self.serial = os.environ.get("ANDROID_SERIAL", "")
        if not self.serial or not os.environ.get("ADB_SERVER_SOCKET"):
            raise SystemExit("android-lab runs inside a device-lab lease: device-lab run --device <phone> -- " + " ".join(sys.argv))
        self.started = None
        # The status bar's 24dp at the phone's density (the emulator's 80px
        # is at 420dpi).
        density = sh([self.adb, "-s", self.serial, "shell", "wm", "density"], check=False).stdout.split()[-1:] or ["420"]
        self.status_bar = round(ANDROID_STATUS_BAR * int(density[0]) / 420)
        # The lab keeps a leased phone awake; unlocked all the same.
        self.wake()
        self.hold(self.rotation)
        self.setup()

    def hold(self, rotation):
        # The window manager's lock (what turns a running app), and the
        # settings it keeps, for a system without the command.
        a = [self.adb, "-s", self.serial, "shell"]
        sh(a + ["wm", "user-rotation", "lock", str(rotation)], check=False)
        sh(a + ["settings", "put", "system", "accelerometer_rotation", "0"], check=False)
        sh(a + ["settings", "put", "system", "user_rotation", str(rotation)], check=False)
        time.sleep(2)

    def wake(self):
        # The lab keeps a leased phone awake. No key event here: a key takes
        # the phone out of touch mode, and the first text field then takes
        # the focus (in landscape the sidebar's search field went to its
        # active look in some runs and not others).
        sh([self.adb, "-s", self.serial, "shell", "wm", "dismiss-keyguard"], check=False)

    def capture(self, screen, out):
        # The hold again with the app in front: the phone's home screen is
        # portrait only, and a hold made over it did not turn the app.
        self.wake()
        recording = AndroidRecording([self.adb, "-s", self.serial], out[:-4] + ".mp4", SETTLE + 6)
        sh([self.adb, "-s", self.serial, "shell", "am", "start", "-S", "-n", f"{ANDROID_PACKAGE}/.MainActivity",
            "--es", "fixture", "snapshot", "--es", "fixture.screen", screen])
        # Turned early, as a hand turns it: the runtime hears the new size
        # (it built for the old one until isomer 88dc09ec: a compact sidebar
        # in a regular split view).
        time.sleep(2)
        self.hold(self.rotation)
        time.sleep(SETTLE)
        with open(out, "wb") as f:
            subprocess.run([self.adb, "-s", self.serial, "exec-out", "screencap", "-p"], stdout=f, check=True)
        recording.stop()
        pngdiff.crop_top(out, self.status_bar)

    def finish(self):
        super().finish()
        # Back to portrait, the lab's own hold.
        self.hold(0)

class AndroidLabLandscape(AndroidLab):
    rotation = 1
    describe = {**AndroidLab.describe, "orientation": "landscape"}

    def check(self, screen):
        # The `earlier` check wants the page put in above and the rows that
        # were there on screen together: a portrait screen's height. In
        # landscape the picture is the check.
        return []

# --- a Mac leased from oss (desktop Safari and the Mac app): through `visor
# machine` in a Visor session, `oss machine` outside one; one lease for the
# run, released when it ends

def machine():
    return ["visor", "machine"] if os.environ.get("VISOR_SESSION") else ["oss", "machine"]

@functools.lru_cache(None)
def mac_lease():
    if machine()[0] == "visor":
        lease = json.loads(sh(machine() + ["lease", "macos", "--json"]).stdout)
    else:
        # oss's own lease JSON leaves the host to its client: its exports say it.
        exports = sh(machine() + ["lease", "macos", "--exports"]).stdout
        values = dict(line[len("export "):].split("=", 1) for line in exports.splitlines() if line.startswith("export "))
        values = {key: (shlex.split(value) or [""])[0] for key, value in values.items()}
        lease = {"id": values["OSS_ID"], "host": values["OSS_HOST"], "sshPort": values["OSS_SSH_PORT"], "sshUser": values["OSS_SSH_USER"]}
    atexit.register(lambda: sh(machine() + ["release", lease["id"]], check=False))
    log("leased a Mac:", lease["id"])
    mac = {"id": lease["id"], "target": f"{lease['sshUser']}@{lease['host']}", "port": str(lease["sshPort"])}
    # The dark look, said outright: the lease's image runs dark, and turning a
    # running session light takes System Events and a consent no one is there
    # to give; said here, a session started again stays dark too.
    sh(guest_ssh(mac) + ["defaults write -g AppleInterfaceStyle -string Dark; defaults write -g AppleInterfaceStyleSwitchesAutomatically -bool false"])
    return mac

def guest_ssh(mac, *options):
    return ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR", "-p", mac["port"], *options, mac["target"]]

def guest(command, check=True):
    """A command in the leased Mac (its login session's, with `as_user`)."""
    return sh(guest_ssh(mac_lease()) + [command], check=check)

def as_user(command):
    return f"sudo -n launchctl asuser $(id -u) {command}"

class WebDesktop:
    describe = {"app": "Visor Isomer", "device": "Safari, macOS (an oss lease)", "orientation": ""}

    """Desktop Safari on a leased Mac, through safaridriver (WebDriver): a fixed
    window size and a screenshot of the page alone, without Safari's chrome.
    One SSH connection runs safaridriver in the guest's login session, forwards
    its port here, and forwards the site, served on this Mac's loopback, to the
    guest's: whatever network the guest is on."""
    def prepare(self):
        self.server = serve(web_site(), "127.0.0.1", WEB_DESKTOP_PORT)
        guest("sudo -n safaridriver --enable; pkill -x safaridriver; pkill -x Safari; true")
        self.tunnel = subprocess.Popen(guest_ssh(mac_lease(), "-o", "ExitOnForwardFailure=yes",
                                                 "-L", f"{WEB_DRIVER_PORT}:127.0.0.1:4444",
                                                 "-R", f"{WEB_DESKTOP_PORT}:127.0.0.1:{WEB_DESKTOP_PORT}")
                                       + [as_user("/usr/bin/safaridriver -p 4444")])
        for _ in range(30):
            try:
                if self.webdriver("GET", "/status").get("ready"): break
            except Exception:
                pass
            time.sleep(1)
        self.session = self.webdriver("POST", "/session", {"capabilities": {"alwaysMatch": {"browserName": "safari"}}})["sessionId"]
        self.webdriver("POST", f"/session/{self.session}/window/rect", {"width": 1280, "height": 860, "x": 0, "y": 0})
    def webdriver(self, method, path, body=None):
        request = urllib.request.Request(f"http://127.0.0.1:{WEB_DRIVER_PORT}" + path, method=method,
                                         data=None if body is None else json.dumps(body).encode(), headers={"Content-Type": "application/json"})
        return json.loads(urllib.request.urlopen(request, timeout=60).read())["value"]
    def capture(self, screen, out):
        self.webdriver("POST", f"/session/{self.session}/url", {"url": web_url(f"http://127.0.0.1:{WEB_DESKTOP_PORT}", screen)})
        time.sleep(SETTLE)
        import base64
        with open(out, "wb") as f:
            f.write(base64.b64decode(self.webdriver("GET", f"/session/{self.session}/screenshot")))
    def finish(self):
        try: self.webdriver("DELETE", f"/session/{self.session}")
        except Exception: pass
        self.tunnel.terminate()
        guest("pkill -x safaridriver; pkill -x Safari; true", check=False)
        self.server.shutdown()
        self.server.server_close()

# The windows on the guest's screen, from CGWindowList (no permission needed
# for owners and frames): "owner layer x y width height", one a line.
WINDOWS_JS = """ObjC.import('CoreGraphics');
const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
const out = [];
for (let i = 0; i < list.count; i++) {
  const w = list.objectAtIndex(i), b = w.objectForKey('kCGWindowBounds');
  out.push([ObjC.unwrap(w.objectForKey('kCGWindowOwnerName')), ObjC.unwrap(w.objectForKey('kCGWindowLayer'))]
    .concat(['X', 'Y', 'Width', 'Height'].map(k => ObjC.unwrap(b.objectForKey(k)))).join('\\t'));
}
out.join('\\n');"""

class MacOS:
    # Red Visor's Mac app.
    describe = {"app": "Visor", "device": "macOS (an oss lease)", "orientation": ""}

    """The Mac app on a leased Mac: the machine's screenshot (its own, taken
    from outside the guest, so no permission in it), cropped to the app's
    window as CGWindowList gives its frame (no menu bar, Dock or wallpaper)."""
    def prepare(self):
        archive = bazel_output("//applications/visor_macos:visor_macos", suffix=".zip")
        unpacked = "/tmp/visor-snapshot-macos"
        remove(unpacked)
        zipfile.ZipFile(archive).extractall(unpacked)
        self.app = os.path.join(unpacked, next(n for n in os.listdir(unpacked) if n.endswith(".app")))
        # zipfile drops the executable bits
        sh(["chmod", "-R", "u+x", os.path.join(self.app, "Contents", "MacOS")])
        mac = mac_lease()
        guest("pkill -x Visor; rm -rf ~/Applications/Visor.app; mkdir -p ~/Applications", check=False)
        subprocess.run(guest_ssh(mac) + ["cat > /tmp/windows.js"], input=WINDOWS_JS.encode(), check=True)
        subprocess.run(["scp", "-rq", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                        "-o", "LogLevel=ERROR", "-P", mac["port"], self.app, f"{mac['target']}:Applications/Visor.app"], check=True)
    def capture(self, screen, out):
        # A fresh window each time: no restored frame or state.
        guest("pkill -x Visor; sleep 1; rm -rf ~/Library/Saved\\ Application\\ State/com.LoganShire.VisorClient.macOS.savedState; "
              "defaults delete com.LoganShire.VisorClient.macOS 'NSWindow Frame main' 2>/dev/null; "
              + as_user(f"open ~/Applications/Visor.app --args -visor.fixture snapshot -visor.fixture.screen {screen}"), check=False)
        time.sleep(SETTLE)
        windows = guest(as_user("osascript -l JavaScript /tmp/windows.js")).stdout.splitlines()
        rows = [line.split("\t") for line in windows]
        # The app's largest window: its main one, with any sheet over it (a
        # sheet is a window of its own, in front).
        x, y, width, height = max((tuple(int(float(v)) for v in row[2:6]) for row in rows if row[:2] == ["Visor", "0"]),
                                  key=lambda frame: frame[2] * frame[3])
        # The menu bar spans the screen: its width in points against the
        # screenshot's in pixels is the screen's scale.
        points = next(int(float(row[4])) for row in rows if row[0] == "Window Server")
        whole = out + ".screen.png"
        sh(machine() + ["screenshot", mac_lease()["id"], whole])
        pixels = int(sh(["sips", "-g", "pixelWidth", whole]).stdout.split()[-1])
        scale = pixels // points
        sh(["sips", "--cropToHeightWidth", str(height * scale), str(width * scale),
            "--cropOffset", str(y * scale), str(x * scale), whole, "--out", out])
        remove(whole)
    def finish(self):
        guest("pkill -x Visor; true", check=False)

KINDS = {"web-mobile": WebMobile, "ios": IOS, "ios-landscape": IOSLandscape, "red-ios": RedIOS, "android": Android, "android-lab": AndroidLab,
         "android-lab-landscape": AndroidLabLandscape, "web-desktop": WebDesktop, "macos": MacOS}

def blue_version():
    """The version blue reports (the web client's, as every blue build here
    carries the same)."""
    with open(os.path.join(ROOT, "applications", "visor_web", "index.html")) as f:
        found = re.search(r'"host.appVersion": "([^"]+)"', f.read())
    return found.group(1) if found else "?"

def write_manifest(run_dir, target, kind, rows, started):
    """The target's results as the review server reads them (AttilaTheFun/
    releases' reviews/MANIFEST.md): run_dir/<target>/manifest.json."""
    describe = dict(getattr(kind, "describe", {"app": "Visor Isomer"}))
    version = getattr(kind, "version", None) or blue_version()
    commit = sh(["git", "rev-parse", "HEAD"], check=False).stdout.strip()
    items = []
    for (_, screen, status, changed, reference, capture, diff) in rows:
        item = {"name": screen, "status": status, "changed_px": int(changed or 0)}
        if reference:
            # A copy in the run, so the run stands alone wherever it is
            # reviewed (the review server has no checkout of this repo).
            os.makedirs(os.path.join(run_dir, target, "reference"), exist_ok=True)
            shutil.copy(reference, os.path.join(run_dir, target, "reference", f"{screen}.png"))
            item["reference"] = f"reference/{screen}.png"
        if capture: item["capture"] = os.path.relpath(capture, os.path.join(run_dir, target))
        if diff: item["diff"] = os.path.relpath(diff, os.path.join(run_dir, target))
        video = os.path.join(run_dir, target, f"{screen}.mp4")
        if os.path.exists(video): item["video"] = f"{screen}.mp4"
        items.append(item)
    manifest = {"schema": 1, **describe, "version": version, "release": version.split(" ")[0],
                "commit": commit, "kind": "snapshots", "target": getattr(kind, "manifest_target", target),
                "started": started, "items": items}
    with open(os.path.join(run_dir, target, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)

def run(targets, screens):
    # VISOR_SNAPSHOT_RUN_DIR: where the run goes (CI keeps it as an artifact);
    # by default a new folder under /tmp/visor-snapshots.
    run_dir = os.environ.get("VISOR_SNAPSHOT_RUN_DIR") or f"/tmp/visor-snapshots/{time.strftime('%Y%m%d-%H%M%S')}"
    # Two runs at once (the lab's phone and this Mac's targets) can start in
    # the same second.
    if os.path.exists(run_dir):
        run_dir += f"-{os.getpid()}"
    os.makedirs(run_dir)
    results, failed = [], False
    for target in targets:
        os.makedirs(os.path.join(run_dir, target), exist_ok=True)
        kind = KINDS[target]()
        first = len(results)
        started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        log(target, "preparing")
        try:
            kind.prepare()
        except Exception as error:
            log(target, "couldn't start:", error)
            results.append((target, "*", "failed", "0", "", "", ""))
            failed = True
            continue
        try:
            for screen in screens:
                capture = os.path.join(run_dir, target, f"{screen}.png")
                try:
                    kind.capture(screen, capture)
                except Exception as error:
                    log(target, screen, "failed:", error)
                    results.append((target, screen, "failed", "0", "", "", ""))
                    failed = True
                    continue
                problems = kind.check(screen) if hasattr(kind, "check") else []
                if problems:
                    log(target, screen, "check failed:", "; ".join(problems))
                    results.append((target, screen, "failed", "0", "", capture, ""))
                    failed = True
                    continue
                reference = os.path.join(REFERENCES, target, f"{screen}.png")
                if not os.path.exists(reference):
                    results.append((target, screen, "new", "0", "", capture, ""))
                    failed = True
                    log(target, screen, "new (no reference yet)")
                    continue
                diff = os.path.join(run_dir, target, f"{screen}.diff.png")
                changed = pngdiff.compare(reference, capture, diff)
                if changed:
                    # A second look: a screen pictured before it settled (a
                    # menu not yet up on a busy runner) differs once; a real
                    # change differs again.
                    log(target, screen, f"changed {changed} px; a second look")
                    try:
                        kind.capture(screen, capture)
                        changed = pngdiff.compare(reference, capture, diff)
                    except Exception as error:
                        log(target, screen, "second look failed:", error)
                status = "same" if changed == 0 else "changed"
                failed |= changed > 0
                results.append((target, screen, status, str(changed), reference, capture, diff if changed else ""))
                log(target, screen, status, f"{changed} px" if changed else "")
        finally:
            kind.finish()
            write_manifest(run_dir, target, kind, results[first:], started)
    with open(os.path.join(run_dir, "results.tsv"), "w") as f:
        for row in results: f.write("\t".join(row) + "\n")
    pngdiff.report(run_dir)
    log("report:", os.path.join(run_dir, "report.html"))
    log(f"to accept: tools/isomer/snapshots/snapshots.py accept {run_dir}")
    return 1 if failed else 0

def accept(run_dir, targets, screens):
    for target in targets:
        for screen in screens:
            capture = os.path.join(run_dir, target, f"{screen}.png")
            if os.path.exists(capture):
                os.makedirs(os.path.join(REFERENCES, target), exist_ok=True)
                shutil.copy(capture, os.path.join(REFERENCES, target, f"{screen}.png"))
                log("accepted", target, screen)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["run", "accept"])
    parser.add_argument("run_dir", nargs="?")
    parser.add_argument("--targets", default=",".join(TARGETS))
    parser.add_argument("--screens", default=",".join(SCREENS))
    parser.add_argument("--record", action="store_true", help="record each screen too (for debugging)")
    args = parser.parse_args()
    RECORD = args.record
    targets, screens = args.targets.split(","), args.screens.split(",")
    if args.command == "run":
        sys.exit(run(targets, screens))
    accept(args.run_dir, targets, screens)
