import SwiftUI
import Combine
import Alamofire
import UIKit

// Third-Party Framework: Alamofire (via Swift Package Manager) is used here
// to download station logo images and cache them for smooth scrolling.
// The package contributes only this remote-image helper path; the core app
// experience remains implemented with SwiftUI, MapKit, AVFoundation, and app code.

@MainActor
/// Downloads and caches remote station logos for list rows and cards.
final class StationLogoLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading: Bool = false

    private static let cache = NSCache<NSString, UIImage>()
    private var request: DataRequest?
    private var activeURLString: String?

    /// Loads a station logo image from a URL string and caches the result.
    /// Starts or restarts an image request for the provided URL string.
    func load(from urlString: String?) {
        activeURLString = urlString
        request?.cancel()
        request = nil
        image = nil
        isLoading = false

        guard let urlString, let url = URL(string: urlString) else {
            AppLog.info("StationLogoLoader.load: invalid URL \(urlString ?? "<nil>")")
            return
        }

        if let cached = Self.cache.object(forKey: urlString as NSString) {
            AppLog.info("StationLogoLoader.load: cache hit \(urlString)")
            image = cached
            return
        }

        isLoading = true
        AppLog.netOp("GET", url)
        AppLog.url("Download station logo", url)
        let requestURL = url

        request = AF.request(url)
            .validate(statusCode: 200..<300)
            .responseData(queue: .global(qos: .userInitiated)) { [weak self] response in
                guard let self else { return }
                Task { @MainActor in
                    guard self.activeURLString == urlString else { return }
                    self.isLoading = false

                    switch response.result {
                    case .success(let data):
                        let status = response.response?.statusCode ?? -1
                        AppLog.info("StationLogoLoader: success status \(status) bytes \(data.count) url \(urlString)")
                        AppLog.dumpData("station logo", url: requestURL, data: data, maxChars: 256, maxBytes: 64)
                        guard let uiImage = UIImage(data: data) else {
                            self.image = nil
                            return
                        }
                        Self.cache.setObject(uiImage, forKey: urlString as NSString)
                        self.image = uiImage

                    case .failure(let error):
                        let status = response.response?.statusCode ?? -1
                        AppLog.info("StationLogoLoader: failure status \(status) url \(urlString) error \(error)")
                        self.image = nil
                    }
                }
            }
    }

    deinit {
        request?.cancel()
    }
}

/// SwiftUI view that renders a station logo from a URL with a fallback placeholder.
/// Small SwiftUI wrapper around `StationLogoLoader` that shows a spinner while loading.
struct AlamofireStationLogoView: View {
    let logoURLString: String?

    @StateObject private var loader = StationLogoLoader()

    var body: some View {
        Group {
            if let uiImage = loader.image {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else if loader.isLoading {
                ProgressView()
                    .scaleEffect(0.75)
            } else {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            loader.load(from: logoURLString)
        }
        .onChange(of: logoURLString) { _, newValue in
            loader.load(from: newValue)
        }
    }
}
