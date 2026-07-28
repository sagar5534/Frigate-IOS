import Foundation

/// A decoded row from `/api/review` - an activity segment (not a single tracked object; see
/// `data.detections` for the object ids inside it). This is what the Events tab surfaces: alert/
/// detection severity, a time span, and a summary of what was seen.
nonisolated struct ReviewSegment: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let camera: String
    let startTime: Double
    let endTime: Double?
    let severity: Severity
    let hasBeenReviewed: Bool
    let thumbPath: String
    let data: ReviewData

    enum Severity: String, Sendable, Equatable, CaseIterable {
        case alert, detection

        var displayName: String { rawValue.capitalized }
    }

    struct ReviewData: Decodable, Equatable, Sendable {
        let detections: [String]
        let objects: [String]
        let subLabels: [String]
        let zones: [String]
        let audio: [String]

        enum CodingKeys: String, CodingKey {
            case detections, objects, zones, audio
            case subLabels = "sub_labels"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            detections = try container.decodeIfPresent([String].self, forKey: .detections) ?? []
            objects = try container.decodeIfPresent([String].self, forKey: .objects) ?? []
            subLabels = try container.decodeIfPresent([String].self, forKey: .subLabels) ?? []
            zones = try container.decodeIfPresent([String].self, forKey: .zones) ?? []
            audio = try container.decodeIfPresent([String].self, forKey: .audio) ?? []
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, camera, severity, data
        case startTime = "start_time"
        case endTime = "end_time"
        case hasBeenReviewed = "has_been_reviewed"
        case thumbPath = "thumb_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        camera = try container.decode(String.self, forKey: .camera)
        startTime = try container.decode(Double.self, forKey: .startTime)
        endTime = try container.decodeIfPresent(Double.self, forKey: .endTime)
        // An unrecognized future severity falls back to `.detection` (the quieter case) rather
        // than dropping the whole page.
        let rawSeverity = try container.decode(String.self, forKey: .severity)
        severity = Severity(rawValue: rawSeverity) ?? .detection
        hasBeenReviewed = try container.decode(Bool.self, forKey: .hasBeenReviewed)
        thumbPath = try container.decode(String.self, forKey: .thumbPath)
        data = try container.decode(ReviewData.self, forKey: .data)
    }

    var startDate: Date { Date(timeIntervalSince1970: startTime) }

    /// Still ongoing - the server hasn't closed out `end_time` yet.
    var isInProgress: Bool { endTime == nil }

    var duration: TimeInterval? {
        guard let endTime else { return nil }
        return endTime - startTime
    }

    /// `thumb_path` comes back as a server filesystem path (`/media/frigate/clips/...`); the
    /// actual HTTP route serves the same file off `/clips/...`, so strip that prefix.
    var thumbnailPath: String {
        let prefix = "/media/frigate/"
        if thumbPath.hasPrefix(prefix) {
            return String(thumbPath.dropFirst(prefix.count))
        }
        return thumbPath.hasPrefix("/") ? String(thumbPath.dropFirst()) : thumbPath
    }

    /// e.g. "Person, Car" for a card subtitle; falls back to the severity when no objects were
    /// categorized (can happen for audio-only detections).
    var objectSummary: String {
        let unique = Array(Set(data.objects)).sorted()
        guard !unique.isEmpty else { return severity.displayName }
        return unique.map(\.capitalized).joined(separator: ", ")
    }
}
