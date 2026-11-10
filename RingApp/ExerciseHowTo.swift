import SwiftUI
import UIKit
import ImageIO
import Combine

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
    private let tick = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()
    private static let frameLabels = ["Start", "End"]

    private var steps: [String] { ex.exerciseInstructions ?? [] }
    private var tips: [String] { ex.tips ?? [] }
    private var hasPictures: Bool { ex.gifPath != nil || !(ex.images ?? []).isEmpty }

    private var videoLink: (url: URL, title: String)? {
        if let s = ex.videoUrl, let u = URL(string: s) { return (u, "Watch video") }
        var c = URLComponents(string: "https://www.youtube.com/results")
        c?.queryItems = [URLQueryItem(name: "search_query", value: "\(ex.exerciseName) exercise proper form")]
        return c?.url.map { ($0, "Find a video") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasPictures { media }
            if let v = videoLink {
                Link(destination: v.url) {
                    Label(v.title, systemImage: "play.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
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
                Image(uiImage: frames[min(frame, frames.count - 1)])
                    .resizable().scaledToFit()
                    .animation(.easeInOut(duration: 0.15), value: frame)
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
                            .foregroundStyle(i == frame ? .black : .white)
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
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .contentShape(Rectangle())
        .onTapGesture { if frames.count > 1 { paused.toggle() } }
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
