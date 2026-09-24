# Siri and Shortcuts (iOS 27)

Kindling exposes its locally mirrored audiobook catalog through the iOS 27
`.audio.audiobook` schema, `AudioSearch` queries, and `.audio.playAudio`.
This is App Intents integration, not an MCP server. macOS does not yet expose
these intents; its minimum OS remains 26.

## Actions

- **Resume Audiobook**: “Resume my audiobook in Kindling” or “Play my audiobook in Kindling.”
- **Play Audio**: Siri resolves an audiobook (and edition when needed) and resumes its saved position.
- **Find Audiobooks**: search the local library by title, author, narrator, or series; returns audiobook entities to Shortcuts.
- **Open Audiobook**: opens the book's detail page. Spotlight uses indexed audiobook entities; book details provide onscreen entity context.

An unspecified audio search prefers the active unfinished book, then the most
recent unfinished book. Explicit searches can return finished books, but playback
rejects them. Repeat, shuffle, and queue insertion requests are unsupported and
return an error rather than silently doing something else.

Only content already mirrored to this device is searchable. Downloaded audio
works without authentication; streaming uses the app's stored Podible session.
Missing audio or a session requiring sign-in produces an error. Playback waits
for readiness and reports failures/timeouts. Library metadata is indexed in
Spotlight and removed from the index when records disappear. Tokens and local
file paths are not entity properties or indexed attributes.

UI and intents share one runtime, SwiftData container, and audio player.
Completion is persisted even without ContentView. Spotlight changes are
coalesced and unchanged metadata is not repeatedly reindexed on playback saves.

## Validation

- Build with Xcode 27. App Intents metadata extraction must succeed; ordinary
  Swift compilation alone does not validate the audio schema.
- Run `xcodebuild -project Kindling.xcodeproj -scheme kindlingTests -destination 'platform=macOS' test`.
- On an iOS 27 device, launch and sync Kindling, then check its actions in Shortcuts.
- Verify search/edition disambiguation, opening Spotlight results, and playback
  from Siri with the app closed and phone locked.
- Verify offline downloaded playback, expired streaming authentication, removed
  books, and refusing to restart completed books.

Siri phrasing/routing and onscreen awareness depend on the device's Siri AI
availability. Passing builds and service tests do not prove end-to-end Siri
routing; that requires the device checks above.
