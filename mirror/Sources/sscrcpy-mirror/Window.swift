import AppKit
import AVFoundation

/// The window showing the device screen. It keeps the video's aspect ratio, follows
/// rotation, and ends the program when it closes or the video ends.
final class MirrorWindow {
    private let server: Server
    private let window: NSWindow
    private let layer = AVSampleBufferDisplayLayer()
    private var videoSize: NSSize
    /// The video size before a rotation in full screen: the window follows once it leaves
    /// full screen, as in scrcpy.
    private var fullScreenVideoSize: NSSize?

    init(server: Server, title: String, videoSize: NSSize) {
        self.server = server
        self.videoSize = videoSize
        layer.backgroundColor = .black
        let view = NSView()
        view.layer = layer
        view.wantsLayer = true
        let size = optimalSize(videoSize, content: videoSize, screen: NSScreen.main?.visibleFrame)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentAspectRatio = videoSize
        window.contentView = view
        window.center()
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [self] _ in
            MainActor.assumeIsolated { quit(0) }
        }
        center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [self] _ in
            MainActor.assumeIsolated {
                guard let old = fullScreenVideoSize else { return }
                fullScreenVideoSize = nil
                fit(from: old)
            }
        }
    }

    /// Shows the window and the video. The program exits with status 2 when the device
    /// disconnects, 1 when the video fails.
    func start() {
        window.makeKeyAndOrderFront(nil)
        // The renderer, unlike the layer, accepts frames from any thread.
        nonisolated(unsafe) let renderer = layer.sampleBufferRenderer
        let video = server.video
        let reader = Thread { [self] in
            do {
                try receiveVideo(video, to: renderer) { width, height in
                    DispatchQueue.main.async { self.resize(to: NSSize(width: width, height: height)) }
                }
                DispatchQueue.main.async { self.quit(2) }
            } catch {
                DispatchQueue.main.async {
                    FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
                    self.quit(1)
                }
            }
        }
        reader.qualityOfService = .userInteractive
        reader.start()
    }

    func quit(_ status: Int32) -> Never {
        server.stop()
        exit(status)
    }

    private func resize(to new: NSSize) {
        guard new != videoSize else { return }
        let old = videoSize
        videoSize = new
        if window.styleMask.contains(.fullScreen) {
            fullScreenVideoSize = fullScreenVideoSize ?? old
        } else {
            fit(from: old)
        }
    }

    /// Follows rotation as scrcpy does: scales the window by the change of the video size,
    /// keeping its top-left corner, then keeps it on its screen.
    private func fit(from old: NSSize) {
        let current = window.contentRect(forFrameRect: window.frame).size
        let scaled = NSSize(
            width: Int(current.width) * Int(videoSize.width) / Int(old.width),
            height: Int(current.height) * Int(videoSize.height) / Int(old.height)
        )
        let visible = window.screen?.visibleFrame
        let size = optimalSize(scaled, content: videoSize, screen: visible)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible {
            frame.origin.x = min(frame.origin.x, visible.maxX - frame.width)
            frame.origin.y = max(frame.origin.y, visible.minY)
        }
        window.contentAspectRatio = videoSize
        window.setFrame(frame, display: true)
    }
}

/// The window content size scrcpy chooses: the largest size up to `size` (in points) that
/// keeps the aspect ratio of `content` and fits `screen` with a 96-point margin.
func optimalSize(_ size: NSSize, content: NSSize, screen: NSRect?) -> NSSize {
    var width = Int(size.width)
    var height = Int(size.height)
    if let screen {
        width = min(width, Int(screen.width) - 96)
        height = min(height, Int(screen.height) - 96)
    }
    let (w, h) = (Int(content.width), Int(content.height))
    if w * height > h * width {
        return NSSize(width: width, height: h * width / w)
    }
    return NSSize(width: w * height / h, height: height)
}
