import AppKit
import Carbon

_ = NSApplication.shared
var key: EventHotKeyRef?
let status = RegisterEventHotKey(105, 6400, EventHotKeyID(signature: 0x54455354, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &key)
print(status)
fflush(stdout)
// The parent closes stdin to release this disposable registration.
_ = FileHandle.standardInput.readDataToEndOfFile()
if let key { UnregisterEventHotKey(key) }
