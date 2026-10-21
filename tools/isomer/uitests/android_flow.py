#!/usr/bin/env python3
"""Blue Visor's UI test on Android: what a reader does, step by step, on the
device lab's phone (or this Mac's emulator), in portrait and in landscape,
each step recorded and its last screen kept, for the review server's store.

  device-lab run --device pixel-3a -- tools/isomer/uitests/android_flow.py --review <dir>
  tools/isomer/uitests/android_flow.py --review <dir>        # emulator-5554

It runs on visor's snapshot fixture (a canned computer, its sessions, a chat
with an approval waiting, a question), so it needs no server:
  sessions        the sessions list shows the fixture's computer and sessions
  open session    a tap on "Offline sync" opens its chat
  details         the details button (ⓘ) opens the session's details
  close details   Done (or Back) puts them away, the chat still there
  new session     the compose button opens New Session
  answer question the question sheet: Send is off until an option is picked,
                  then on; Send puts the sheet away
Each orientation is a ui-test manifest (target android-lab-flow or
android-flow) under <dir>, for tools/isomer/snapshots/publish_review.py. Exit 1 when
a step failed. VISOR_SNAPSHOT_BAZEL_FLAGS adds Bazel flags to the build, as
for the snapshots (an --override_module to test an unpinned dependency).
"""
import argparse, json, os, re, subprocess, sys, time
import xml.etree.ElementTree as ElementTree

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
PACKAGE = "com.loganshire.visor"
REMOTE = "/sdcard/visor-flow.mp4"
EXTRA_FLAGS = os.environ.get("VISOR_SNAPSHOT_BAZEL_FLAGS", "").split()


def sh(cmd, check=False):
    return subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, check=check, cwd=ROOT)


def adb_path():
    base = sh(["bazel", "info", "output_base"]).stdout.strip()
    found = sh(f'find -L "{base}/external" -maxdepth 4 -path "*androidsdk*platform-tools*" -name adb -type f | head -1').stdout.strip() \
        if base else ""
    return found or "adb"


def sh_shell(a, *args):
    return sh(a + ["shell", *args])


