import Foundation
import OSLog
import SwiftUI
import UIKit

/// The MJPEG rung of the live-view ladder (P4.2) - the floor: Frigate's own
/// `multipart/x-mixed-replace` feed over the same `FrigateClient` HTTP path as everything else.
///
/// No go2rtc, no ports, no codecs - just JPEGs off the detect stream, which is why this is the
/// **only** tier that works for every camera on every network, restreamed or not. It is also the
/// most expensive tier *for the server* (it JPEG-encodes per connected client), which is why it is
/// the last rung rather than the first. See ADR-012.
@MainActor
final class MJPEGLivePlayer: LivePlayer {
    let transport: LiveTransport
    let supportsAudio = false
    private(set) var isMuted = true
    var onStateChange: (@MainActor (LivePlayerState) -> Void)?
    var onVideoSizeChange: (@MainActor (CGSize) -> Void)?

    private(set) var videoSize: CGSize? {
        didSet {
            guard let videoSize, videoSize != oldValue else { return }
            onVideoSizeChange?(videoSize)
        }
    }

    private(set) var state: LivePlayerState = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    private let camera: String
    private let height: Int
    private let fps: Int
    private let client: FrigateClient
    private let imageView: UIImageView

    private var streamTask: Task<Void, Never>?
    private let frameWatchdog = FrameLivenessWatchdog()
    private var isStarted = false
    private var connectionEpoch = 0
    private var hasPlayed = false
    private var hasVideo = false
    private var lastFrameAt: ContinuousClock.Instant?

    /// Feed the parser roughly this often. Small enough that a frame is shown as soon as its last
    /// bytes arrive, large enough that the scan cost stays negligible.
    private nonisolated static let parseChunkSize = 2048

    init(camera: String, height: Int, fps: Int, client: FrigateClient) {
        self.transport = .mjpeg(camera: camera, height: height, fps: fps)
        self.camera = camera
        self.height = height
        self.fps = fps
        self.client = client
        self.imageView = UIImageView()
        // Match the other tiers: show the whole frame regardless of camera aspect ratio.
        // An empty UIImageView remains transparent until the first frame lands.
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
    }

    var view: AnyView {
        AnyView(MJPEGVideoView(imageView: imageView))
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        connectionEpoch += 1
        let epoch = connectionEpoch
        state = .connecting
        streamTask = Task { await self.run(epoch: epoch) }
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
    }

    func stop() {
        isStarted = false
        hasPlayed = false
        hasVideo = false
        lastFrameAt = nil
        videoSize = nil

        frameWatchdog.cancel()
        streamTask?.cancel()
        streamTask = nil
        imageView.image = nil

        state = .idle
    }

    private func transition(to newState: LivePlayerState) {
        guard isStarted else { return }
        state = newState
    }

    private func isStale(_ epoch: Int) -> Bool {
        !isStarted || epoch != connectionEpoch
    }

    // MARK: Streaming

    private func run(epoch: Int) async {
        do {
            let (bytes, response) = try await client.byteStream(
                for: .mjpegFeed(camera: camera, height: height, fps: fps)
            )
            guard !isStale(epoch) else { return }
            LiveLog.logger.info("mjpeg stream open camera=\(self.camera, privacy: .public) height=\(self.height, privacy: .public) fps=\(self.fps, privacy: .public)")

            let frames = Self.decodedFrames(from: bytes, boundary: Self.boundary(from: response), camera: camera)
            for try await image in frames {
                // Checked before showing anything: a stop() can land while this task is parked on
                // the await, and a frame shown after it would repopulate a view that teardown
                // just cleared.
                guard !isStale(epoch) else { return }
                show(image)
            }

            guard !isStale(epoch) else { return }
            LiveLog.logger.info("mjpeg stream ended camera=\(self.camera, privacy: .public)")
            transition(to: .failed(hasPlayed ? .connectionLost : .signalingFailed))
        } catch let error as MultipartFrameParser.ParseError {
            // Megabytes with no frame boundary: whatever this stream is, it isn't the feed - a
            // structural fact, not a network blip, so it must not earn reconnect attempts.
            guard !isStale(epoch) else { return }
            LiveLog.logger.error("mjpeg stream unparsable camera=\(self.camera, privacy: .public) error=\(String(describing: error), privacy: .public)")
            transition(to: .failed(.decodeFailed))
        } catch {
            guard !isStale(epoch) else { return }
            LiveLog.logger.error("mjpeg stream failed camera=\(self.camera, privacy: .public) error=\(String(describing: error), privacy: .public)")
            transition(to: .failed(hasPlayed ? .connectionLost : .signalingFailed))
        }
    }

