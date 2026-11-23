import ChatNet
import ChatSync
import SwiftUI

/// Decoded 64 px profile photos shared by every row; the oldest go first past `capacity`. Downloads go through
/// `AvatarLoads`, which shares them between rows and retries brief failures.
@MainActor
final class AvatarImages {
    static let shared = AvatarImages()
    static let capacity = 200

    private var images: [URL: DecodedImage] = [:]
    private var order: [URL] = []

    func cached(_ url: URL) -> DecodedImage? { images[url] }

    func load(_ url: URL, media: MediaLoader) async -> DecodedImage? {
        if let hit = images[url] { return hit }
        let fetched = await AvatarLoads.shared.load(url) { () async throws(MediaLoadError) -> DecodedImage in
            try await media.avatar(at: url, maxPixelSize: 64)
        }
        guard let fetched else { return nil }
        if images[url] == nil {
            images[url] = fetched
            order.append(url)
            if order.count > Self.capacity { images[order.removeFirst()] = nil }
        }
        return images[url]
    }
}

/// Initials until the photo arrives, at a fixed size so rows never shift.
struct PhotoAvatar: View {
    let name: String
    let url: URL?
    let media: MediaLoader?
    var size: CGFloat = 32
    /// Keeps the image and its memory reservation alive while shown, even after the shared cache drops it.
    @State private var loaded: (url: URL, image: DecodedImage)?

    var body: some View {
        let current =
            loaded.flatMap { $0.url == url ? $0.image : nil } ?? url.flatMap { AvatarImages.shared.cached($0) }
        Avatar(name: name, size: size)
            .overlay {
                if let image = current?.image {
                    Image(decorative: image, scale: 2).resizable().scaledToFill()
                        .frame(width: size, height: size).clipShape(Circle())
                }
            }
            .task(id: url) {
                guard let url else { return }
                if let hit = AvatarImages.shared.cached(url) {
                    loaded = (url, hit)
                    return
                }
                guard let media, let decoded = await AvatarImages.shared.load(url, media: media), !Task.isCancelled
                else { return }
                loaded = (url, decoded)
            }
    }
}
