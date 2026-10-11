#if DEBUG
import Foundation
import GymWatchLink
import Observation
import SwiftUI

/// DEBUG/UI-test only (`-fakeWatch`): an in-process "Apple Watch". Pushed states go (as WatchConnectivity payloads)
/// into the watch's real `WatchWorkoutModel`, and its commands come back the same way, so a UI test can tap the
/// watch's Log set without a watch or a watch simulator.
@MainActor
@Observable
final class FakeWatchTransport: PhoneWatchTransport, WatchCommandSending {
    static let shared = FakeWatchTransport()
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("-fakeWatch")

    @ObservationIgnored var onCommand: ((WatchCommand) -> Void)?
    @ObservationIgnored var onReady: (() -> Void)?
    /// The watch's view model, fed by this transport.
    @ObservationIgnored private(set) lazy var model = WatchWorkoutModel(sender: self)
    private(set) var pushes = 0
    private(set) var launches = 0
    /// Bumps with every state the watch received (the probe re-renders).
    private(set) var revision = 0

    let isReachable = true

    func activate() { onReady?() }

    func push(_ state: WatchState) {
        guard let payload = try? WatchEnvelope.encode(state), case .state(let received)? = try? WatchEnvelope.decode(payload)
        else { return }
        pushes += 1
        model.receive(received)
        revision += 1
    }

    func launchWatchWorkout() { launches += 1 }

    func send(_ command: WatchCommand, reachableOnly: Bool) -> Bool {
        guard let payload = try? WatchEnvelope.encode(command),
              case .command(let received)? = try? WatchEnvelope.decode(payload) else { return false }
        // Delivered asynchronously, like WatchConnectivity.
        Task { @MainActor in self.onCommand?(received) }
        return true
    }

    /// "Warm-up 1/2 · 45 lb × 10 · 45×10 · rest · launches 1", or "idle · Push".
    var summary: String {
        _ = revision
        guard let workout = model.workout else {
            return ["idle", model.state?.today?.title ?? "", "launches \(launches)"].filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        let next = model.next.map { [$0.setLabel, $0.setDetail] } ?? [workout.status]
        let crown = model.weight.map { w in "\(WatchFormat.weight(w))×\(model.reps ?? 0)" } ?? ""
        return (next + [crown, workout.rest == nil ? "no rest" : "rest", "launches \(launches)"])
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The fake watch's face and buttons (`watch.fake.*`), only under `-fakeWatch`.
struct FakeWatchProbe: View {
    private let watch = FakeWatchTransport.shared

    var body: some View {
        VStack(spacing: 2) {
            Text(watch.summary)
                .font(.caption2)
                .accessibilityIdentifier("watch.fake.probe")
            HStack(spacing: 4) {
                button("crown+", id: "watch.fake.crownUp") { watch.model.stepWeight(by: 1) }
                button("reps−", id: "watch.fake.repsDown") { watch.model.stepReps(by: -1) }
                button("log", id: "watch.fake.logSet") { watch.model.logSet() }
                button("start", id: "watch.fake.startToday") { watch.model.startToday() }
            }
        }
        .foregroundStyle(.white)
        .background(.black)
    }

    private func button(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.caption2)
            .buttonStyle(.bordered)
            .accessibilityIdentifier(id)
    }
}
#endif
