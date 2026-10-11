#if os(iOS) || os(watchOS)
import Foundation
import os
import WatchConnectivity

/// The WatchConnectivity session, for both sides. Phone → watch: `send(state:)` (application context, latest wins, plus
/// an immediate message when reachable). Watch → phone: `send(_:reachableOnly:)` (a message when reachable, with a
/// queued `transferUserInfo` fallback). Payloads are decoded on WatchConnectivity's queue and handed to the main actor
/// as Sendable values.
@MainActor
public final class WatchConnectivityLink: NSObject, WatchCommandSending {
    public var onState: ((WatchState) -> Void)?
    public var onCommand: ((WatchCommand) -> Void)?
    public var onReachabilityChange: ((Bool) -> Void)?
    /// The session finished activating (sends before this are dropped: send the current state again).
    public var onActivated: (() -> Void)?
    public private(set) var isReachable = false
    private let session: WCSession?
    nonisolated static let log = Logger(subsystem: "com.rollins.gymrollins", category: "watch-link")

    override public init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    /// Call once at launch, after setting the callbacks.
    public func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    #if os(iOS)
    /// A paired Apple Watch has the GymRollins app.
    public var watchAppInstalled: Bool {
        guard let session, session.activationState == .activated else { return false }
        return session.isPaired && session.isWatchAppInstalled
    }
    #endif

    /// Phone → watch.
    public func send(state: WatchState) {
        guard let session, session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired, session.isWatchAppInstalled else { return }
        #endif
        do {
            let payload = try WatchEnvelope.encode(state)
            try session.updateApplicationContext(payload)
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil) { error in
                    Self.log.notice("State message failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            Self.log.error("Sending state failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Watch → phone.
    @discardableResult
    public func send(_ command: WatchCommand, reachableOnly: Bool) -> Bool {
        guard let session, session.activationState == .activated,
              let payload = try? WatchEnvelope.encode(command) else { return false }
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { [weak self] error in
                Self.log.notice("Command message failed: \(error.localizedDescription, privacy: .public)")
                guard !reachableOnly else { return }
                Task { @MainActor in self?.queue(command) }
            }
            return true
        }
        guard !reachableOnly else { return false }
        queue(command)
        return true
    }

    private func queue(_ command: WatchCommand) {
        guard let session, let payload = try? WatchEnvelope.encode(command) else { return }
        session.transferUserInfo(payload)
    }

    fileprivate func deliver(_ decoded: WatchEnvelope.Decoded?) {
        switch decoded {
        case .state(let state): onState?(state)
        case .command(let command): onCommand?(command)
        case nil: break
        }
    }

    fileprivate func setReachable(_ reachable: Bool) {
        guard reachable != isReachable else { return }
        isReachable = reachable
        onReachabilityChange?(reachable)
    }

    nonisolated static func decode(_ payload: [String: Any]) -> WatchEnvelope.Decoded? {
        guard !payload.isEmpty else { return nil }
        do {
            return try WatchEnvelope.decode(payload)
        } catch {
            log.error("Ignored a watch payload: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension WatchConnectivityLink: WCSessionDelegate {
    nonisolated public func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                                    error: Error?) {
        if let error { Self.log.error("Activation failed: \(error.localizedDescription, privacy: .public)") }
        let reachable = session.isReachable
        let context = Self.decode(session.receivedApplicationContext)
        Task { @MainActor in
            self.setReachable(reachable)
            self.deliver(context)
            self.onActivated?()
        }
    }

    nonisolated public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.setReachable(reachable) }
    }

    nonisolated public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let decoded = Self.decode(message)
        Task { @MainActor in self.deliver(decoded) }
    }

    nonisolated public func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        let decoded = Self.decode(context)
        Task { @MainActor in self.deliver(decoded) }
    }

    nonisolated public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let decoded = Self.decode(userInfo)
        Task { @MainActor in self.deliver(decoded) }
    }

    #if os(iOS)
    nonisolated public func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched watches: activate again for the new one.
    nonisolated public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated public func sessionWatchStateDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.setReachable(reachable) }
    }
    #endif
}
#endif
