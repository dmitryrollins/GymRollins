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
        presenting = Task { [weak self] in await self?.present(url, env: env, showToday: showToday) }
    }

    /// Each pass first clears the sheet an earlier link left up, once UIKit has finished moving it, then presents from the
    /// top controller. It waits while that can't present (it moves, or a system sheet or alert is up) and when UIKit
    /// refuses the presentation.
    private func present(_ url: URL, env: AppEnvironment, showToday: @escaping @MainActor () -> Void) async {
        while !Task.isCancelled {
            if clearOldSheet(), let top = Self.topController() {
                let host = UIHostingController(rootView: AnyView(EmptyView()))
                // Made first so that each button closes this sheet, never whichever one is newest.
                host.rootView = AnyView(sheet(env.incomingWorkoutScreen(url: url), env: env, host: host,
                                              showToday: showToday))
                top.present(host, animated: true)
                if host.presentingViewController != nil {
                    shown = host
                    return
                }
                AppEnvironment.log.error("Presenting the workout link sheet was refused; trying again")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// True when no old sheet is left. An old sheet that is still moving is waited for; one that has settled goes at once.
    private func clearOldSheet() -> Bool {
        guard let old = shown else { return true }
        if old.isBeingPresented || old.isBeingDismissed { return false }
        if old.presentingViewController != nil { old.dismiss(animated: false) }
        shown = nil
        return true
    }

    private func sheet(_ screen: IncomingWorkoutScreen, env: AppEnvironment, host: UIViewController,
                       showToday: @escaping @MainActor () -> Void) -> some View {
        IncomingWorkoutSheet(
            screen: screen,
            close: { [weak host] in host?.dismiss(animated: true) },
            used: { [weak host] in
                showToday()
                host?.dismiss(animated: true)
            },
            resume: { [weak host] in
                showToday()
                host?.dismiss(animated: true) {
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
