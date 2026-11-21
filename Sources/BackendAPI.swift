import Foundation
import Security
import UIKit

// MARK: - Models

/// One frame → who the graph thinks is in front of you.
struct Recognition {
    let matched: Bool
    let name: String
    let role: String
    let org: String
    /// The line the backend composed for the ear / lens.
    let spoken: String
    let score: Double
    let elapsedMs: Int

    var title: String {
        if name.isEmpty { return "No match" }
        if org.isEmpty { return name }
        return "\(name), \(org)"
    }
}

/// The lookup card: who they are and what to say next.
struct LookupCard: Identifiable {
    let id = UUID()
    let found: Bool
    let name: String
    let org: String
    let headline: String
    let lines: [String]
    let topics: [String]
    let followups: [String]
    let history: [HistoryEntry]
    let date = Date()

    struct HistoryEntry: Identifiable {
        let id = UUID()
        let when: String
        let what: String
        let kind: String
    }

    static func empty(name: String) -> LookupCard {
        LookupCard(
            found: false, name: name, org: "", headline: "",
            lines: [], topics: [], followups: [], history: []
        )
    }
}

/// The result of POST /api/enroll, without throwing.
///
/// The backend answers a frame with no detectable face with
/// `{"enrolled": false, "reason": "no face detected in the reference photo"}`,
/// which is guidance rather than an error — so auto-enroll can show it as
/// "get a bit closer" instead of a red banner.
struct EnrollOutcome {
    let enrolled: Bool
    let name: String
    /// True when the face was attached to a Person the graph already had —
    /// i.e. the conversation ingest just created.
    let attachedToExisting: Bool
    let knownInteractions: Int
    let reason: String

    var noFaceDetected: Bool {
        !enrolled && reason.lowercased().contains("no face")
    }

    var friendlyReason: String {
        if noFaceDetected {
            return "Couldn't find a face in that frame — get a little closer, hold steady, and make sure they're lit."
        }
        return reason.isEmpty ? "Enrollment failed." : reason
    }
}

/// What /api/ingest pulled out of a conversation.
struct IngestReceipt: Identifiable {
    let id = UUID()
    let saved: String
    let newPerson: Bool
    /// Job title, when the speaker stated one. Empty otherwise.
    let role: String
    let org: String
    let topics: [String]
    let newTopics: [String]
    let followups: [String]
    let date = Date()

    /// True when the extractor actually named the speaker, as opposed to
    /// reporting `saved: ""` because nobody introduced themselves.
    var namedSomeone: Bool {
        FaceCache.usableRealName(saved) != nil
    }

    /// Whether the conversation supplied a title or a company. `ingest` stores
    /// either one itself when the person's record has none yet.
    var hasProfileDetail: Bool {
        !role.isEmpty || !org.isEmpty
    }
}

/// Answer to "ask your network".
struct NetworkAnswer {
    struct Match: Identifiable {
        let id = UUID()
        let name: String
        let org: String
        let last: String
    }

    let matches: [Match]
    let reason: String
    let searched: Int
}

/// A row in the roster.
struct RosterPerson: Identifiable {
    let name: String
    let role: String
    let org: String
    let relationship: String
    let enrolledFace: Bool
    let encounters: Int

    var id: String { name }

