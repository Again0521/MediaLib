import Foundation
import MediaLibCore

#if canImport(VideoToolbox)
import VideoToolbox
#endif

struct ServerRuntimeDiagnosticsSnapshot: Codable, Equatable, Sendable {
    let serviceVersion: String
    let startedAt: Date
    let uptimeSeconds: Int64
    let databaseAccessible: Bool
    let databaseByteLength: Int64
    let availableDiskByteLength: Int64?
    let ffmpegAvailable: Bool
    let ffprobeAvailable: Bool
    let videoToolboxH264Available: Bool
    let videoToolboxHEVCAvailable: Bool
    let listenerMode: String
    let configuredPort: Int
    let publicOrigin: String?
    let trustedProxyAddresses: [String]
    let hostControlAvailable: Bool
}

/// 只采集管理总览需要的非敏感运行时事实。
/// 快照不含磁盘路径、监听地址、代理地址、工具位置或完整进程命令。
final class ServerRuntimeDiagnostics: @unchecked Sendable {
    private let databaseURL: URL
    private let volumeURL: URL
    private let listenerMode: String
    private let configuredPort: Int
    private let publicOrigin: String?
    private let trustedProxyAddresses: [String]
    private let hostControlAvailable: @Sendable () -> Bool
    private let startedAt = Date()
    private let serviceVersion: String

    init(
        databaseURL: URL,
        volumeURL: URL,
        listenerMode: ServerNetworkAccessMode,
        configuredPort: Int,
        publicOrigin: String?,
        trustedProxyAddresses: [String],
        hostControlAvailable: @escaping @Sendable () -> Bool = { false }
    ) {
        self.databaseURL = databaseURL
        self.volumeURL = volumeURL
        self.listenerMode = listenerMode.rawValue
        self.configuredPort = configuredPort
        self.publicOrigin = publicOrigin
        self.trustedProxyAddresses = trustedProxyAddresses.sorted()
        self.hostControlAvailable = hostControlAvailable
        serviceVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ProcessInfo.processInfo.environment["MEDIALIB_SERVER_VERSION"]
            ?? "development"
    }

    func snapshot(at date: Date = Date()) -> ServerRuntimeDiagnosticsSnapshot {
        let databaseValues = try? databaseURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let volumeValues = try? volumeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return ServerRuntimeDiagnosticsSnapshot(
            serviceVersion: serviceVersion,
            startedAt: startedAt,
            uptimeSeconds: Int64(max(0, date.timeIntervalSince(startedAt)).rounded(.down)),
            databaseAccessible: databaseValues?.isRegularFile == true,
            databaseByteLength: Int64(max(0, databaseValues?.fileSize ?? 0)),
            availableDiskByteLength: volumeValues?.volumeAvailableCapacityForImportantUsage.map { Int64(max(0, $0)) },
            ffmpegAvailable: ServerMediaToolchain.ffmpegURL() != nil,
            ffprobeAvailable: ServerMediaToolchain.ffprobeURL() != nil,
            videoToolboxH264Available: Self.videoToolboxH264Available,
            videoToolboxHEVCAvailable: Self.videoToolboxHEVCAvailable,
            listenerMode: listenerMode,
            configuredPort: configuredPort,
            publicOrigin: publicOrigin,
            trustedProxyAddresses: trustedProxyAddresses,
            hostControlAvailable: hostControlAvailable()
        )
    }

    #if canImport(VideoToolbox)
    private static let videoToolboxH264Available = VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
    private static let videoToolboxHEVCAvailable = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    #else
    private static let videoToolboxH264Available = false
    private static let videoToolboxHEVCAvailable = false
    #endif
}
