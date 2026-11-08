import Foundation
import GymSync
import Testing
@testable import GymRollins

/// Approve a connection's behaviour without a server: what the field shows, when the code is looked up, and what a
/// refusal or a decision leaves on screen.
@MainActor
@Suite struct ApproveConnectionModelTests {
    private static let opened = Date(timeIntervalSince1970: 1_799_999_400)
    private static let request = ConnectRequest(code: "ABCD-EFGH", clientName: "Claude Code",
                                                redirectHost: "127.0.0.1:53682", knownHost: false,
                                                expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                openedAt: opened)

    private final class Calls {
        var lookedUp: [String] = []
        var decided: [(String, ConnectDecision)] = []
    }

    private func model(lookUp: Error? = nil, decide: Error? = nil, calls: Calls = Calls()) -> ApproveConnectionModel {
        ApproveConnectionModel(lookUp: { code in
            calls.lookedUp.append(code)
            if let lookUp { throw lookUp }
            return Self.request
        }, decide: { code, decision in
            calls.decided.append((code, decision))
            if let decide { throw decide }
        })
    }

    @Test func theFieldShowsTheCodeWithItsDashAndLooksItUpOnceComplete() async {
        let calls = Calls()
        let model = model(calls: calls)
        model.type("abcd")
        #expect(model.typed == "ABCD" && model.complete == nil)
        await model.lookUp()
        #expect(calls.lookedUp.isEmpty)
        model.type("abcd-efgh")
        await model.lookUp()
        #expect(model.typed == "ABCD-EFGH")
        #expect(calls.lookedUp == ["ABCDEFGH"] && model.request == Self.request)
    }

    @Test func aWrongCodeSaysWhyAndAChangedCodeTriesAgain() async {
        let calls = Calls()
        let model = model(lookUp: ConnectCodeError.unknownCode, calls: calls)
        model.type("ZZZZZZZZ")
        await model.lookUp()
        #expect(model.phase == .typing && model.error?.hasPrefix("No sign-in is waiting with this code") == true)
        await model.lookUp()
        #expect(calls.lookedUp.count == 1) // the same code isn't sent again
        model.type("ZZZZZZZY")
        #expect(model.error == nil)
    }

    @Test func refusalsReadAsTheOwnerNeedsThem() {
        #expect(ApproveConnectionModel.message(for: ConnectCodeError.tooManyAttempts)
            == "Too many wrong codes. Try again in 10 minutes.")
        #expect(ApproveConnectionModel.message(for: SyncUnavailableError()) == ApproveConnectionModel.signInFirst)
        #expect(ApproveConnectionModel.message(for: ApiError(status: 401, code: "signed_out", message: ""))
            == ApproveConnectionModel.signInFirst)
        #expect(ApproveConnectionModel.message(for: URLError(.notConnectedToInternet)).hasPrefix("Couldn't reach"))
    }

    @Test func approveAndDenyDecideTheTypedCode() async {
        let calls = Calls()
        let approving = model(calls: calls)
        approving.type("ABCDEFGH")
        await approving.lookUp()
        await approving.decide(.approve)
        #expect(approving.phase == .approved && approving.isDone)
        approving.type("ZZZZ")
        #expect(approving.typed == "ABCD-EFGH") // the field is done

        let denying = model(calls: calls)
        denying.type("ABCDEFGH")
        await denying.lookUp()
        await denying.decide(.deny)
        #expect(denying.phase == .denied)
        #expect(calls.decided.map(\.1) == [.approve, .deny] && calls.decided.allSatisfy { $0.0 == "ABCDEFGH" })
    }

    @Test func aFailedDecisionKeepsTheRequestToTryAgain() async {
        let model = model(decide: URLError(.timedOut))
        model.type("ABCDEFGH")
        await model.lookUp()
        await model.decide(.approve)
        #expect(model.request == Self.request && model.error?.hasPrefix("Couldn't reach") == true)
    }

    // Added after the server's whole-flow review: when and where the code's page was opened, in one line.
    @Test func theOpenedLineSaysWhenWhereAndWhichBrowserLeavingOutWhatIsUnknown() {
        let safari = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like "
            + "Gecko) Version/26.1 Mobile/15E148 Safari/604.1"
        let full = ConnectRequest(code: "ABCD-EFGH", clientName: "Claude", redirectHost: "claude.ai", knownHost: true,
                                  expiresAt: Self.opened + 600, openedAt: Self.opened, country: "CA",
                                  city: "Toronto", userAgent: safari)
        #expect(ApproveConnectionModel.openedLine(for: full, now: Self.opened + 150)
            == "Opened 2 min ago \u{00B7} Toronto, CA \u{00B7} Safari")
        let countryOnly = ConnectRequest(code: "ABCD-EFGH", clientName: nil, redirectHost: "claude.ai",
                                         knownHost: true, expiresAt: Self.opened + 600, openedAt: Self.opened,
                                         country: "CA")
        #expect(ApproveConnectionModel.openedLine(for: countryOnly, now: Self.opened + 60)
            == "Opened 1 min ago \u{00B7} CA")
        #expect(ApproveConnectionModel.openedLine(for: Self.request, now: Self.opened + 20) == "Opened just now")
        #expect(ApproveConnectionModel.openedLine(for: Self.request, now: Self.opened - 30) == "Opened just now")
    }

    @Test func theBrowserIsNamedFromItsUserAgent() {
        let chrome = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) "
            + "Chrome/131.0.0.0 Safari/537.36"
        #expect(ApproveConnectionModel.browserName(chrome) == "Chrome")
        #expect(ApproveConnectionModel.browserName(chrome + " Edg/131.0.0.0") == "Edge")
        #expect(ApproveConnectionModel.browserName("Mozilla/5.0 (iPhone) Mobile/15E148 FxiOS/133.0 Safari/605.1.15")
            == "Firefox")
        #expect(ApproveConnectionModel.browserName("Mozilla/5.0 (iPhone) CriOS/131.0 Mobile Safari/604.1")
            == "Chrome")
        #expect(ApproveConnectionModel.browserName("curl/8.7.1") == "curl")
        #expect(ApproveConnectionModel.browserName("node") == "node")
        #expect(ApproveConnectionModel.caution
            == "Approve only a code that's on your own screen, from a connection you started just now.")
    }
}