    var subtitle: String {
        [role, org].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

struct PersonCard {
    let name: String
    let md: String
}

struct TimelineEvent: Identifiable {
    let id = UUID()
    let ts: String
    let kind: String
    let text: String
}

// MARK: - API client

/// Client for the backend you run yourself. Every endpoint is a JSON POST to
/// `/api/<name>` that answers `{"ok": true, "data": {...}}`, or
/// `{"ok": false, "error": "..."}` when something went wrong.
/// JSONSerialization is used throughout and every field is optional-safe, so
/// minor schema drift degrades instead of crashing the demo.
enum BackendAPI {
    /// Where the backend listens when it runs on the same machine. This only
    /// reaches it from the Simulator; on a real iPhone, enter the address the
    /// server prints when it starts (Connect → Graph backend).
    static let defaultBase = "http://localhost:8000"

    /// UserDefaults key for the backend address entered in Glasses › Backend.
    static let baseURLKey = "backendBaseURL"

    static var baseString: String {
        let stored = UserDefaults.standard.string(forKey: baseURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var base = stored.isEmpty ? defaultBase : stored
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    /// The `Authorization` header for the backend's password, or nil when
    /// none is set. The backend asks for it as HTTP Basic authentication; the
    /// user name is always `thread`.
    static var authorization: String? {
        let password = BackendPassword.value
        guard !password.isEmpty else { return nil }
        return "Basic " + Data("\(BackendPassword.user):\(password)".utf8).base64EncodedString()
    }

    enum APIError: LocalizedError {
        case badURL
        case server(status: Int, body: String)
        case backend(message: String)
        case password(missing: Bool)

        var errorDescription: String? {
            switch self {
            case let .password(missing):
                return missing
                    ? "This backend needs a password. Enter it in Glasses › Backend."
                    : "The backend didn't accept the password in Glasses › Backend."
            case .badURL:
                return "The backend address in Glasses › Backend looks invalid."
            case let .server(status, body):
                let snippet = body.isEmpty ? "an empty body" : "“\(body)”"
                return "Server replied \(status) with \(snippet) — check the backend address in Glasses › Backend."
            case let .backend(message):
                return message
            }
        }
    }

    /// POSTs `body` to `path` and returns the response's `data` object.
    /// Throws `APIError.backend` with the server's own message when it
    /// answers `"ok": false`.
    @discardableResult
    static func post(
        _ path: String, _ body: [String: Any] = [:], timeout: TimeInterval = 60
    ) async throws -> [String: Any] {
        guard let url = URL(string: baseString + path) else {
            throw APIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // Say which call failed and why, so "couldn't reach the backend"
            // can be told apart: no network, wrong address, timeout, refused.
            let nsError = error as NSError
            print("[thread] backend \(path) failed: \(nsError.domain) \(nsError.code) — \(error.localizedDescription) (\(url.absoluteString))")
            throw error
        }
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            throw APIError.password(missing: authorization == nil)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let snippet = String(decoding: data.prefix(200), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw APIError.server(status: status, body: snippet)
        }
        if let ok = json["ok"] as? Bool, !ok {
            let message = (json["error"] as? String)
                ?? (json["message"] as? String)
                ?? "The backend said no without a reason."
            throw APIError.backend(message: message)
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    // MARK: Helpers

    private static func strings(_ any: Any?) -> [String] {
        (any as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func str(_ any: Any?) -> String {
        (any as? String) ?? ""
    }

    // MARK: Endpoints

    /// Face recognition from one frame.
    static func recognize(jpeg: Data) async throws -> Recognition {
        let payload = try await post(
            "/api/recognize", ["frame_b64": jpeg.base64EncodedString()],
            timeout: 90
        )
        return Recognition(
            matched: (payload["matched"] as? Bool) ?? false,
            name: str(payload["name"]),
            role: str(payload["role"]),
            org: str(payload["org"]),
            spoken: str(payload["spoken"]),
            score: (payload["score"] as? NSNumber)?.doubleValue ?? 0,
            elapsedMs: (payload["elapsed_ms"] as? NSNumber)?.intValue ?? 0
        )
    }

    /// The lookup card for a person — pass "last" for the most recent contact.
    static func lookup(name: String = "last") async throws -> LookupCard {
        let payload = try await post("/api/lookup", ["name": name], timeout: 90)
        let history = (payload["history"] as? [[String: Any]] ?? []).map {
            LookupCard.HistoryEntry(
                when: str($0["when"]),
                what: str($0["what"]),
                kind: str($0["kind"])
            )
        }
        return LookupCard(
            found: (payload["found"] as? Bool) ?? false,
            name: str(payload["name"]).isEmpty ? name : str(payload["name"]),
            org: str(payload["org"]),
            headline: str(payload["headline"]),
            lines: strings(payload["lines"]),
            topics: strings(payload["topics"]),
            followups: strings(payload["followups"]),
            history: history
        )
    }

    /// Feed a conversation transcript into the graph.
    ///
    /// `speaker` pins the conversation onto a person we already identified by
    /// face — the backend prefers it over any name the extractor thinks it
    /// heard, which stops "Sarah" in the transcript creating a second node.
    /// UserDefaults key for Your Name in the Glasses tab.
    static let wearerNameKey = "wearerName"

    /// The wearer's own name, if they have set it.
    static var wearerName: String {
        (UserDefaults.standard.string(forKey: wearerNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func ingest(
        transcript: String, speaker: String = ""
    ) async throws -> IngestReceipt {
        var body: [String: Any] = ["transcript": transcript]
        if !speaker.isEmpty { body["speaker"] = speaker }
        // The wearer introduces themselves too; the backend must never file
        // them as the person they are meeting.
        if !wearerName.isEmpty { body["wearer"] = wearerName }
        // The exact bytes going to the graph, logged at the boundary so the
        // on-screen text can be checked against what was actually posted.
        print(
            "[thread] POST /api/ingest speaker=\"\(speaker)\" "
                + "transcript(\(transcript.count) chars)=\"\(transcript)\""
        )
        let payload = try await post("/api/ingest", body, timeout: 120)
        let org = str(payload["org"]).isEmpty
            ? str(payload["company"])
            : str(payload["org"])
        return IngestReceipt(
            saved: str(payload["saved"]),
            newPerson: (payload["new_person"] as? Bool) ?? false,
            role: str(payload["role"]).isEmpty
                ? str(payload["title"])
                : str(payload["role"]),
            org: org,
            topics: strings(payload["topics"]),
            newTopics: strings(payload["new_topics"]),
            followups: strings(payload["followups"])
        )
    }

    /// Free-text question over everyone you've met.
    static func query(question: String) async throws -> NetworkAnswer {
        let payload = try await post(
            "/api/query", ["question": question], timeout: 120
        )
        let matches = (payload["matches"] as? [[String: Any]] ?? []).map {
            NetworkAnswer.Match(
                name: str($0["name"]),
                org: str($0["org"]),
                last: str($0["last"])
            )
        }
        return NetworkAnswer(
            matches: matches,
            reason: str(payload["reason"]),
            searched: (payload["searched"] as? NSNumber)?.intValue ?? matches.count
        )
    }

    /// Everyone in the graph. The backend can hold duplicate names after
    /// repeated seeding, so rows are merged by name here.
    static func roster() async throws -> [RosterPerson] {
        let payload = try await post("/api/roster")
        let rows = payload["people"] as? [[String: Any]] ?? []
        var order: [String] = []
        var merged: [String: RosterPerson] = [:]
        for row in rows {
            let name = str(row["name"])
            guard !name.isEmpty else { continue }
            let person = RosterPerson(
                name: name,
                role: str(row["role"]),
                org: str(row["org"]),
                relationship: str(row["relationship"]),
                enrolledFace: (row["enrolled_face"] as? Bool) ?? false,
                encounters: (row["encounters"] as? NSNumber)?.intValue ?? 0
            )
            if let existing = merged[name] {
                merged[name] = RosterPerson(
                    name: name,
                    role: existing.role.isEmpty ? person.role : existing.role,
                    org: existing.org.isEmpty ? person.org : existing.org,
                    relationship: existing.relationship.isEmpty
                        ? person.relationship : existing.relationship,
                    enrolledFace: existing.enrolledFace || person.enrolledFace,
                    encounters: max(existing.encounters, person.encounters)
                )
            } else {
                merged[name] = person
                order.append(name)
            }
        }
        return order.compactMap { merged[$0] }
    }

    /// Attach a face to a person — creates them if they aren't in the graph.
    ///
    /// Returns the outcome rather than throwing on `enrolled: false`, because
    /// "no face detected" is guidance the UI should show gently. Network and
    /// server failures still throw.
    static func enrollOutcome(
        name: String,
        photoJpeg: Data,
        role: String = "",
        org: String = "",
        relationship: String = "",
        notes: String = ""
    ) async throws -> EnrollOutcome {
        // The backend keeps a thumbnail of this same frame as the person's
        // avatar, so the photo does not need sending separately.
        let body: [String: Any] = [
            "name": name,
            "frame_b64": photoJpeg.base64EncodedString(),
            "role": role,
            "org": org,
            "relationship": relationship,
            "notes": notes,
        ]
        let payload = try await post("/api/enroll", body, timeout: 120)
        return EnrollOutcome(
            enrolled: (payload["enrolled"] as? Bool) ?? false,
            name: str(payload["name"]).isEmpty ? name : str(payload["name"]),
            attachedToExisting: (payload["attached_to_existing"] as? Bool) ?? false,
            knownInteractions: (payload["known_interactions"] as? NSNumber)?.intValue ?? 0,
            reason: str(payload["reason"])
        )
    }

    /// Throwing wrapper kept for the manual Enroll sheet, where a failure is a
    /// genuine error the form should show.
    @discardableResult
    static func enroll(
        name: String,
        role: String,
        org: String,
        relationship: String,
        notes: String = "",
        photoJpeg: Data
    ) async throws -> String {
        let outcome = try await enrollOutcome(
            name: name, photoJpeg: photoJpeg, role: role, org: org,
            relationship: relationship, notes: notes
        )
        guard outcome.enrolled else {
            throw APIError.backend(message: outcome.friendlyReason)
        }
        return outcome.attachedToExisting
            ? "Face attached to \(outcome.name)'s existing record."
            : "\(outcome.name) added to your network."
    }

    /// Rename an auto-enrolled contact.
    ///
    /// The backend has no rename endpoint: `enroll` matches an existing
    /// person only by exact or fuzzy *name*, so re-enrolling under the real
    /// name creates (or merges into) the right record, and the placeholder is
    /// then removed with `forget`. The same reference frame is replayed so the
    /// face signature moves with the name.
    static func rename(
        from placeholder: String,
        to newName: String,
        photoJpeg: Data,
        role: String = "",
        org: String = "",
        relationship: String = ""
    ) async throws -> EnrollOutcome {
        let outcome = try await enrollOutcome(
            name: newName, photoJpeg: photoJpeg, role: role, org: org,
            relationship: relationship
        )
        guard outcome.enrolled else {
            throw APIError.backend(message: outcome.friendlyReason)
        }
        if placeholder.caseInsensitiveCompare(newName) != .orderedSame {
            try? await forget(name: placeholder)
        }
        return outcome
    }

    static func personCard(name: String) async throws -> PersonCard {
        let payload = try await post("/api/person_card", ["name": name], timeout: 90)
        return PersonCard(
            name: str(payload["name"]).isEmpty ? name : str(payload["name"]),
            md: str(payload["md"])
        )
    }

    static func timeline() async throws -> [TimelineEvent] {
        let payload = try await post("/api/timeline")
        let events = payload["events"] as? [[String: Any]] ?? []
        return events.map {
            TimelineEvent(
                ts: str($0["ts"]),
                kind: str($0["kind"]),
                text: str($0["text"])
            )
        }
    }

    static func forget(name: String) async throws {
        try await post("/api/forget", ["name": name])
    }

    static func seed() async throws {
        try await post("/api/seed", [:], timeout: 120)
    }

    static func reset() async throws {
        try await post("/api/reset", [:], timeout: 120)
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// The backend's password, kept in the Keychain rather than with the other
/// settings. Empty when the backend has none, as on a computer on the same
/// Wi-Fi.
enum BackendPassword {
    /// The user name that goes with it. The backend checks only the password.
    static let user = "thread"

    /// Counts changes, so views that use the password (the map) know to load
    /// again. Only the count is in UserDefaults, never the password.
    static let changesKey = "backendPasswordChanges"

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.threadglasses.app.backend",
        kSecAttrAccount as String: "password",
    ]

    static var value: String {
        get {
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data
            else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let password = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard password != value else { return }
            SecItemDelete(query as CFDictionary)
            if !password.isEmpty {
                var item = query
                item[kSecValueData as String] = Data(password.utf8)
                // Meet calls the backend with the phone in a pocket, locked.
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                SecItemAdd(item as CFDictionary, nil)
            }
            UserDefaults.standard.set(
                UserDefaults.standard.integer(forKey: changesKey) + 1, forKey: changesKey)
        }
    }
}
