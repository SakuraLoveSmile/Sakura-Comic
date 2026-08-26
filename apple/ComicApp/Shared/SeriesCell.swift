import SwiftUI
import KomgaStore

/// One cover-wall tile. Shows the cached cover image when available,
/// otherwise a placeholder while it loads.
struct SeriesCell: View {
    let record: SeriesRecord
    let data: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            cover
            Text(record.name)
                .font(.caption)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let image = platformImage(data) {
            image
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    ProgressView()
                }
        }
    }
}

#if canImport(UIKit)
import UIKit
private func platformImage(_ data: Data?) -> Image? {
    guard let data, let ui = UIImage(data: data) else { return nil }
    return Image(uiImage: ui)
}
#else
import AppKit
private func platformImage(_ data: Data?) -> Image? {
    guard let data, let ns = NSImage(data: data) else { return nil }
    return Image(nsImage: ns)
}
#endif

