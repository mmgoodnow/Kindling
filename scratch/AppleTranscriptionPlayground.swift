import AVFoundation
import Foundation
import FoundationModels
import Speech

// Example:
// swiftc -parse-as-library scratch/AppleTranscriptionPlayground.swift -o tmp/apple-transcription-playground
// ./tmp/apple-transcription-playground ~/path/to/audio.m4b --locale en-US --summarize

@available(macOS 26.0, *)
struct Segment: Sendable {
  let startSeconds: Double
  let endSeconds: Double
  let text: String
}

@available(macOS 26.0, *)
@main
enum AppleTranscriptionPlayground {
  static func main() async {
    do {
      let configuration = try Configuration(arguments: CommandLine.arguments)
      let transcript = try await transcribeAudio(
        at: configuration.audioURL,
        locale: configuration.locale
      )

      print("=== Transcript ===")
      for segment in transcript {
        print(
          "[\(formatTime(segment.startSeconds)) - \(formatTime(segment.endSeconds))] \(segment.text)"
        )
      }

      if configuration.shouldSummarize {
        let transcriptText = transcript.map(\.text).joined(separator: " ")
        let summary = try await summarizeTranscript(transcriptText)
        print("\n=== Foundation Models Summary ===")
        print(summary)
      }
    } catch {
      fputs("error: \(error)\n", stderr)
      exit(1)
    }
  }

  static func transcribeAudio(at audioURL: URL, locale requestedLocale: Locale?) async throws
    -> [Segment]
  {
    guard SpeechTranscriber.isAvailable else {
      throw PlaygroundError.transcriberUnavailable
    }

    let locale = try await resolveLocale(requestedLocale)
    let audioFile = try AVAudioFile(forReading: audioURL)
    let transcriber = SpeechTranscriber(
      locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
    let analyzer = SpeechAnalyzer(
      modules: [transcriber],
      options: .init(priority: .userInitiated, modelRetention: .whileInUse)
    )

    let resultsTask = Task { () throws -> [Segment] in
      var segments: [Segment] = []
      for try await result in transcriber.results {
        guard result.isFinal else { continue }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { continue }
        segments.append(
          Segment(
            startSeconds: result.range.start.seconds,
            endSeconds: result.range.end.seconds,
            text: text
          )
        )
      }
      return segments
    }

    try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
    return try await resultsTask.value
  }

  static func summarizeTranscript(_ transcript: String) async throws -> String {
    let model = SystemLanguageModel(
      useCase: .general,
      guardrails: .permissiveContentTransformations
    )
    switch model.availability {
    case .available:
      break
    case .unavailable(let reason):
      throw PlaygroundError.modelUnavailable(reason)
    }

    let session = LanguageModelSession(
      model: model,
      instructions:
        "Summarize speech-to-text transcripts concisely. The input may contain recognition errors. Preserve concrete facts, avoid inventing missing context, and do not refuse solely because the transcript contains arbitrary user speech."
    )
    let response = try await session.respond(
      to: """
        Summarize the following transcript in 3 concise bullet points. If words appear mistranscribed, call that out briefly instead of refusing.

        \(transcript)
        """,
      options: GenerationOptions(sampling: .greedy)
    )
    return response.content
  }

  static func resolveLocale(_ requestedLocale: Locale?) async throws -> Locale {
    if let requestedLocale {
      if let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) {
        return supported
      }
      throw PlaygroundError.unsupportedLocale(requestedLocale.identifier(.bcp47))
    }

    if let supportedCurrent = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
      return supportedCurrent
    }

    if let installed = await SpeechTranscriber.installedLocales.first {
      return installed
    }

    if let supported = await SpeechTranscriber.supportedLocales.first {
      return supported
    }

    throw PlaygroundError.noSupportedLocales
  }

  static func formatTime(_ seconds: Double) -> String {
    let total = max(Int(seconds.rounded(.down)), 0)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainingSeconds = total % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%02d:%02d", minutes, remainingSeconds)
  }
}

@available(macOS 26.0, *)
struct Configuration {
  let audioURL: URL
  let locale: Locale?
  let shouldSummarize: Bool

  init(arguments: [String]) throws {
    var positional: [String] = []
    var localeIdentifier: String?
    var shouldSummarize = false

    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--locale":
        guard let value = iterator.next() else {
          throw PlaygroundError.usage("Missing value for --locale")
        }
        localeIdentifier = value
      case "--summarize":
        shouldSummarize = true
      case "--help", "-h":
        throw PlaygroundError.usage(
          """
          Usage: swift scratch/AppleTranscriptionPlayground.swift <audio-file> [--locale en-US] [--summarize]
          """
        )
      default:
        positional.append(argument)
      }
    }

    guard let path = positional.first else {
      throw PlaygroundError.usage(
        """
        Usage: swift scratch/AppleTranscriptionPlayground.swift <audio-file> [--locale en-US] [--summarize]
        """
      )
    }

    let expandedPath = (path as NSString).expandingTildeInPath
    self.audioURL = URL(fileURLWithPath: expandedPath)
    self.locale = localeIdentifier.map(Locale.init(identifier:))
    self.shouldSummarize = shouldSummarize
  }
}

@available(macOS 26.0, *)
enum PlaygroundError: LocalizedError {
  case usage(String)
  case transcriberUnavailable
  case unsupportedLocale(String)
  case noSupportedLocales
  case modelUnavailable(SystemLanguageModel.Availability.UnavailableReason)

  var errorDescription: String? {
    switch self {
    case .usage(let message):
      return message
    case .transcriberUnavailable:
      return "SpeechTranscriber is not available on this machine."
    case .unsupportedLocale(let locale):
      return "SpeechTranscriber does not support locale \(locale)."
    case .noSupportedLocales:
      return "SpeechTranscriber reported no supported locales."
    case .modelUnavailable(let reason):
      return "Foundation Models unavailable: \(String(describing: reason))"
    }
  }
}
