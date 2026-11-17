import Foundation
import ServiceManagement

struct HelperInstaller {
    private let serviceName = "com.tailscale-route.helper.plist"

    func register() throws {
        if #available(macOS 13.0, *) {
            try SMAppService.daemon(plistName: serviceName).register()
        } else {
            throw InstallerError.unsupported
        }
    }

    func unregister() throws {
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: serviceName)
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
                try waitUntilUnregistered(service)
            case .notRegistered, .notFound:
                break
            @unknown default:
                break
            }
        } else {
            throw InstallerError.unsupported
        }
    }

    /// `reload()` polls SMAppService for up to ten seconds. Run it off the
    /// main actor so the menu bar UI never freezes while launchd catches up.
    func reloadInBackground() async throws {
        let installer = self
        try await Task.detached(priority: .userInitiated) {
            try installer.reload()
        }.value
    }

    func reload() throws {
        // register() alone is a no-op for an already registered daemon and
        // can leave launchd running the previous executable from the app
        // bundle. Unregister first so the updated Helper is actually loaded.
        // Do not hide an unregister failure: registering over a live old
        // daemon is exactly the stale-process state this reload is meant to
        // prevent.
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: serviceName)
            try unregister()
            try service.register()
            try waitUntilRegistered(service)
        } else {
            throw InstallerError.unsupported
        }
    }

    @available(macOS 13.0, *)
    private func waitUntilUnregistered(_ service: SMAppService) throws {
        for _ in 0..<50 {
            switch service.status {
            case .notRegistered, .notFound:
                return
            default:
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw InstallerError.unregisterTimedOut
    }

    @available(macOS 13.0, *)
    private func waitUntilRegistered(_ service: SMAppService) throws {
        for _ in 0..<50 {
            switch service.status {
            case .enabled, .requiresApproval:
                return
            case .notRegistered, .notFound:
                Thread.sleep(forTimeInterval: 0.1)
            @unknown default:
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw InstallerError.registerTimedOut
    }
}

enum InstallerError: LocalizedError {
    case unsupported
    case unregisterTimedOut
    case registerTimedOut

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "当前 macOS 版本不支持 SMAppService"
        case .unregisterTimedOut:
            return "旧 Helper 注销超时，拒绝复用旧进程"
        case .registerTimedOut:
            return "新 Helper 注册超时，未启动旧版本替代进程"
        }
    }
}
