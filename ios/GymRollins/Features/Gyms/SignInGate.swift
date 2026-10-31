import Observation
import SwiftUI

/// Why the sign-in sheet is open. The words must be true for each: syncing goes to the user's own account only,
/// sharing and confirming are seen by the gym, and a report goes to the people who check them.
enum SignInPurpose: Equatable {
    case share, confirm, sync, report

    var title: String {
        switch self {
        case .sync: "Sign in to sync"
        case .report: "Sign in to report"
        case .share, .confirm: "Sign in to share"
        }
    }

    var body: String { "\(lead) \(Self.backup)" }

    private var lead: String {
        switch self {
        case .share: "Share this gym's equipment with other people."
        case .confirm: "Confirm that this equipment is at the gym, for everyone who trains there."
        case .report: "Report this so it can be checked."
        case .sync: "Sync this to your account so it is there on your other devices. Only you can see it."
        }
    }

    /// Signing in adopts the phone's data and runs a full sync, as it does from Settings; the sheet says so.
    private static let backup = "Signing in also backs up your workouts, routines, weigh-ins and profile to your account. "
        + "Gyms and equipment marked This phone only stay on this phone."
}

/// The sign-in sheet and the one action waiting behind it. The action belongs to the sheet that is open: closing the
/// sheet any way takes it back, so a sign-in call that finishes after an explicit Cancel runs nothing.
@MainActor
@Observable
final class SignInGate {
    var isPresented = false
    private(set) var purpose = SignInPurpose.share
    @ObservationIgnored private var pending: (() -> Void)?

    func ask(_ purpose: SignInPurpose, then work: @escaping () -> Void) {
        self.purpose = purpose
        pending = work
        isPresented = true
    }

    /// The user signed in: the waiting action runs, once.
    func signedIn() {
        let work = pending
        pending = nil
        isPresented = false
        work?()
    }

    /// The sheet was closed without waiting for a sign-in.
    func cancelled() { pending = nil }
}

extension View {
    /// Presents the sign-in sheet for a gate. Closing the sheet any way other than a finished sign-in runs nothing.
    func signInForSharing(gate: SignInGate) -> some View {
        sheet(isPresented: Binding(get: { gate.isPresented }, set: { gate.isPresented = $0 }),
              onDismiss: { gate.cancelled() }) {
            SignInForSharingSheet(purpose: gate.purpose) { gate.signedIn() }
        }
    }
}
