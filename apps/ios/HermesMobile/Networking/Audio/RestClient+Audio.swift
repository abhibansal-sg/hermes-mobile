import Foundation

// Voice REST endpoints (transcribe / speak) layered onto ``RestClient`` as an
// extension, mirroring the sibling ``RestClient+Sessions.swift`` pattern. These
// reuse ``RestClient``'s shared `makeRequest`/`perform`/`decode`/`encodeBody`
// plumbing (loopback `Host: 127.0.0.1` override, `X-Hermes-Session-Token` auth,
// 15s timeout, ``RestError`` mapping) rather than cloning it.
//
// ``AudioSpeakResult`` declares explicit snake_case `CodingKeys`, so its decode
// passes `strategy: .useDefaultKeys` (converting would double-transform `data_url`).

// MARK: - Response shapes (verified against web_server.py)

/// `POST /api/audio/transcribe` → `{ok, transcript, provider}` (web_server.py:1235).
struct AudioTranscribeResult: Decodable, Sendable, Equatable {
    let ok: Bool
    let transcript: String
    let provider: String?
}

/// `POST /api/audio/speak` → `{ok, data_url, mime_type, provider}` (web_server.py:1438).
///
/// IMPORTANT: the audio payload key is `data_url` (a full
/// `data:<mime>;base64,<bytes>` URL), NOT `audio`. `mime_type` echoes the
/// rendered format (e.g. `audio/mpeg` for Edge/OpenAI mp3).
struct AudioSpeakResult: Decodable, Sendable, Equatable {
    let ok: Bool
    let dataURL: String
    let mimeType: String?
    let provider: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case dataURL = "data_url"
        case mimeType = "mime_type"
        case provider
    }
}

// MARK: - Endpoints

extension RestClient {
    /// `POST /api/audio/transcribe` — server-side speech-to-text.
    ///
    /// - Parameters:
    ///   - dataURL: a full `data:<mime>;base64,<payload>` URL of the recording.
    ///   - mimeType: the recording MIME type (e.g. `audio/mp4` for AAC `.m4a`).
    /// - Returns: the transcript (already trimmed server-side); empty string if
    ///   the provider produced no text. Throws ``RestError`` on transport/HTTP
    ///   failure (e.g. 400 empty recording, 413 too large, 500 provider error).
    func transcribe(dataURL: String, mimeType: String) async throws -> String {
        let body: JSONValue = .object([
            "data_url": .string(dataURL),
            "mime_type": .string(mimeType),
        ])
        let data = try await audioPost(path: "/api/audio/transcribe", body: body)
        // AudioTranscribeResult has no explicit CodingKeys; `transcript`/`provider`
        // are already lowercase, so the default snake-case strategy is a no-op here.
        return try decode(AudioTranscribeResult.self, from: data, context: "transcribe").transcript
    }

    /// `POST /api/audio/speak` — server-side text-to-speech.
    ///
    /// - Parameter text: text to synthesize (server rejects empty/whitespace).
    /// - Returns: a `data:<mime>;base64,<payload>` URL of the rendered audio,
    ///   ready to decode for `AVAudioPlayer`. Throws ``RestError`` on failure.
    func speak(text: String) async throws -> String {
        let body: JSONValue = .object(["text": .string(text)])
        let data = try await audioPost(path: "/api/audio/speak", body: body)
        // AudioSpeakResult has explicit snake_case CodingKeys — skip the global
        // conversion (it would double-convert `data_url`).
        return try decode(
            AudioSpeakResult.self, from: data, context: "speak", strategy: .useDefaultKeys
        ).dataURL
    }

    // MARK: - Request helper (POST a JSON body via RestClient's shared plumbing)

    /// Per-request timeout for the audio endpoints (B6 / ABH-74 RIDER 5).
    ///
    /// Transcription has to upload a base64-encoded recording (up to the
    /// recorder's 2-minute cap) AND wait on the STT round-trip — well beyond the
    /// shared 15s `RestClient` default that everything else uses. We give the
    /// audio POSTs a dedicated 60s ceiling (4× the shared default) so a long
    /// dictation completes where it previously failed at 15s. Co-located here so
    /// it does not perturb the shared timeout used by every other endpoint; it is
    /// a fixed engineering constant, not a user preference (no DefaultsKeys entry).
    static let transcribeTimeout: TimeInterval = 60

    private func audioPost(path: String, body: JSONValue) async throws -> Data {
        var request = makeRequest(path: path, method: "POST")
        // Override the shared 15s timeout baked in by `makeRequest` — base64
        // upload + STT for a long recording needs the wider 60s window (B6).
        request.timeoutInterval = Self.transcribeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encodeBody(body, context: path)
        return try await perform(request)
    }
}
