import SwiftUI
import UIKit

/// A workout link on its way to the screen: it waits for onboarding, then the sheet opens over whatever is up. That can be
/// the full-screen workout, which a `.sheet` on the root view can't appear above, so this presents from the top controller.
/// A second link replaces the first. Links are held in memory only: if the app quits first, the person taps it again.
@MainActor
final class IncomingWorkoutCoordinator {
    private var pending: URL?
    private var presenting: Task<Void, Never>?
    private weak var shown: UIViewController?

    func receive(_ url: URL, env: AppEnvironment, showToday: @escaping @MainActor () -> Void) {
        pending = url
        showIfReady(env: env, showToday: showToday)
    }

    func showIfReady(env: AppEnvironment, showToday: @escaping @MainActor () -> Void) {
        guard env.onboardingComplete, let url = pending else { return }
        pending = nil
        presenting?.cancel()
        shown?.dismiss(animated: false)
        presenting = Task { [weak self] in await self?.present(url, env: env, showToday: showToday) }
    }

    /// Waits while the top controller can't present: while it moves, or a system sheet or alert is up.
    private func present(_ url: URL, env: AppEnvironment, showToday: @escaping @MainActor () -> Void) async {
        while !Task.isCancelled {
            if let top = Self.topController() {
                let host = UIHostingController(rootView: sheet(env.incomingWorkoutScreen(url: url), env: env,
                                                               showToday: showToday))
                shown = host
                top.present(host, animated: true)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func sheet(_ screen: IncomingWorkoutScreen, env: AppEnvironment,
                       showToday: @escaping @MainActor () -> Void) -> some View {
        IncomingWorkoutSheet(
            screen: screen,
            close: { [weak self] in self?.shown?.dismiss(animated: true) },
            used: { [weak self] in
                showToday()
                self?.shown?.dismiss(animated: true)
            },
            resume: { [weak self] in
                showToday()
                self?.shown?.dismiss(animated: true) {
                    NotificationCenter.default.post(name: .resumeWorkoutRequested, object: nil)
                }
            })
            .environment(env)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
    }

    private static func topController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var top = window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        guard let top, !top.isBeingPresented, !top.isBeingDismissed, !(top is UIAlertController),
              !(top is UIActivityViewController), !(top is UIImagePickerController) else { return nil }
        return top
    }
}
