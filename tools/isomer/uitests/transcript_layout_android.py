#!/usr/bin/env python3
"""What a transcript lays out wider than a phone, on Android: blue Visor,
freshly installed on this Mac's hermetic emulator (or the device lab's phone
under `device-lab run`), is connected by a visor:// link to stub_server.py
on this Mac (adb reverse) and opens two of its sessions.
- "Long lines": the code block (a connection code, one word of 220
  characters, and a line of words) wraps, as AgentUI's MarkdownText has it
  since 48cf89b: within the screen's width and as many lines tall as
  wrapping makes it. The UI dump's bounds are clipped to the screen, so a
  block left to scroll sideways would show as two lines.
- "Pictures": four phone screenshots in one message are wider together than
  it, so they are a carousel (AgentUI 9f9f753's ViewThatFits; as wide as the
  thread since 54eb84d): a scroller about a thumbnail tall holds all four,
  within the screen, and the
  message's words are on screen. Two in another fit: a row, in no scroller
  but the transcript's, at the trailing edge with their message. Thumbnails
  are found by their accessibility identifiers ("attachment-<name>"), which
  Isomer's Compose renderer gives UI Automator as resource ids.

  tools/isomer/uitests/transcript_layout_android.py                  # emulator-5554 (boots it if none)
  tools/isomer/uitests/transcript_layout_android.py --override_module=isomer=<checkout>   # bazel flags pass through
LAYOUT_SHOTS=<dir> keeps screenshots. Exit 1 when a check fails."""
import base64, json, os, random, re, subprocess, sys, time
from xml.etree import ElementTree

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from android_flow import Phone, adb_path, sh, sh_shell, ROOT, PACKAGE  # noqa: E402

CODE_START = r"^vsr1-eyJ2Ijox"
BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def bounds(node):
    return tuple(map(int, BOUNDS.search(node.get("bounds", "")).groups()))


