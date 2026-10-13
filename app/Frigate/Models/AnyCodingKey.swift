import Foundation

/// A `CodingKey` that accepts whatever key the document actually carries. Needed wherever a JSON
/// object's keys are *user-defined names* rather than a fixed schema - go2rtc stream names, live
/// stream labels - so we can read the key set (and its declaration order) without modelling the
/// values.
nonisolated struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
