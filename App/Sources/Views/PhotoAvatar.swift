import ChatNet
import ChatSync
import SwiftUI

/// Decoded 64 px profile photos shared by every row; the oldest go first past `capacity`.
@MainActor
final class AvatarImages {
    static let shared = AvatarImages()
    static let capacity = 200

    private var images: [URL: DecodedImage] = [:]
    private var order: [URL] = []
    private var failed: Set<URL> = []

    func cached(_ url: URL) -> CGImage? { images[url]?.image }

    func load(_ url: URL, media: MediaLoader) async -> CGImage? {
        if let hit = images[url] { return hit.image }
        guard !failed.contains(url), let decoded = try? await media.avatar(at: url, maxPixelSize: 64) else {
            failed.insert(url)
            return nil
        }
        if images[url] == nil {
            images[url] = decoded
            order.append(url)
            if order.count > Self.capacity { images[order.removeFirst()] = nil }
        }
        return images[url]?.image
    }
}

/// Initials until the photo arrives, at a fixed size so rows never shift.
struct PhotoAvatar: View {
    let name: String
    let url: URL?
    let media: MediaLoader?
    var size: CGFloat = 32
    @State private var loaded: CGImage?

    var body: some View {
        let image = loaded ?? url.flatMap { AvatarImages.shared.cached($0) }
        Avatar(name: name, size: size)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 2).resizable().scaledToFill()
                        .frame(width: size, height: size).clipShape(Circle())
                }
            }
            .task(id: url) {
                guard let url, let media, AvatarImages.shared.cached(url) == nil else { return }
                loaded = await AvatarImages.shared.load(url, media: media)
            }
    }
}
