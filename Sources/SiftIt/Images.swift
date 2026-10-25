// The pictures the panel shows: a file type's icon, a picture's thumbnail, a video's frame at a moment, a PDF page, a
// recording's loudness around a moment. Decoding happens off the main thread, at the size it's shown and no larger.

import AVFoundation
import AppKit
import ImageIO
import SiftItKit
import UniformTypeIdentifiers

/// A picture decoded off the main thread. CGImage is immutable once made.
struct Picture: @unchecked Sendable {
    let image: CGImage
}

@MainActor
final class Images {
    static let shared = Images()

    /// Row thumbnails: small, so a few hundred cost little.
    private let thumbnails: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()
    private var icons: [String: NSImage] = [:]

    /// Pictures and videos show themselves in the list; other files show their type's icon.
    static func hasThumbnail(_ hit: Hit) -> Bool {
        hit.kind.isPicture || hit.kind == .video
    }

    /// The icon for the file's type: the same for every file of a type, so it's made once. A conversation's is its own:
    /// its log's type says nothing.
    func icon(for hit: Hit) -> NSImage {
        if hit.kind == .conversation {
            if let icon = icons["conversation"] { return icon }
            let icon = Self.conversationIcon()
            icons["conversation"] = icon
            return icon
        }
        let type = (hit.path as NSString).pathExtension.lowercased()
        if let icon = icons[type] { return icon }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: type) ?? .data)
        icons[type] = icon
        return icon
    }

    /// Two speech bubbles, white on an indigo tile: it shows on a selected row too.
    private static func conversationIcon() -> NSImage {
        NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
            let tile = rect.insetBy(dx: 2, dy: 2)
            NSColor.systemIndigo.setFill()
            NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let symbol = NSImage(
                systemSymbolName: "bubble.left.and.bubble.right.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            {
                let size = symbol.size
                symbol.draw(
                    in: NSRect(
                        x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width,
                        height: size.height))
            }
            return true
        }
    }

    func cachedThumbnail(for hit: Hit) -> NSImage? {
        thumbnails.object(forKey: Self.key(hit))
    }

    func thumbnail(for hit: Hit, points: CGFloat) async -> NSImage? {
        let pixels = Int(points * 2)
        let picture =
            hit.kind == .video
            ? await Self.frame(hit.url, at: hit.loc ?? 0, pixels: pixels, exact: false)
            : await Self.picture(hit.url, pixels: pixels)
        guard let picture else { return nil }
        let image = NSImage(cgImage: picture.image, size: .zero)
        thumbnails.setObject(image, forKey: Self.key(hit))
        return image
    }

    private static func key(_ hit: Hit) -> NSString {
        "\(hit.path)#\(hit.loc ?? 0)" as NSString
    }

    // MARK: - Decoding, off the main thread

    /// A picture fitted in `pixels`. Small ones come from the thumbnail a photo carries, when it has one.
    nonisolated static func picture(_ url: URL, pixels: Int) async -> Picture? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                pixels > 256
                    ? kCGImageSourceCreateThumbnailFromImageAlways : kCGImageSourceCreateThumbnailFromImageIfAbsent:
                    true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(Picture.init)
        }.value
    }

    /// A video's frame at a moment. Exact is the frame itself; else the nearest that decodes fast.
    nonisolated static func frame(_ url: URL, at seconds: Double, pixels: Int, exact: Bool) async -> Picture? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: pixels, height: pixels)
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return (try? await generator.image(at: time)).map { Picture(image: $0.image) }
    }

    /// A PDF page (from 1) on white, fitted in `pixels`.
    nonisolated static func page(_ url: URL, _ number: Int, pixels: Int) async -> Picture? {
        await Task.detached(priority: .userInitiated) {
            guard let document = CGPDFDocument(url as CFURL),
                let page = document.page(at: min(max(1, number), document.numberOfPages))
            else { return nil }
            let box = page.getBoxRect(.cropBox)
            let turned = page.rotationAngle % 180 != 0
            let size = turned ? CGSize(width: box.height, height: box.width) : box.size
            let scale = CGFloat(pixels) / max(size.width, size.height)
            let width = Int(size.width * scale)
            let height = Int(size.height * scale)
            guard width > 0, height > 0,
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            context.setFillColor(.white)
            context.fill(rect)
            context.interpolationQuality = .high
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            return context.makeImage().map(Picture.init)
        }.value
    }

    /// A recording's loudness from `start` to `end` seconds, in `columns` slices from 0 to 1. Only that stretch is
    /// decoded, at a rate far below the recording's: about 100 ms for two minutes of a podcast.
    nonisolated static func levels(_ url: URL, from start: Double, to end: Double, columns: Int) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard end > start, let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let reader = try? AVAssetReader(asset: asset)
        else { return nil }
        // The lowest rate AVFoundation converts to: lower, and it throws.
        let rate = 8000.0
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1,
                AVSampleRateKey: rate,
            ])
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600))
        guard reader.startReading() else { return nil }

        let perColumn = max(1, Int((end - start) * rate) / columns)
        var levels = [Float](repeating: 0, count: columns)
        var sample = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard
                CMBlockBufferGetDataPointer(
                    block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil,
                    dataPointerOut: &pointer) == noErr, let pointer
            else { continue }
            pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { floats in
                for index in 0..<(length / 4) {
                    let column = min(sample / perColumn, columns - 1)
                    levels[column] = max(levels[column], abs(floats[index]))
                    sample += 1
                }
            }
        }
        let loudest = levels.max() ?? 0
        return loudest > 0 ? levels.map { $0 / loudest } : levels
    }
}
