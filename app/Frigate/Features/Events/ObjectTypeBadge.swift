import SwiftUI

/// Small overlay badge showing what kind of object a review segment detected (person, car, ...),
/// meant to sit on top of a thumbnail. Icon-only by design - the thumbnail is the point, this is
/// just enough to tell alert types apart at a glance without reading text.
struct ObjectTypeBadge: View {
    let objects: [String]

    var body: some View {
        Image(systemName: Self.systemImage(for: objects))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(.black.opacity(0.45), in: Circle())
    }

    /// When a segment saw more than one object type, picks alphabetically first so the badge is
    /// stable across reloads rather than flickering between icons.
    private static func systemImage(for objects: [String]) -> String {
        guard let label = Array(Set(objects)).sorted().first else {
            // Audio-only or otherwise uncategorized activity.
            return "sensor.tag.radiowaves.forward.fill"
        }
        return iconsByLabel[label] ?? "viewfinder"
    }

    /// Frigate's default model reports COCO labels; Frigate+ adds a handful of custom ones
    /// (package, license_plate, common yard animals). Unrecognized labels fall back to a generic
    /// viewfinder icon rather than guessing.
    private static let iconsByLabel: [String: String] = [
        "person": "person.fill",
        "face": "person.crop.circle",
        "car": "car.fill",
        "bicycle": "bicycle",
        "motorcycle": "scooter",
        "bus": "bus.fill",
        "truck": "box.truck.fill",
        "boat": "ferry.fill",
        "train": "tram.fill",
        "airplane": "airplane",
        "dog": "dog.fill",
        "cat": "cat.fill",
        "bird": "bird.fill",
        "horse": "figure.equestrian.sports",
        "deer": "pawprint.fill",
        "raccoon": "pawprint.fill",
        "squirrel": "pawprint.fill",
        "fox": "pawprint.fill",
        "skunk": "pawprint.fill",
        "rabbit": "pawprint.fill",
        "package": "shippingbox.fill",
        "license_plate": "rectangle.and.text.magnifyingglass",
    ]
}
