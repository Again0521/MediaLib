import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum MemoryAudioResourceLoadingPolicy {
    static func contentType(preferred: String, allowedTypes: [String]?) -> String {
        guard let allowedTypes, !allowedTypes.isEmpty else {
            return preferred
        }
        if allowedTypes.contains(preferred) {
            return preferred
        }
        return allowedTypes.first ?? preferred
    }

    static func responseRange(
        dataCount: Int,
        requestedOffset: Int64,
        currentOffset: Int64,
        requestedLength: Int,
        requestsAllDataToEndOfResource: Bool
    ) -> Range<Int>? {
        let requestedOffset = max(Int(requestedOffset), 0)
        let currentOffset = max(Int(currentOffset), requestedOffset)
        let offset = min(max(currentOffset, requestedOffset), dataCount)
        let resolvedLength = requestsAllDataToEndOfResource
            ? dataCount - offset
            : requestedLength
        let length = min(max(resolvedLength, 0), max(dataCount - offset, 0))
        guard length > 0 else { return nil }
        return offset..<(offset + length)
    }
}

final class MemoryAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "MediaLIB.memory-audio-resource-loader", qos: .userInitiated)

    private let data: Data
    private let preferredContentType: String

    init(fileURL: URL, data: Data) {
        self.data = data
        preferredContentType = UTType(filenameExtension: fileURL.pathExtension)?.identifier ?? UTType.data.identifier
        super.init()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = MemoryAudioResourceLoadingPolicy.contentType(
                preferred: preferredContentType,
                allowedTypes: info.allowedContentTypes
            )
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }

        if let request = loadingRequest.dataRequest,
           let range = MemoryAudioResourceLoadingPolicy.responseRange(
            dataCount: data.count,
            requestedOffset: request.requestedOffset,
            currentOffset: request.currentOffset,
            requestedLength: request.requestedLength,
            requestsAllDataToEndOfResource: request.requestsAllDataToEndOfResource
           ) {
            request.respond(with: data.subdata(in: range))
        }

        loadingRequest.finishLoading()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {}
}

struct MemoryAudioAsset {
    let asset: AVURLAsset
    let loader: MemoryAudioResourceLoader

    init(fileURL: URL, data: Data) {
        loader = MemoryAudioResourceLoader(fileURL: fileURL, data: data)
        let assetURL = Self.assetURL(for: fileURL)
        asset = AVURLAsset(
            url: assetURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    private static func assetURL(for fileURL: URL) -> URL {
        let ext = fileURL.pathExtension.isEmpty ? "audio" : fileURL.pathExtension
        return URL(string: "medialib-memory-audio://track/\(UUID().uuidString).\(ext)")!
    }
}
