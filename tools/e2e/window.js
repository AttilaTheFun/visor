// Visor's main window on screen, as `x y width height` in points: for the
// proof's crop. Run in the desktop session: osascript -l JavaScript window.js
ObjC.import('CoreGraphics');
ObjC.import('Foundation');
var list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0));
var found = '';
for (var i = 0; i < list.count && !found; i++) {
  var w = list.objectAtIndex(i);
  if (ObjC.unwrap(w.objectForKey('kCGWindowOwnerName')) !== 'Visor' || ObjC.unwrap(w.objectForKey('kCGWindowLayer')) !== 0) continue;
  var b = w.objectForKey('kCGWindowBounds');
  var width = ObjC.unwrap(b.objectForKey('Width'));
  if (width < 600) continue;
  found = [ObjC.unwrap(b.objectForKey('X')), ObjC.unwrap(b.objectForKey('Y')), width, ObjC.unwrap(b.objectForKey('Height'))].join(' ');
}
found;
