# Known issues

Problems seen and not yet fixed, with what is known about each, so the
work can be picked up later. Remove an entry when it is fixed.

## Swiping an archived session hitches (iPhone)

**Seen:** on an iPhone 15 Pro, swiping a row in the Archived list (either
edge, Unarchive or Remove) hitches as the action's icon first appears and
grows. Swiping a live session in the sidebar (Archive) is smooth.

**Tried, not the cause on its own:**
- The destructive button role on Remove (now an ordinary button tinted
  red).
- The plain list style with hidden separators and zero minimum row height
  (the list now uses the sidebar's inset grouped style, which helped a
  little).
- Redrawing rows that did not change (an equatable row wrapper): no
  difference.

**Not reproduced in the simulator:** `VisorProbe/testArchivedSwipe`
drags a row part-way and holds it three times; stack samples of the app
over the whole run show the main thread idle apart from drawing and the
test harness. Both lists use SF Symbols through `Label(_:systemImage:)`
and Apple's SwiftUI.

**Leading suspect:** main-thread work landing during the swipe. The
archived list observes the whole `HostConnection`, whose session list
changes several times a second while an agent works on that computer,
redrawing the list under the finger; the sidebar's rows redraw less.

**Next step:** record a Time Profiler trace on the device while swiping
(`xcrun xctrace record --device <UDID> --template 'Time Profiler' --attach
visor_ios --time-limit 60s`). Over Wi-Fi it timed out "waiting for device
to boot"; try with the phone on USB and unlocked. To reproduce, create a
throwaway session over the API and archive it (`POST /api/sessions`, then
`POST /api/sessions/<id>/archive`), and end it afterwards.
