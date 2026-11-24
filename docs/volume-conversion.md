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
volume outside the system's own folders (`lsof -F pcn /Volumes/<Name>`,
and `<Name>-new`). Run as the person, lsof sees only their processes: a
write by any other process during the copy is caught by the source's
listing (below), and Swap In checks again as root. Then:

- **What the person can't copy as it is is refused, with a list, before
  anything is copied:** a file or folder of another owner (ditto run as
  the person would quietly make it theirs: a container's or another uid's
  files), of a group the person isn't in, one they can't read, one with a
  flag only root can set (`schg`, `sappnd`, restricted…) or whose data
  isn't on the Mac (dataless), one whose extended attributes or ACL can't
  be read (an error other than "none" from listxattr or acl_get_link_np:
  neither side's could be compared), and a hard link shared between two entries
  at the root (each root entry is copied on its own, which would split
  it). The copy isn't done as root instead: copy-staged is NCH's, over
  SSH, with no administrator. Put them right first, as Logan (`sudo chown
  -R logan:staff <path>`, `chflags`), or move them off the volume. To see
  them ahead of the window: `find /Volumes/Sessions ! -user $USER` and
  `find /Volumes/Sessions ! -group staff`;
- the copy must fit: the bytes it writes (clones in full, a file shared by
  hard links within a root entry once) against `<Name>-new`'s free space;
- any old marker on `<Name>-new` is removed; a `<Name>-new` that holds
  anything is refused unless `--replace`, which empties it first;
- every entry at `/Volumes/<Name>`'s root is copied but the system's own
  folders (`.Spotlight-V100`, `.fseventsd`, `.Trashes`, `.TemporaryItems`,
  `.DocumentRevisions-V100`), which it says it left out: **the volume's
  Trash and temporary items aren't carried over**, so empty or move out
  anything wanted from them first. A symbolic link at the root goes with
  `cp -P -p` (ditto follows a link it's given), everything else with
  `ditto` (modes, ACLs, extended attributes, flags, hard links within the
  entry; links inside folders stay links); a root folder's own flags
  (hidden, say), which ditto leaves off, are set after with `chflags`;
- both sides' manifests are made, the system's folders left out: every
  regular file's sha256, every symbolic link's target, every folder, and
  of each its mode, owner, group, flags (the person's and root's; not the
  system's own bookkeeping: compressed, tracked, dataless), the sha256 of
  its extended attributes (names and values) and of its ACL's text; FIFOs
  and devices by type, mode and device number; and each group of paths
  that are one file (hard links). They must be identical. Socket files are
  left out (no data, and nothing copies one) and listed;
- the source's listing (every path's size, modification time and
  status-change time) is taken before and after the copy, and must be the
  same: nothing wrote to it meanwhile;
- a symbolic link whose target differs from a file's name only in case
  (`readme -> NOTES.md` beside `notes.md`) resolves on the case-insensitive
  volume and not on the copy: it's copied as it is, and listed as a
  warning. Fix such links (and any path written in a different case in a
  script or a config) before or after the window;
- only then is `.visor-conversion-verified` written at `<Name>-new`'s root
  (JSON): the source's and the copy's APFS volume UUIDs, the file, link,
  folder and hard-link counts, the manifest's sha256, the source's and the
  copy's listings' sha256, and the time.

Anything that fails, a mismatch above all, leaves no marker and says what
(`MISMATCH`, with the first lines that differ). Run it again with
`--replace` once the cause is gone.

**Swap In** (the box's **Swap In Sessions and Sources**, or `Visor Disk
Utility swap sessions|sources|both`; one administrator prompt for both).
Refused unless, for each role: the marker is on `<Name>-new`, names this
`<Name>`'s UUID and this `<Name>-new`'s, and is at most two hours old by
this Mac's clock; the source's and the copy's listings are still the
marker's (nothing changed on either since the check: the marker is the
person's to write, so the copy itself is checked too); no `<Name>-old-ci`
exists; and, as for the copy, Visor is stopped and nothing has either
volume open. Then, in the administrator prompt's one shell:

1. **as root, first, from a verified copy of the app:** the bundle Logan
   runs is his to write, and so any process of his (an agent's) could
   change it between Visor Disk Utility's look and the prompt. So the
   prompt's script copies the bundle, as root, into a fresh root-owned
   folder (`mktemp -d /private/var/tmp/visor-check.XXXXXXXX`, 0700),
   verifies the copy (`codesign --verify --strict -R=<requirement>`)
   against a requirement built from constants, never read from the bundle:
   `anchor apple generic and identifier "com.LoganShire.Visor.DiskUtility"
   and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and
   certificate leaf[subject.OU] = "<team>" and cdhash H"<cdhash>"`. The team
   is Logan's, compiled in from VISOR_TEAM_ID (`--repo_env`, which CI's
   alpha-apple and release-apple set from the repository's VISOR_TEAM_ID
   variable, or the builder's own .bazelrc.user): an optimized
   build without it refuses Swap In and unswap ("built without Logan's
   team"), since a bundle replaced before launch would bring its own, and
   one that runs signed by another team refuses too. Only a dev or test
   build falls back to the running process's own team (its entitlements as
   the kernel holds them). The cdhash is the running
   process's own as the kernel holds it, so the copy must be exactly the
   binary that ran Visor Disk Utility's checks: a bundle replaced after
   launch, by a build signed by any other identity, fails (and Swap In
   refuses up front when the bundle on disk isn't the code that's
   running). Only a test build
   (`--config=visor_test_signing`, which defines VISOR_TEST_SIGNING) may be
   ad hoc, pinned by its cdhash alone; it alone has the test hooks
   (`VISOR_CONVERSION_TEST_PAUSE`, `VISOR_CONVERSION_TEST_TAMPER`). The
   prompt then runs the copy's `conversion-check swap
   <role> <the marker file's sha256>…`, and removes the folder whatever
   happens. A copy that fails its verification is refused ("conversion-check
   refused: the copy of Visor Disk Utility failed its signature check …
   Nothing was changed"). The check then checks it all again: the marker is still
   the file checked before the prompt, names the volumes there now and
   isn't too old; both listings are unchanged; Visor's processes are gone;
   and root's `lsof` (which sees every process, the container engine's and
   root's among them) finds nothing open on either volume. If anything
   differs it refuses, and nothing after it runs: **nothing is changed**;
2. by disk (`disk3s7`), so no path or name can stand for the other volume:
   `diskutil rename <old disk> <Name>-old-ci`, `diskutil unmount <old
   disk>`, then `diskutil rename <new disk> <Name>`, `diskutil unmount <new
   disk>`, `diskutil mount <new disk>`: mounted at `/Volumes/<Name>`;
3. the marker removed (as the user), and a note left in Visor's data
   folder (`volume-conversions.json`): the swap's time, both UUIDs and the
   converted volume's listing, for unswap.

VolumeGuard plans the same commands again from the disks just before the
prompt runs, with the marker checked again by this Mac's clock, and passes
them only if they're identical and the check is first, in exactly that
copy-verify-run shape, for Visor Disk Utility's own bundle and
requirement. The box and the command line then say what's
there: "Sessions: Case-sensitive APFS, mounted at /Volumes/Sessions, owned
by logan", and the volume kept. `volumes.json` records the new volume as
Visor's own.

**The kept volumes.** `<Name>-old-ci` stays unmounted (after a restart
macOS mounts it at `/Volumes/<Name>-old-ci`, which is harmless). The box
lists it as "kept for rollback" with **Delete…** (its name typed, `delete
Sessions-old-ci`, then the administrator prompt: `diskutil apfs
deleteVolume <its UUID>`), and `Visor Disk Utility delete-kept
Sessions-old-ci --confirm "delete Sessions-old-ci"` does the same.
Uninstall…'s dry run lists them as kept, and deletes them with the volumes
when that's asked; its typed phrase then names them too ("delete Sessions,
Sources, Visor and Sessions-old-ci"), since after a swap that stopped
part-way a kept volume can be the only original.

**unswap** (`Visor Disk Utility unswap sessions|sources|both [--force]`,
one administrator prompt; command line only). The rollback, while
`<Name>-old-ci` is there, found by its name: the converted `<Name>` at
`/Volumes/<Name>`, if there's one, renamed `<Name>-cs-failed` and
unmounted; the old one mounted if it isn't, renamed `<Name>`, unmounted and
mounted again at `/Volumes/<Name>`. A swap that stopped part-way is undone
the same way, and so is one that stopped just after its first rename, the
old volume renamed but still mounted at `/Volumes/<Name>` (it's named
back). The prompt starts with the root's check (`conversion-check unswap
<role>…`: Visor stopped, nothing open). **Unswap brings back the old volume
as it was at the swap:** if the converted one has changed since (its
listing isn't the note's, or there's no note), it's refused unless
`--force`, and says that what was written since stays on `<Name>-cs-failed`,
unmounted, to be copied out by hand. The `-cs-failed` copy is listed for
Delete… like a kept one, its sheet saying it may hold the newest data. To
convert again after an unswap: delete both kept volumes, then Stage.

**Stage's quota.** The copy gets the role volume's own quota and reserve
(the Mini's: 40 GB and 120 GB, no reserve), and **no quota when the role
volume has none**: a quota can't be changed or removed once a volume is
made (`diskutil` has no verb for it on macOS 27, and no other tool does),
and the copy becomes the volume Visor uses, so a quota set only to bound
the copy would stay on the live Sessions or Sources and fill it early. A
copy with no quota shares the container's free space with the rest of the
Mac instead, so copy-staged refuses one that would leave less than a tenth
of it free (at least 20 GB); with a quota, the copy must fit in it. Either
way it counts the bytes it writes first: each file's and folder's
allocated blocks (`st_blocks` × 512, so a tree of small files, node_modules
or .git's objects, counts as it takes the disk), clones in full.

## The window, step by step (the Mini)

Run it after the release with these actions is installed on the Mini, and
after Visor Disk Utility has made the **Visor** volume (Create on its card;
see the session folder's one-time runbook for Time Machine).

**0. Before (NCH, read-only):** nothing else holds Sessions or Sources (no
Shireworks or Nimbus lease mounting them: `sw machine list`; no editor open
in a checkout), the container has room (`Visor Disk Utility status`:
Sessions' and Sources' conversion lines say "Stage makes …"), and nothing
on them belongs to another user or group (`find /Volumes/Sessions
/Volumes/Sources \( ! -user logan -o ! -group staff \) -print | head`,
`ls -lO` for flags): what it lists, Logan gives to himself before the
window (`sudo chown -R logan:staff <path>`), or copy-staged will refuse
with the same list. Look for links that only resolve case-insensitively
too (copy-staged warns of them).

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
for rollback". If it refuses, it says why (Visor running, Apple's Disk
Utility open, a file open, the marker too old or not matching, the volume
changed since the copy), and nothing was renamed. **Quit Apple's Disk
Utility first**: it can hold a volume it shows, which stopped the Mini's
first Swap In after its first rename (24 Nov). If a Swap In does stop
part-way, the old volume is `<Name>-old-ci` with nothing named `<Name>`
(mounted at `/Volumes/<Name>-old-ci`, as diskutil moves a renamed volume's
mount point): **don't delete it**, it holds everything. Swap In says so;
run `unswap <role>` to name it back, then Swap In again.

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

approve the prompt, and start Visor again (step 6). If the sessions have
already written to the converted volumes, unswap refuses: `--force` brings
the old ones back anyway, and what was written since stays on
`<Name>-cs-failed`, to be copied out by hand.

**Afterwards:** Time Machine backs the new volumes up afresh. After a week
or so, with Logan happy, he deletes `Sessions-old-ci` and `Sources-old-ci`
with their Delete… buttons.

## Testing

`//tests/visor_disk_volumes_tests` (in `//tests:linux`, and on a Mac;
the Mac's own inspector, with flags, extended attributes and ACLs, in a
leased macOS VM):
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
