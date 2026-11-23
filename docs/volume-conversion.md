# Converting Sessions and Sources to case-sensitive APFS

A Mac whose Sessions or Sources volume was made by hand before Visor Disk
Utility (the Mini's, 21 Nov 2026) has it as plain, case-insensitive APFS,
where `Foo.h` and `foo.h` are one file; the Sessions container's Linux sees
them as two (docs/containers.md, Visor's volumes). Visor Disk Utility
adopts such a volume as it is and never reformats it. It converts one by a
copy instead, in three steps, two of them a click and one administrator
prompt each:

1. **Stage** (Logan, in Visor Disk Utility): `Sessions-new` and
   `Sources-new` are made beside the old ones.
2. **copy-staged** (NCH, over SSH as Logan's user, no `sudo`): with Visor
   stopped, everything is copied onto them and checked file by file, and a
   marker is left on each.
3. **Swap In** (Logan, in Visor Disk Utility): each verified copy takes its
   volume's place at the same path; the old one is kept, unmounted, for a
   rollback.

Visor and every session on the Mac are stopped from step 2 until Visor is
started again after step 3, about 15 to 30 minutes in all. Nothing is
swapped unless the copy was checked, and the old volumes are only renamed
and unmounted, never changed, until Logan deletes them.

## What each step does

**Stage** (the window's *Convert to Case-Sensitive* box, below the volumes'
cards: **Stage Sessions and Sources**; or `Visor Disk Utility stage
sessions|sources|both`). For each role, in one administrator prompt:
`diskutil apfs addVolume <the role's APFS container> "Case-sensitive APFS"
<Name>-new` with the role volume's own quota and reserve as diskutil lists
them (the Mini: Sessions 40 GB, Sources 120 GB, no reserve), then `chown
<user>:staff /Volumes/<Name>-new` and `chmod 775`, as Create does. Refused
when the role's volume isn't there (named for its role, mounted at
`/Volumes/<Name>`), is case-sensitive already (nothing to convert), when
`<Name>-new` exists already (the box shows it as staged), when an earlier
conversion's `<Name>-old-ci` is still there, when `/Volumes/<Name>-new` is
taken, or when the container hasn't room for a copy. VolumeGuard passes the
three commands only exactly as planned, for a role the step names.

**copy-staged** (`Visor Disk Utility copy-staged sessions|sources|both
[--replace]`, as the volumes' owner; it refuses to run as root). Refused
unless Visor's server is stopped (no `Visor.app/Contents/MacOS/Visor` nor
`visor-agent-host` process, nothing answering on 127.0.0.1:7433) and
nothing but Spotlight (`mds*`, `mdworker*`) has a file open on either
volume (`lsof /Volumes/<Name>`, `lsof /Volumes/<Name>-new`). Then:

- any old marker on `<Name>-new` is removed; a `<Name>-new` that holds
  anything is refused unless `--replace`, which empties it first;
- every entry at `/Volumes/<Name>`'s root is copied but the system's own
  folders (`.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems`,
  `.DocumentRevisions-V100`): a symbolic link at the root with `cp -P -p`
  (ditto follows a link it's given), everything else with `ditto` (modes,
  ACLs, extended attributes; links inside folders stay links);
- both sides' manifests are made, the system's folders left out: every
  regular file's sha256, every symbolic link's target and every folder,
  sorted by path. They must be identical. Socket files are left out (no
  data, and nothing copies one) and listed;
- the source's listing (every path's size and modification time) is taken
  before and after the copy, and must be the same: nothing wrote to it
  meanwhile;
- only then is `.visor-conversion-verified` written at `<Name>-new`'s root
  (JSON): the source's and the copy's APFS volume UUIDs, the file, link and
  folder counts, the manifest's sha256, the listing's sha256, and the time.

Anything that fails, a mismatch above all, leaves no marker and says what
(`MISMATCH`, with the first paths that differ). Run it again with
`--replace` once the cause is gone.

**Swap In** (the box's **Swap In Sessions and Sources**, or `Visor Disk
Utility swap sessions|sources|both`; one administrator prompt for both).
Refused unless, for each role: the marker is on `<Name>-new`, names this
`<Name>`'s UUID and this `<Name>-new`'s, and is at most two hours old; the
source's listing is still the marker's (nothing changed since the copy);
no `<Name>-old-ci` exists; and, as for the copy, Visor is stopped and
nothing has either volume open. Then, by disk (`disk3s7`), so no path or
name can stand for the other volume:

1. `diskutil rename <old disk> <Name>-old-ci`, `diskutil unmount <old disk>`;
2. `diskutil rename <new disk> <Name>`, `diskutil unmount <new disk>`,
   `diskutil mount <new disk>`: mounted at `/Volumes/<Name>`;
3. the marker removed (as the user).

VolumeGuard plans the same five commands again from the disks just before
the prompt runs, with the marker checked again, and passes them only if
they're identical. The box and the command line then say what's there:
"Sessions: Case-sensitive APFS, mounted at /Volumes/Sessions, owned by
logan", and the volume kept. `volumes.json` records the new volume as
Visor's own.

**The kept volumes.** `<Name>-old-ci` stays unmounted (after a restart
macOS mounts it at `/Volumes/<Name>-old-ci`, which is harmless). The box
lists it as "kept for rollback" with **Delete…** (its name typed, `delete
Sessions-old-ci`, then the administrator prompt: `diskutil apfs
deleteVolume <its UUID>`), and `Visor Disk Utility delete-kept
Sessions-old-ci --confirm "delete Sessions-old-ci"` does the same.
Uninstall…'s dry run lists them as kept, and deletes them with the volumes
when that's asked.

**unswap** (`Visor Disk Utility unswap sessions|sources|both`, one
administrator prompt; command line only). The rollback, while
`<Name>-old-ci` is there, found by its name: the converted `<Name>` at
`/Volumes/<Name>`, if there's one, renamed `<Name>-cs-failed` and
unmounted; the old one mounted if it isn't, renamed `<Name>`, unmounted and
mounted again at `/Volumes/<Name>`. A swap that stopped part-way is undone
the same way. The `-cs-failed` copy is listed for Delete… like a kept one.
To convert again after an unswap: delete both kept volumes, then Stage.

## The window, step by step (the Mini)

Run it after the release with these actions is installed on the Mini, and
after Visor Disk Utility has made the **Visor** volume (Create on its card;
see the session folder's one-time runbook for Time Machine).

**0. Before (NCH, read-only):** nothing else holds Sessions or Sources (no
Shireworks or Nimbus lease mounting them: `sw machine list`; no editor open
in a checkout), and the container has room (`Visor Disk Utility status`:
Sessions' and Sources' conversion lines say "Stage makes …").

**1. Stage (Logan).** Open Visor Disk Utility; in *Convert to
Case-Sensitive*, click **Stage Sessions and Sources** and approve the
prompt. The box then says "Sessions-new is staged (disk3sN): waiting for
copy-staged sessions", and the same for Sources. Visor keeps running.

**2. Stop Visor (NCH, over SSH as logan; Logan's OK for the window).** Tell
Manager the window starts and wait until no session is mid-turn. Then:

```zsh
cd ~                                   # not inside either volume
osascript -e 'quit app "Visor"'        # Quit Visor (the menu bar app)
launchctl bootout gui/$(id -u)/com.LoganShire.Visor.server
pkill -TERM -f visor-agent-host; sleep 3
pgrep -fl 'Visor.app/Contents' || echo "Visor stopped"
lsof /Volumes/Sessions /Volumes/Sources /Volumes/Sessions-new /Volumes/Sources-new
```

`lsof` must list nothing but `mds*` or `mdworker*`; quit or stop anything
else, and run it again.

**3. Copy and verify (NCH, as logan, no sudo):**

```zsh
DU="/Applications/Visor Disk Utility.app/Contents/MacOS/Visor Disk Utility"
"$DU" copy-staged sources
"$DU" copy-staged sessions
"$DU" status | grep -A1 conversion
```

Each ends "Sources-new verified …: N files, M links, … Swap In within two
hours." and `status` says "ready to swap in". A `MISMATCH` or any error:
nothing has been swapped; fix the cause and run that line again with
`--replace`, or stop here (Visor can be started again: step 6).

**4. Swap In (Logan), within two hours of step 3.** In Visor Disk
Utility, click Refresh, then **Swap In Sessions and Sources**, and approve
the prompt. The box shows, for each: "Case-sensitive APFS, mounted at
/Volumes/<Name>, owned by logan", and "<Name>-old-ci (…, not mounted): kept
for rollback". If it refuses, it says why (Visor running, a file open, the
marker too old or not matching, the volume changed since the copy), and
nothing was renamed.

**5. Check (NCH, read-only):**

```zsh
diskutil info /Volumes/Sessions | grep -E 'Personality|Mount Point'   # Case-sensitive APFS, /Volumes/Sessions
diskutil info /Volumes/Sources  | grep -E 'Personality|Mount Point'
ls -la /Volumes/Sessions /Volumes/Sources | head -30
git -C /Volumes/Sources/visor status --short | head
git -C /Volumes/Sources/visor fsck --no-dangling 2>&1 | tail -2
```

**6. Start Visor (NCH):** `open -a Visor` (it registers its server agent);
then send Manager "window done". The sessions resume on the same paths.

**Rollback (Logan, in Terminal on the Mini, any time while the kept
volumes are there):** stop Visor as in step 2, then

```zsh
"/Applications/Visor Disk Utility.app/Contents/MacOS/Visor Disk Utility" unswap both
```

approve the prompt, and start Visor again (step 6).

**Afterwards:** Time Machine backs the new volumes up afresh. After a week
or so, with Logan happy, he deletes `Sessions-old-ci` and `Sources-old-ci`
with their Delete… buttons.

## Testing

`//tests/visor_disk_volumes_tests` (in `//tests:linux`, and on a Mac):
ConversionPlanTests (Stage's, Swap In's and unswap's commands, and every
refusal), ConversionGuardTests (each step passes only as planned, for the
roles named; rename, unmount and mount for those names and disks alone; a
kept volume deleted only by its UUID, its name asked for), MarkerTests
(the marker's round trip), CopyTests (the copy and check on scratch
folders: links at the root and inside, the system's folders, a changed
file, a followed link, a source changed meanwhile, a failed command, a
volume not empty) and PreflightTests (`ps` and `lsof` read).
`//tests/visor_uninstall_tests`: the kept volumes listed or deleted. A real
Stage, copy-staged, Swap In, unswap and Delete… on scratch volumes runs in
a leased macOS VM, with `--sudo` for the prompt.
