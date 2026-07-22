import Foundation

@MainActor
struct PlaybackMetadataLoader {
  let player: AudioPlayerController

  func load(
    playback: PodiblePlaybackAudio?,
    identity: PlaybackIdentity,
    client: RemoteLibraryServing
  ) async {
    guard let playback else {
      player.applyRemoteTranscriptUnavailable(
        "No audio edition metadata is available for transcript lookup.",
        for: identity
      )
      player.applyRemoteChapters([], for: identity)
      return
    }

    async let chapters: Void = loadChapters(
      playback: playback,
      identity: identity,
      client: client
    )
    async let transcript: Void = loadTranscript(
      playback: playback,
      identity: identity,
      client: client
    )
    _ = await (chapters, transcript)
  }

  func loadForActivePlaybackIfNeeded(
    books: [LibraryBook],
    identity: (LibraryBook) -> PlaybackIdentity,
    client: RemoteLibraryServing
  ) async {
    guard player.transcriptLoadState == .idle else { return }
    guard let activeResumeID = player.activeResumeID else { return }
    guard let activeBook = books.first(where: { identity($0).matches(activeResumeID) }) else {
      return
    }
    let playback = activeBook.playbackJSON.flatMap {
      try? JSONDecoder().decode(PodiblePlayback.self, from: $0).audio
    }
    await load(playback: playback, identity: identity(activeBook), client: client)
  }

  private func loadTranscript(
    playback: PodiblePlaybackAudio,
    identity: PlaybackIdentity,
    client: RemoteLibraryServing
  ) async {
    guard let transcriptURL = playback.transcriptUrl,
      transcriptURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      player.applyRemoteTranscriptUnavailable(
        "Podible did not return a transcript URL for this audio edition.",
        for: identity
      )
      return
    }

    player.beginRemoteTranscriptLoad(for: identity)
    do {
      if let transcript = try await client.fetchTranscript(playback: playback) {
        player.applyRemoteTranscript(transcript, for: identity)
      } else {
        player.applyRemoteTranscriptUnavailable(
          "Podible returned 404 for this transcript URL.",
          for: identity
        )
      }
    } catch {
      player.applyRemoteTranscriptFailure(
        "Transcript download failed: \(error.localizedDescription)",
        for: identity
      )
    }
  }

  private func loadChapters(
    playback: PodiblePlaybackAudio,
    identity: PlaybackIdentity,
    client: RemoteLibraryServing
  ) async {
    do {
      player.applyRemoteChapters(
        try await client.fetchChapters(playback: playback),
        for: identity
      )
    } catch {
      player.applyRemoteChapters([], for: identity)
    }
  }
}