def main():
    serial = os.environ.get("ANDROID_SERIAL", "emulator-5554")
    adb = adb_path()
    phone = Phone(adb, serial)
    started = None
    if serial.startswith("emulator-") and f"{serial}\tdevice" not in sh([adb, "devices"]).stdout:
        print("[layout] booting the hermetic emulator", flush=True)
        started = subprocess.Popen(["bazel", "run", "@isomer//tools/android/emulator", "--", "-no-window", "-no-audio", "-port", "5554"],
                                   cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(200):
            time.sleep(3)
            if sh_shell(phone.a, "getprop", "sys.boot_completed").stdout.strip() == "1":
                break
    flags = ["-c", "opt"] + sys.argv[1:]
    sh(["bazel", "build"] + flags + ["//applications/visor_web:visor_web_site", "//applications/visor_android:visor_android_apk"], check=True)
    site = sh(["bazel", "cquery"] + flags + ["--output=files", "//applications/visor_web:visor_web_site"]).stdout.split()[0]
    apk = next(f for f in sh(["bazel", "cquery"] + flags + ["--output=files", "//applications/visor_android:visor_android_apk"]).stdout.split()
               if f.endswith(".apk") and "_unsigned" not in f)
    port = 8600 + random.randrange(400)
    stub = subprocess.Popen([sys.executable, os.path.join(ROOT, "tools/isomer/e2e/stub_server.py"), os.path.join(ROOT, site), str(port)],
                            cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    failures = []

    def check(name, ok, got):
        print(("[layout] ok    " if ok else "[layout] FAIL  ") + name + ("" if ok else f": got {got!r}"), flush=True)
        if not ok:
            failures.append(name)
        return ok

    def shot(name):
        if os.environ.get("LAYOUT_SHOTS"):
            with open(os.path.join(os.environ["LAYOUT_SHOTS"], name + "-android.png"), "wb") as out:
                subprocess.run(phone.a + ["exec-out", "screencap", "-p"], stdout=out)

    def tree(until, tries=30):
        """The UI dump's root and the first that `until` finds in it."""
        for _ in range(tries):
            try:
                root = ElementTree.fromstring(phone.dump())
            except ElementTree.ParseError:
                time.sleep(1)
                continue
            found = until(root)
            if found is not None:
                return root, found
            time.sleep(1)
        return None, None

    try:
        sh(phone.a + ["uninstall", PACKAGE])
        sh(phone.a + ["install", "-r", os.path.join(ROOT, apk)], check=True)
        sh(phone.a + ["reverse", f"tcp:{port}", f"tcp:{port}"], check=True)
        sh_shell(phone.a, "wm", "dismiss-keyguard")
        code = {"v": 1, "name": "Stub", "host": f"http://127.0.0.1:{port}", "password": "", "auth": "none"}
        encoded = base64.urlsafe_b64encode(json.dumps(code).encode()).decode().rstrip("=")
        sh_shell(phone.a, "am", "start", "-a", "android.intent.action.VIEW", "-d", f"'visor://connect?code={encoded}'", PACKAGE)
        if phone.find(r"^Connect$", tries=8):
            phone.tap(r"^Connect$", tries=1)
        density = int(re.search(r"(\d+)\s*$", sh_shell(phone.a, "wm", "density").stdout.strip()).group(1)) / 160

        # 1. A code block's long lines wrap.
        if check('"Long lines" is listed', phone.tap(r"^Long lines$", tries=40), None):
            root, node = tree(lambda r: next((n for n in r.iter("node") if re.search(CODE_START, n.get("text") or "")), None))
            shot("code-block")
            if check("the code block shows in \"Long lines\"", node is not None, None):
                width = bounds(root.find("node"))[2]
                x1, y1, x2, y2 = bounds(node)
                lines = round((y2 - y1) / (13 * 1.3 * density))
                check("the code block keeps within the screen", x1 >= 0 and x2 <= width, (x1, x2, width))
                check("its long lines wrap (the code word and the line of words take several lines)", lines >= 6, (y2 - y1, lines))
            sh_shell(phone.a, "input", "keyevent", "KEYCODE_BACK")
            time.sleep(1)

        # 2. Pictures wider than their message are a carousel; ones that fit, a row.
        if check('"Pictures" is listed', phone.tap(r"^Pictures$", tries=30), None):
            def pictures(root):
                four = [n for n in root.iter("node") if (n.get("resource-id") or "").startswith("attachment-four-")]
                two = [n for n in root.iter("node") if (n.get("resource-id") or "").startswith("attachment-two-")]
                return (four, two) if four and len(two) == 2 else None
            root, found = tree(pictures)
            shot("pictures")
            if check("the pictures show in \"Pictures\"", found is not None, None):
                four, two = found
                parents = {child: parent for parent in root.iter() for child in parent}
                width = bounds(root.find("node"))[2]

                def scroller(node):
                    """The nearest scrollable node above `node`."""
                    above = parents.get(node)
                    while above is not None and above.get("scrollable") != "true":
                        above = parents.get(above)
                    return above
                carousel = scroller(four[0])
                tall = lambda n: (bounds(n)[3] - bounds(n)[1]) > 300 * density
                check("four pictures wider than the message are a carousel (a scroller a thumbnail tall holds them)",
                      carousel is not None and not tall(carousel) and all(scroller(n) is carousel for n in four),
                      carousel is not None and bounds(carousel))
                if carousel is not None:
                    x1, _, x2, _ = bounds(carousel)
                    check("  within the screen", x1 >= 0 and x2 <= width, (x1, x2, width))
                words = next((n for n in root.iter("node") if n.get("text") == "Four screenshots of the sign-in screen."), None)
                check("  and the message's words on screen", words is not None and bounds(words)[2] <= width, words is not None and bounds(words))
                row = scroller(two[0])
                check("two that fit are a row (in no scroller but the transcript's)", row is None or tall(row), row is not None and bounds(row))
                answer = next((n for n in root.iter("node") if n.get("text") == "And the two that changed."), None)
                if answer is not None:
                    right = max(bounds(n)[2] for n in two)
                    check("  at the trailing edge with their message", abs(right - bounds(answer)[2]) <= 24 * density,
                          (right, bounds(answer)[2]))
    finally:
        sh_shell(phone.a, "am", "force-stop", PACKAGE)
        sh(phone.a + ["reverse", "--remove", f"tcp:{port}"])
        stub.kill()
        if started:
            sh(phone.a + ["emu", "kill"])
        print("[layout] FAILED: " + "; ".join(failures) if failures else "[layout] all passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
