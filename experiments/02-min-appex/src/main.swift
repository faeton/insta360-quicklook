// NSExtensionMain() is the entry point for all app extensions. Without it the
// binary just exits 0 immediately and the extension host (ThumbnailsAgent) sees
// "extension died, fall back to default thumbnail".
import Foundation

@_silgen_name("NSExtensionMain")
func NSExtensionMain() -> Never

NSExtensionMain()
