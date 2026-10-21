#!/usr/bin/env python3
"""AgentUI's composer typed into on Android: the cases AgentUI's
ComposerTypingTests type into a Mac's field, here in blue Visor's composer
(visor's snapshot fixture, its chat) on this Mac's hermetic emulator, or the
device lab's phone under `device-lab run`. `adb shell input` types ASCII
only, so the cases with an em dash or an emoji are the web's
(tools/isomer/e2e/composer_check.js); the caret is read by typing a letter where
it is and reading the words (Android's dump has no selection).

  tools/isomer/uitests/composer_android.py                  # emulator-5554 (boots it if none)
  tools/isomer/uitests/composer_android.py --override_module=isomer=<checkout>   # bazel flags pass through
Exit 1 when a case fails."""
import os, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from android_flow import Phone, adb_path, sh, sh_shell, ROOT, PACKAGE  # noqa: E402

COMPOSER = r"^Message Claude Code"


def main():
    serial = os.environ.get("ANDROID_SERIAL", "emulator-5554")
    adb = adb_path()
    phone = Phone(adb, serial)
    started = None
    if serial.startswith("emulator-") and f"{serial}\tdevice" not in sh([adb, "devices"]).stdout:
        print("[composer] booting the hermetic emulator", flush=True)
        started = subprocess.Popen(["bazel", "run", "@isomer//tools/android/emulator", "--", "-no-window", "-no-audio", "-port", "5554"],
                                   cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(200):
            time.sleep(3)
            if sh_shell(phone.a, "getprop", "sys.boot_completed").stdout.strip() == "1":
                break
    failures = []
    try:
        flags = ["-c", "opt"] + sys.argv[1:]
        sh(["bazel", "build"] + flags + ["//applications/visor_android:visor_android_apk"], check=True)
        apk = next(f for f in sh(["bazel", "cquery"] + flags + ["--output=files", "//applications/visor_android:visor_android_apk"]).stdout.split()
                   if f.endswith(".apk") and "_unsigned" not in f)
        sh(phone.a + ["uninstall", PACKAGE])
        sh(phone.a + ["install", "-r", os.path.join(ROOT, apk)], check=True)
        sh_shell(phone.a, "wm", "dismiss-keyguard")
        phone.start("chat", 0)

        def text():
            """The composer's words: the EditText's, or its prompt when empty."""
            found = re.search(r'<node[^>]*class="android\.widget\.EditText"[^>]*>', phone.dump())
            if not found:
                return None
            value = re.search(r'text="([^"]*)"', found.group(0))
            words = (value.group(1) if value else "").replace("&#10;", "\n").replace("&amp;", "&").replace("&quot;", '"')
            return "" if re.match(COMPOSER, words) else words

        def key(*names):
            if len(names) == 1:
                sh_shell(phone.a, "input", "keyevent", names[0])
            else:
                sh_shell(phone.a, "input", "keycombination", *names)
            time.sleep(0.4)

        def type_(words):
            sh_shell(phone.a, "input", "text", words.replace(" ", "%s"))
            time.sleep(0.6)

        def clear():
            phone.tap(COMPOSER + r"|android\.widget\.EditText", tries=5) or phone.tap(r".", tries=1)
            key("KEYCODE_MOVE_END")
            for _ in range(4):
                sh_shell(phone.a, "input", "keyevent", *(["KEYCODE_DEL"] * 12))
            time.sleep(0.4)

        def check(name, ok, got):
            print(("[composer] ok    " if ok else "[composer] FAIL  ") + name + ("" if ok else f": got {got!r}"), flush=True)
            if not ok:
                failures.append(name)

        if not phone.shows(COMPOSER, tries=30):
            print("[composer] FAIL  no composer on the chat")
            return 1

        clear(); type_("rows archived"); key("KEYCODE_SHIFT_LEFT", "KEYCODE_ENTER"); key("KEYCODE_DEL"); type_("d"); type_("Q")
        got = text()
        check('"archived", Shift-Return, Delete, "d" gives "…archivedd|"', got == "rows archiveddQ", got)

        clear(); type_("first second")
        for _ in "second":
            key("KEYCODE_DPAD_LEFT")
        key("KEYCODE_SHIFT_LEFT", "KEYCODE_ENTER"); type_("X")
        got = text()
        check("Shift-Return mid-message leaves the caret right after the newline", got == "first \nXsecond", got)

        clear(); type_("abc"); key("KEYCODE_DEL"); key("KEYCODE_DEL"); type_("Q")
        got = text()
        check("Delete never adds a newline", got == "aQ", got)

        clear(); type_("keep drop")
        for _ in "drop":
            key("KEYCODE_SHIFT_LEFT", "KEYCODE_DPAD_LEFT")
        key("KEYCODE_SHIFT_LEFT", "KEYCODE_ENTER"); type_("y")
        got = text()
        check("Shift-Return over a selection replaces it", got == "keep \ny", got)

        # The commands are a menu floating above the composer, in a popup of
        # its own (Isomer's floating layer): found among every window.
        clear(); type_("/")
        command = None
        for _ in range(10):
            found = re.search(r'text="(/[a-z][a-z-]*)"', phone.dump(windows=True))
            if found:
                command = found.group(1)
                break
            time.sleep(0.5)
        if command and phone.tap("^" + re.escape(command) + "$", tries=3, windows=True):
            time.sleep(0.6); type_("Z")
            got = text()
            check(f"a picked slash command ({command}) puts the caret after it",
                  got is not None and got.startswith(command) and got.rstrip().endswith("Z"), got)
        else:
            print('[composer] skip  a picked slash command: no command list showed for "/"', flush=True)
    finally:
        # A touch, to put the phone back in touch mode: the keys typed here
        # took it out, and then the next app's first text field takes the
        # focus (a snapshot run afterwards showed the keyboard on every
        # screen). On the chat's title, which does nothing.
        phone.tap(r"^Offline sync$", tries=1)
        sh_shell(phone.a, "am", "force-stop", PACKAGE)
        if started:
            sh(phone.a + ["emu", "kill"])
    print("[composer] FAILED: " + "; ".join(failures) if failures else "[composer] all passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
