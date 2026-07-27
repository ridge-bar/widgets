// Prints the live current keyboard LAYOUT input source id (e.g.
// "com.apple.keylayout.Hungarian-QWERTY") via the Carbon Text Input Source
// API. This is authoritative and reflects a layout switch instantly, for every
// switch method - unlike the `AppleCurrentKeyboardLayoutInputSourceID`
// preference read by `defaults`, which can lag or not update for some paths.
//
// The keyboard plugin compiles this once (cached under its state dir) and runs
// the binary each poll; if a Swift toolchain (swiftc) is unavailable, the
// plugin falls back to `defaults read`. Prints nothing if no current layout
// source can be read.
import Carbon

if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
   let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
    print(Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String)
}
