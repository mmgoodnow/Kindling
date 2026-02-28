## Build Instructions
- When working on the macOS app, use Xcode as the run surface: build and launch the Mac app from Xcode, and prefer AppleScript automation to trigger Run/hide Xcode instead of only using `xcodebuild`.
- When working on the iOS app, switch the active Xcode run destination to `Fermat` and use Xcode as the run surface: trigger Run via AppleScript so the app builds and launches on the phone, then hide Xcode and bring the iPhone Mirroring app to the front.
- Use `xcodebuild` as a verification/build tool, but prefer Xcode-driven launch flows for actual app running.
- Commit after every change or logical set of changes.
- Do not batch unrelated work into a single uncommitted checkpoint when you can avoid it.
- Do not ask before committing; use good judgment on commit messages.
