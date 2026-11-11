import SwiftUI
import UIKit
import ImageIO
import Combine
import SafariServices
import WebKit

/// Plays a YouTube video inline (privacy-enhanced embed). The page is loaded
/// with an https base URL so YouTube gets a referrer; embeds without one fail
/// with "video player configuration error".
struct YouTubePlayer: UIViewRepresentable {
    let videoID: String

    /// "watch?v=ID", "youtu.be/ID", "shorts/ID" or "embed/ID" -> ID.
    static func id(fromURL s: String) -> String? {
        guard let u = URL(string: s), let host = u.host?.lowercased(), host.contains("youtu") else { return nil }
        if let v = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value,
           !v.isEmpty { return v }
        let parts = u.pathComponents.filter { $0 != "/" }
        if host.contains("youtu.be") { return parts.first }
        if let i = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" || $0 == "live" }), i + 1 < parts.count {
            return parts[i + 1]
        }
        return nil
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}iframe{position:absolute;inset:0;width:100%;height:100%;border:0}</style>
        </head><body><iframe src="https://www.youtube-nocookie.com/embed/\(videoID)?playsinline=1&rel=0"
        allow="autoplay; encrypted-media; picture-in-picture; fullscreen" allowfullscreen
        referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
        let base = "https://" + (Bundle.main.bundleIdentifier ?? "naldo.fitness").lowercased() + "/"
        v.loadHTMLString(html, baseURL: URL(string: base))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}
}

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// In-app browser for exercise videos (YouTube plays inside it).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}

// MARK: - Exercise how-to (Fitness 2026-11-10)
//
// Shown inside each exercise card on the workout screen: the exercise's GIF,
// or its start/end photos played like a GIF, numbered steps, form tips and a
// video link. Pictures come from the Fitness server's /api/app/media with the
// ring token (AsyncImage can't send the token header).

@MainActor
final class ExerciseMediaCache {
    static let shared = ExerciseMediaCache()
    private var images: [String: UIImage] = [:]

    func image(_ path: String) async -> UIImage? {
        if let hit = images[path] { return hit }
        guard let req = FitnessLink.shared.request("/api/app" + path, timeout: 20),
              let reply = try? await URLSession.shared.data(for: req),
              (reply.1 as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage.animatedOrStill(reply.0) else { return nil }
        images[path] = img
        return img
    }
}

extension UIImage {
    /// GIF / animated WebP -> an animated UIImage; anything else -> a still.
    static func animatedOrStill(_ data: Data) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
        let count = CGImageSourceGetCount(src)
        guard count > 1 else { return UIImage(data: data) }
        var frames: [UIImage] = []
        var total = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            total += frameDelay(src, i)
        }
        guard !frames.isEmpty else { return UIImage(data: data) }
        return UIImage.animatedImage(with: frames, duration: total > 0 ? total : Double(frames.count) * 0.1)
    }

    private static func frameDelay(_ src: CGImageSource, _ i: Int) -> Double {
        let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
        let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let webp = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
        let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (webp?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
            ?? (webp?[kCGImagePropertyWebPDelayTime] as? Double)
            ?? 0.1
        return d < 0.02 ? 0.1 : d
    }
}

/// UIImageView plays animated UIImages; SwiftUI's Image doesn't.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFit
        v.clipsToBounds = true
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            v.setContentCompressionResistancePriority(.defaultLow, for: axis)
            v.setContentHuggingPriority(.defaultLow, for: axis)
        }
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if v.image !== image { v.image = image }
    }
}

struct ExerciseHowTo: View {
    let ex: WorkoutExercise

    @State private var gif: UIImage?
    @State private var frames: [UIImage] = []
    @State private var frame = 0
    @State private var paused = false
    @State private var loading = true
    @State private var videoURL: IdentifiedURL?
    @State private var page = 0          // 0 = GIF/photos, 1 = video
    private let tick = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()
    private static let frameLabels = ["Start", "End"]

    private var steps: [String] { ex.exerciseInstructions ?? [] }
    private var tips: [String] { ex.tips ?? [] }
    private var hasPictures: Bool { ex.gifPath != nil || !(ex.images ?? []).isEmpty }

    /// The pinned video's YouTube id, if it is a YouTube link (plays in the viewer).
    private var youTubeID: String? { ex.videoUrl.flatMap { YouTubePlayer.id(fromURL: $0) } }