class Phone:
    def __init__(self, adb, serial):
        self.a = [adb, "-s", serial]

    def dump(self, windows=False):
        """The UI as XML: the app's window, or with `windows` every window on
        screen (a popup is one of its own: Isomer's floating menus)."""
        sh_shell(self.a, "uiautomator", "dump", *(["--windows"] if windows else []), "/sdcard/visor-flow.xml")
        return sh_shell(self.a, "cat", "/sdcard/visor-flow.xml").stdout

    def find(self, pattern, tries=20, windows=False):
        """The first node whose text or content-desc matches: its centre, and
        whether it is enabled, read from the nearest clickable node at or
        above it (Compose puts a button's words in a child of it)."""
        for _ in range(tries):
            try:
                root = ElementTree.fromstring(self.dump(windows))
            except ElementTree.ParseError:
                time.sleep(1)
                continue
            parents = {child: parent for parent in root.iter() for child in parent}
            for node in root.iter("node"):
                if not any(re.search(pattern, node.get(key) or "") for key in ("text", "content-desc")):
                    continue
                box = re.search(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
                if not box:
                    continue
                clickable = node
                while clickable is not None and clickable.get("clickable") != "true":
                    clickable = parents.get(clickable)
                enabled = (clickable if clickable is not None else node).get("enabled") == "true"
                x1, y1, x2, y2 = map(int, box.groups())
                return (x1 + x2) // 2, (y1 + y2) // 2, enabled
            time.sleep(1)
        return None

    def tap(self, pattern, tries=20, windows=False):
        found = self.find(pattern, tries, windows)
        if found:
            sh_shell(self.a, "input", "tap", str(found[0]), str(found[1]))
        return found is not None

    def shows(self, pattern, tries=20):
        return self.find(pattern, tries) is not None

    def hold(self, rotation):
        sh_shell(self.a, "wm", "user-rotation", "lock", str(rotation))
        sh_shell(self.a, "settings", "put", "system", "accelerometer_rotation", "0")
        sh_shell(self.a, "settings", "put", "system", "user_rotation", str(rotation))

    def start(self, screen, rotation):
        sh_shell(self.a, "am", "start", "-S", "-n", f"{PACKAGE}/.MainActivity", "--es", "fixture", "snapshot",
                 "--es", "fixture.screen", screen)
        time.sleep(3)
        # Held with the app in front: the home screen is portrait only.
        self.hold(rotation)
        time.sleep(5)

    def screenshot(self, out):
        with open(out, "wb") as f:
            subprocess.run(self.a + ["exec-out", "screencap", "-p"], stdout=f)


class Recording:
    """`screenrecord` for one step, at half the screen's size, pulled after."""
    def __init__(self, phone, out, seconds=40):
        self.phone, self.out = phone, out
        size = re.search(r"(\d+)x(\d+)", sh_shell(phone.a, "wm", "size").stdout or "")
        half = f"{int(size.group(1)) // 4 * 2}x{int(size.group(2)) // 4 * 2}" if size else "540x960"
        self.process = subprocess.Popen(phone.a + ["shell", "screenrecord", "--time-limit", str(seconds), "--size", half, REMOTE],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)

    def stop(self):
        # screenrecord finishes its file on SIGINT: sent on the device.
        sh_shell(self.phone.a, "pkill", "-INT", "screenrecord")
        try: self.process.wait(timeout=15)
        except subprocess.TimeoutExpired: self.process.kill()
        time.sleep(1)
        sh(self.phone.a + ["pull", REMOTE, self.out])
        sh_shell(self.phone.a, "rm", "-f", REMOTE)


def steps(phone, rotation):
    """(name, what it checks, the actions and checks): each returns ok, note."""
    def sessions():
        phone.start("sessions", rotation)
        return phone.shows(r"Snapshot Mac") and phone.shows(r"Offline sync"), "the computer and its sessions listed"
    def open_session():
        ok = phone.tap(r"^Offline sync") and phone.shows(r"Message Claude Code")
        return ok, "the chat with its composer"
    def details():
        ok = phone.tap(r"Session details") and phone.shows(r"^About$|Agent")
        return ok, "the details (About, Agent)"
    def close_details():
        if not phone.tap(r"^Done$", tries=5):
            sh_shell(phone.a, "input", "keyevent", "KEYCODE_BACK")
        time.sleep(2)
        return phone.shows(r"Message Claude Code") and not phone.shows(r"^About$", tries=2), "back to the chat"
    def new_session():
        phone.start("sessions", rotation)
        ok = phone.tap(r"New session|New Session|Compose") and phone.shows(r"New Session|Folder|Agent|Start", tries=15)
        return ok, "New Session open"
    def answer_question():
        phone.start("question", rotation)
        sheet = phone.shows(r"Which way should rows written offline go")
        send_before = phone.find(r"^Send$", tries=5)
        off = bool(send_before) and not send_before[2]
        picked = phone.tap(r"^On reconnect")
        time.sleep(1)
        send_after = phone.find(r"^Send$", tries=5)
        on = bool(send_after) and send_after[2]
        sent = phone.tap(r"^Send$")
        time.sleep(2)
        # The sheet's own parts gone (the question's words stay, in the
        # composer's waiting row, as red keeps them there).
        gone = not phone.shows(r"^On reconnect$|^Skip$", tries=2)
        note = f"sheet {sheet}, Send off before {off}, picked {picked}, Send on after {on}, sent and gone {sent and gone}"
        return sheet and off and picked and on and sent and gone, note
    return [("sessions", sessions), ("open session", open_session), ("details", details),
            ("close details", close_details), ("new session", new_session), ("answer question", answer_question)]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--review", required=True)
    parser.add_argument("--orientations", default="portrait,landscape")
    args = parser.parse_args()
    serial = os.environ.get("ANDROID_SERIAL", "emulator-5554")
    lab = not serial.startswith("emulator-")
    phone = Phone(adb_path(), serial)
    sh(["bazel", "build", "-c", "opt", *EXTRA_FLAGS, "//applications/visor_android:visor_android_apk"], check=True)
    apk = next(f for f in sh(["bazel", "cquery", "-c", "opt", "--output=files", *EXTRA_FLAGS,
                              "//applications/visor_android:visor_android_apk"]).stdout.split()
               if f.endswith(".apk") and "_unsigned" not in f)
    sh(phone.a + ["install", "-r", os.path.join(ROOT, apk)], check=True)
    sh_shell(phone.a, "wm", "dismiss-keyguard")
    index = open(os.path.join(ROOT, "applications", "visor_web", "index.html")).read()
    version = (re.search(r'"host.appVersion": "([^"]+)"', index) or [None, "?"])[1]
    commit = sh(["git", "rev-parse", "HEAD"]).stdout.strip()
    target = "android-lab-flow" if lab else "android-flow"
    failed = False
    try:
        for orientation in args.orientations.split(","):
            rotation = 1 if orientation == "landscape" else 0
            out = os.path.join(args.review, f"{target}-{orientation}")
            os.makedirs(out, exist_ok=True)
            items = []
            for name, step in steps(phone, rotation):
                slug = name.replace(" ", "-")
                recording = Recording(phone, os.path.join(out, f"{slug}.mp4"))
                try:
                    ok, note = step()
                except Exception as error:
                    ok, note = False, f"raised {error!r}"
                time.sleep(1)
                phone.screenshot(os.path.join(out, f"{slug}.png"))
                recording.stop()
                print(("[flow] ok    " if ok else "[flow] FAIL  ") + f"{orientation}: {name}: {note}", flush=True)
                failed |= not ok
                item = {"name": name, "status": "passed" if ok else "failed", "capture": f"{slug}.png", "notes": note}
                if os.path.exists(os.path.join(out, f"{slug}.mp4")):
                    item["video"] = f"{slug}.mp4"
                items.append(item)
            manifest = {"schema": 1, "app": "Visor Isomer", "version": version, "release": version.split(" ")[0], "commit": commit,
                        "kind": "ui-test", "target": target,
                        "device": "Pixel 3a, Android 12 (device lab)" if lab else "Android emulator (API 34)",
                        "orientation": orientation, "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "items": items}
            json.dump(manifest, open(os.path.join(out, "manifest.json"), "w"), indent=1)
    finally:
        phone.hold(0)
        sh_shell(phone.a, "am", "force-stop", PACKAGE)
    print("[flow] FAILED" if failed else "[flow] all passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
