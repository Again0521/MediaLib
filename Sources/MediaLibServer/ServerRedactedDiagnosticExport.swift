import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 可下载诊断只包含运行能力、计数与稳定结果码。
/// 用户名、主体 ID、路径、URL、代理地址、令牌与进程命令均不进入此 DTO。
struct ServerRedactedDiagnosticExport: Codable, Equatable, Sendable {
    struct Runtime: Codable, Equatable, Sendable {
        let serviceVersion: String
        let uptimeSeconds: Int64
        let databaseAccessible: Bool
        let databaseByteLength: Int64
        let availableDiskByteLength: Int64?
        let ffmpegAvailable: Bool
        let ffprobeAvailable: Bool
        let videoToolboxH264Available: Bool
        let videoToolboxHEVCAvailable: Bool
        let listenerMode: String
        let hostControlAvailable: Bool
    }

    struct Job: Codable, Equatable, Sendable {
        let kind: String
        let state: String
        let progress: Double
        let resultCode: String?
    }

    struct SecurityEvent: Codable, Equatable, Sendable {
        let category: String
        let action: String
        let outcome: String
        let detailCode: String?
    }

    let formatVersion: Int
    let generatedAt: Date
    let databaseSchemaVersion: Int
    let runtime: Runtime
    let userCount: Int
    let activeDeviceCount: Int
    let activeSessionCount: Int
    let managedSourceCount: Int
    let recentJobs: [Job]
    let recentSecurityEvents: [SecurityEvent]

    init(
        runtime snapshot: ServerRuntimeDiagnosticsSnapshot,
        userCount: Int,
        activeDeviceCount: Int,
        activeSessionCount: Int,
        managedSourceCount: Int,
        jobs: [ServerJob],
        securityEvents: [ServerSecurityEventSummary],
        generatedAt: Date = Date()
    ) {
        formatVersion = 1
        self.generatedAt = generatedAt
        databaseSchemaVersion = DatabaseManager.currentSchemaVersion
        runtime = Runtime(
            serviceVersion: snapshot.serviceVersion,
            uptimeSeconds: snapshot.uptimeSeconds,
            databaseAccessible: snapshot.databaseAccessible,
            databaseByteLength: snapshot.databaseByteLength,
            availableDiskByteLength: snapshot.availableDiskByteLength,
            ffmpegAvailable: snapshot.ffmpegAvailable,
            ffprobeAvailable: snapshot.ffprobeAvailable,
            videoToolboxH264Available: snapshot.videoToolboxH264Available,
            videoToolboxHEVCAvailable: snapshot.videoToolboxHEVCAvailable,
            listenerMode: snapshot.listenerMode,
            hostControlAvailable: snapshot.hostControlAvailable
        )
        self.userCount = max(0, userCount)
        self.activeDeviceCount = max(0, activeDeviceCount)
        self.activeSessionCount = max(0, activeSessionCount)
        self.managedSourceCount = max(0, managedSourceCount)
        recentJobs = jobs.prefix(25).map {
            Job(kind: $0.kind, state: $0.state.rawValue, progress: $0.progress, resultCode: $0.resultCode)
        }
        recentSecurityEvents = securityEvents.prefix(25).map {
            SecurityEvent(
                category: $0.category,
                action: $0.action,
                outcome: $0.outcome,
                detailCode: $0.detailCode
            )
        }
    }
}