    /// Pumps bytes, splits parts, and decodes JPEGs, all **off the main actor** - the stream runs
    /// for as long as the screen is open at hundreds of kilobytes per second, none of which
    /// belongs on the thread doing UI. Only the finished `UIImage` (immutable, `Sendable`) crosses
    /// back. Cancelling the consuming loop cancels the pump, which cancels the HTTP transfer.
    private nonisolated static func decodedFrames(
        from bytes: URLSession.AsyncBytes,
        boundary: String,
        camera: String
    ) -> AsyncThrowingStream<UIImage, Error> {
        AsyncThrowingStream { continuation in
            let pump = Task {
                var parser = MultipartFrameParser(boundary: boundary)
                var chunk: [UInt8] = []
                chunk.reserveCapacity(parseChunkSize)
                do {
                    for try await byte in bytes {
                        chunk.append(byte)
                        // Parse on size, and on any newline so a frame's final bytes (which end
                        // CRLF CRLF) never sit waiting for the buffer to fill.
                        guard chunk.count >= parseChunkSize || byte == 0x0A else { continue }
                        let frames = try parser.append(chunk)
                        chunk.removeAll(keepingCapacity: true)
                        for frame in frames {
                            if let image = UIImage(data: frame) {
                                continuation.yield(image)
                            } else {
                                // Dropped rather than fatal: the stream re-syncs at the next
                                // boundary, and one bad JPEG shouldn't tear down a working feed.
                                LiveLog.logger.error("mjpeg frame did not decode camera=\(camera, privacy: .public) bytes=\(frame.count, privacy: .public)")
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    private func show(_ image: UIImage) {
        lastFrameAt = .now
        imageView.image = image
        videoSize = image.size
        markVideoArrived()
    }

    /// Unlike the other tiers there is no pipeline between arrival and display - setting the image
    /// *is* rendering - so first frame genuinely means pixels on screen.
    private func markVideoArrived() {
        guard !hasVideo else { return }
        LiveLog.logger.info("mjpeg first frame camera=\(self.camera, privacy: .public)")
        hasVideo = true
        hasPlayed = true
        startFrameWatchdog()
        transition(to: .playing)
    }

    private func startFrameWatchdog() {
        frameWatchdog.start(
            lastFrameAt: { [weak self] in self?.lastFrameAt },
            onStall: { [weak self] in
                guard let self else { return }
                LiveLog.logger.info("mjpeg frames stopped camera=\(self.camera, privacy: .public)")
                self.hasVideo = false
                self.transition(to: .stalled)
            }
        )
    }

    /// From the response's `Content-Type: multipart/x-mixed-replace;boundary=frame`. Frigate
    /// hardcodes `frame`, but the header says so explicitly - believe the header.
    nonisolated static func boundary(from response: HTTPURLResponse) -> String {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type"),
              let range = contentType.range(of: "boundary=")
        else { return "frame" }
        let raw = contentType[range.upperBound...]
            .prefix { $0 != ";" }
            .trimmingCharacters(in: .whitespaces)
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return unquoted.isEmpty ? "frame" : unquoted
    }
}

/// Hosts the player-owned `UIImageView` - the whole render surface this tier needs.
struct MJPEGVideoView: UIViewRepresentable {
    let imageView: UIImageView

    func makeUIView(context: Context) -> UIImageView {
        imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}
}
