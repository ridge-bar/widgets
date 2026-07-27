// Prints one line per on-screen window as `<window-id>\t<x>\t<y>`, using
// CoreGraphics window bounds. AeroSpace's `%{window-id}` equals the
// CoreGraphics CGWindowNumber, and AeroSpace's own window listing order is
// neither the visual on-screen order nor stable - so the plugin sorts windows
// by this positional data instead. Reading kCGWindowBounds needs no Screen
// Recording permission (only window titles do, which this script never reads).
// Technique borrowed from sketchybar's window_order.js.
//
// No stdin: returns positions for every on-screen window in one call, so the
// caller (aerospace-plugin.sh) invokes this exactly once per reconcile and
// builds a window-id -> (x, y) map locally instead of shelling out per window.
function run(argv) {
  ObjC.import('CoreGraphics');

  const ref = $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, $.kCGNullWindowID);
  const wins = ObjC.deepUnwrap(ObjC.castRefToObject(ref)) || [];

  const lines = [];
  for (var i = 0; i < wins.length; i++) {
    var wid = wins[i].kCGWindowNumber;
    if (wid == null) continue;
    var b = wins[i].kCGWindowBounds || {};
    var x = b.X == null ? 1000000000 : Math.round(b.X);
    var y = b.Y == null ? 0 : Math.round(b.Y);
    lines.push(wid + '\t' + x + '\t' + y);
  }

  return lines.join('\n');
}