    private var videoLink: (url: URL, title: String)? {
        if let s = ex.videoUrl, let u = URL(string: s) {
            return (url: u, title: youTubeID != nil ? "Video not playing? Open it" : "Watch video")
        }
        var c = URLComponents(string: "https://www.youtube.com/results")
        c?.queryItems = [URLQueryItem(name: "search_query", value: "\(ex.exerciseName) exercise proper form")]
        guard let u = c?.url else { return nil }
        return (url: u, title: "Find a video")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasPictures || youTubeID != nil { viewer }
            if let v = videoLink {
                // Opens inside the app, so the workout (and the ring recording) stays put.
                Button { videoURL = IdentifiedURL(url: v.url) } label: {
                    Label(v.title, systemImage: youTubeID != nil ? "safari" : "play.circle.fill")
                        .font(youTubeID != nil ? Font.caption : Font.subheadline.weight(.semibold))
                        .foregroundStyle(youTubeID != nil ? Color.secondary : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: youTubeID != nil ? 28 : 40)
                        .background(Color.white.opacity(youTubeID != nil ? 0 : 0.08), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
            if !steps.isEmpty {
                Text("HOW TO DO IT").font(.caption2.weight(.semibold)).tracking(1.1).foregroundStyle(.secondary)
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(i + 1)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .frame(width: 22, height: 22)
                            .background(Palette.optimal, in: Circle())
                        Text(step).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !tips.isEmpty {
                Text("FORM TIPS").font(.caption2.weight(.semibold)).tracking(1.1).foregroundStyle(.secondary)
                    .padding(.top, 2)
                ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill").font(.caption).foregroundStyle(.yellow)
                            .padding(.top, 2)
                        Text(tip).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let credit = ex.mediaCredit, !frames.isEmpty, gif == nil {
                Text(credit).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .sheet(item: $videoURL) { v in SafariView(url: v.url).ignoresSafeArea() }
        .task(id: ex.id) { await load() }
        .onReceive(tick) { _ in
            guard frames.count > 1, !paused else { return }
            frame = (frame + 1) % frames.count
        }
    }

    private var media: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 16).fill(gif != nil ? Color.white : Color.black.opacity(0.5))
            if let gif {
                AnimatedImageView(image: gif)
            } else if !frames.isEmpty {
                // Start/end photos cross-fade back and forth, like a slow GIF.
                ZStack {
                    ForEach(frames.indices, id: \.self) { i in
                        Image(uiImage: frames[i])
                            .resizable().scaledToFit()
                            .opacity(i == frame ? 1 : 0)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: frame)
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Label("Couldn't load the pictures", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if frames.count > 1 && gif == nil {
                HStack(spacing: 6) {
                    ForEach(0..<frames.count, id: \.self) { i in
                        Text(i < Self.frameLabels.count ? Self.frameLabels[i] : "\(i + 1)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .foregroundStyle(i == frame ? Color.black : Color.white)
                            .background(i == frame ? Palette.optimal : Color.black.opacity(0.5), in: Capsule())
                    }
                    Spacer()
                    Text(paused ? "Paused · tap to play" : "Tap to pause")
                        .font(.caption2).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.black.opacity(0.5), in: Capsule())
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture { if frames.count > 1 { paused.toggle() } }
    }

    // GIF/photos first; swipe (or tap "Video") for the pinned video.
    private var viewer: some View {
        let both = hasPictures && youTubeID != nil
        return VStack(spacing: 8) {
            TabView(selection: $page) {
                if hasPictures { media.tag(0) }
                if let id = youTubeID { videoPage(id).tag(1) }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 230)
            if both {
                HStack(spacing: 8) {
                    pagePill(gif != nil ? "GIF" : "Photos", "photo", 0)
                    pagePill("Video", "play.rectangle.fill", 1)
                    Spacer()
                    Text(page == 0 ? "Swipe for video ›" : "‹ Swipe for the GIF")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { if !hasPictures { page = 1 } }
    }

    private func pagePill(_ title: String, _ symbol: String, _ tag: Int) -> some View {
        Button { withAnimation { page = tag } } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .foregroundStyle(page == tag ? Color.black : Color.white)
                .background(page == tag ? Palette.optimal : Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// The player only exists while its page is showing, so swiping away stops it.
    @ViewBuilder
    private func videoPage(_ id: String) -> some View {
        if page == 1 {
            YouTubePlayer(videoID: id)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.6))
                Image(systemName: "play.circle.fill").font(.system(size: 44)).foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        if let g = ex.gifPath {
            gif = await ExerciseMediaCache.shared.image(g)
            if gif != nil { return }
        }
        var got: [UIImage] = []
        for p in ex.images ?? [] {
            if let img = await ExerciseMediaCache.shared.image(p) { got.append(img) }
        }
        frames = got
        frame = 0
    }
}
