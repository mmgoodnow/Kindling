## Build Instructions
- Build and run after changes with: `xcodebuild -project Kindling.xcodeproj -scheme Kindling -destination 'platform=macOS' build`.
- Always escalate permissions when running `xcodebuild` (requires access to Xcode caches/DerivedData).
- Run `make run` after every change.
- When working on code that interacts with the LazyLibrarian API, test with `./llapi` (example: `./llapi cmd=getAllBooks`).
- Commit after every change or logical set of changes.
- Do not batch unrelated work into a single uncommitted checkpoint when you can avoid it.
- Do not ask before committing; use good judgment on commit messages.
