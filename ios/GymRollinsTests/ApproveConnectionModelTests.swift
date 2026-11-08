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
        /// Added after review: the answers to the first lookups, in order; nil is the request, and later ones follow
        /// the model's `lookUp`.
        var lookUpAnswers: [Error?] = []
    }

    /// Added after review: a call that waits until the test answers it, so a test can act while it is in flight.
    @MainActor private final class Gate<Answer: Sendable> {
        private(set) var codes: [String] = []
        private var waiting: [CheckedContinuation<Answer, Error>?] = []

        func call(_ code: String) async throws -> Answer {
            codes.append(code)
            return try await withCheckedThrowingContinuation { waiting.append($0) }
        }

        /// Waits (a bounded number of turns) until `count` calls are in flight.
        func untilWaiting(_ count: Int) async {
            for _ in 0..<1_000 where waiting.count < count { await Task.yield() }
        }

        func answer(_ index: Int, with result: Result<Answer, Error>) {
            guard waiting.indices.contains(index), let call = waiting[index] else {
                Issue.record("no call \(index) is waiting (\(waiting.count) were made)")
                return
            }
            waiting[index] = nil
            call.resume(with: result)
        }
    }

    private func model(lookUp: Error? = nil, decide: Error? = nil, calls: Calls = Calls()) -> ApproveConnectionModel {
        ApproveConnectionModel(lookUp: { code in
            calls.lookedUp.append(code)
            let answer = calls.lookUpAnswers.isEmpty ? lookUp : calls.lookUpAnswers.removeFirst()
            if let answer { throw answer }
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
        calls.lookUpAnswers = [ConnectCodeError.unknownCode]
        let model = model(calls: calls)
        model.type("ZZZZZZZZ")
        await model.lookUp()
        #expect(model.phase == .typing && model.error?.hasPrefix("No sign-in is waiting with this code") == true)
        await model.lookUp()
        #expect(calls.lookedUp.count == 1) // the same code isn't sent again
        model.type("ZZZZZZZY")
        #expect(model.error == nil)
        await model.lookUp() // added after review: the changed code is looked up
        #expect(calls.lookedUp == ["ZZZZZZZZ", "ZZZZZZZY"] && model.request == Self.request)
    }

    /// Added after review: only an unknown code is refused for good. After any other failure the sheet says "try
    /// again", and retyping the same code sends it again.
    @Test(arguments: [URLError(.notConnectedToInternet), ApiError(status: 503, code: "http_503", message: ""),
                      ApiError(status: 401, code: "signed_out", message: ""), ConnectCodeError.tooManyAttempts] as [any Error])
    func aFailureThatIsntAboutTheCodeLetsItBeSentAgain(_ failure: any Error) async {
        let calls = Calls()
        calls.lookUpAnswers = [failure]
        let model = model(calls: calls)
        model.type("ABCDEFGH")
        await model.lookUp()
        #expect(model.phase == .typing && model.error == ApproveConnectionModel.message(for: failure))
        model.type("ABCDEFG")
        model.type("ABCDEFGH")
        await model.lookUp()
        #expect(calls.lookedUp == ["ABCDEFGH", "ABCDEFGH"])
        #expect(model.phase == .found(Self.request) && model.error == nil)
    }

    /// Added after review: deleting and retyping a character cancels the lookup in flight (the view's task follows
    /// the complete code). That cancellation is no answer: no error, no refusal, and the retyped code is sent.
    @Test func aLookUpCancelledByARetypeIsNoRefusal() async {
        let gate = Gate<ConnectRequest>()
        let model = ApproveConnectionModel(lookUp: { try await gate.call($0) }, decide: { _, _ in })
        model.type("ABCDEFGH")
        let first = Task { await model.lookUp() }
        await gate.untilWaiting(1)
        model.type("ABCDEFG")
        first.cancel()
        model.type("ABCDEFGH")
        gate.answer(0, with: .failure(URLError(.cancelled)))
        await first.value
        #expect(model.phase == .typing && model.error == nil)

        let second = Task { await model.lookUp() }
        await gate.untilWaiting(2)
        gate.answer(1, with: .success(Self.request))
        await second.value
        #expect(gate.codes == ["ABCDEFGH", "ABCDEFGH"])
        #expect(model.phase == .found(Self.request) && model.error == nil)
    }

    /// Added after review: the same, when the cancelled lookup's answer comes after the new one was sent.
    @Test func aLateCancelledLookUpLeavesTheNewOneAlone() async {
        let gate = Gate<ConnectRequest>()
        let model = ApproveConnectionModel(lookUp: { try await gate.call($0) }, decide: { _, _ in })
        model.type("ABCDEFGH")
        let first = Task { await model.lookUp() }
        await gate.untilWaiting(1)
        model.type("ABCDEFG")
        first.cancel()
        model.type("ABCDEFGH")
        let second = Task { await model.lookUp() }
        await gate.untilWaiting(2)
        gate.answer(0, with: .failure(URLError(.cancelled)))
        await first.value
        #expect(model.phase == .lookingUp && model.error == nil)
        gate.answer(1, with: .success(Self.request))
        await second.value
        #expect(model.phase == .found(Self.request) && model.error == nil)
    }

    /// Added after review: text with a character outside the code's alphabet is no code. It stays as typed, says so,
    /// and is never sent (dropping the character used to send another code and use a try).
    @Test func textThatIsNoCodeIsNeverSent() async {
        let calls = Calls()
        let model = model(calls: calls)
        model.type("Code: ABCD-EFGH")
        #expect(model.typed == "Code: ABCD-EFGH" && model.complete == nil && model.isInvalid)
        await model.lookUp()
        model.type("ABCDEFGß")
        await model.lookUp()
        #expect(calls.lookedUp.isEmpty && model.isInvalid)
        model.type("ABCD-EFG")
        #expect(!model.isInvalid)
        model.type("ABCD-EFGH")
        await model.lookUp()
        #expect(calls.lookedUp == ["ABCDEFGH"])
    }

    @Test func refusalsReadAsTheOwnerNeedsThem() {
        #expect(ApproveConnectionModel.message(for: ConnectCodeError.tooManyAttempts)
            == "Too many wrong codes. Try again in 10 minutes.")
        #expect(ApproveConnectionModel.message(for: SyncUnavailableError()) == ApproveConnectionModel.signInFirst)
        #expect(ApproveConnectionModel.message(for: ApiError(status: 401, code: "signed_out", message: ""))
            == ApproveConnectionModel.signInFirst)
        #expect(ApproveConnectionModel.message(for: URLError(.notConnectedToInternet)).hasPrefix("Couldn't reach"))
    }

    @Test func approveAndDenyDecideTheRequestsCode() async {
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
        #expect(model.phase == .found(Self.request) && model.canEditCode)
    }

    /// Added after review: a code that died while the sheet was open (expired, decided elsewhere) or used-up tries
    /// take Approve away, so tapping it again can't use more tries; the same code isn't sent again.
    @Test(arguments: [ConnectCodeError.unknownCode, .tooManyAttempts])
    func aDecisionOnADeadCodeGoesBackToTheField(_ failure: ConnectCodeError) async {
        let calls = Calls()
        let model = model(decide: failure, calls: calls)
        model.type("ABCDEFGH")
        await model.lookUp()
        await model.decide(.approve)
        #expect(model.phase == .typing && model.request == nil && model.canEditCode)
        #expect(model.error == ApproveConnectionModel.message(for: failure))
        await model.lookUp()
        #expect(calls.lookedUp.count == 1 && calls.decided.count == 1)
    }

    /// Added after review: the field takes no typing while a decision is on its way, and the decision is for the
    /// request on screen.
    @Test func whileDecidingTheCodeCantChange() async {
        let gate = Gate<Void>()
        let model = ApproveConnectionModel(lookUp: { _ in Self.request }, decide: { code, _ in
            try await gate.call(code)
        })
        model.type("ABCDEFGH")
        await model.lookUp()
        #expect(model.canEditCode)
        let deciding = Task { await model.decide(.approve) }
        await gate.untilWaiting(1)
        #expect(model.phase == .deciding(Self.request) && !model.canEditCode)
        model.type("ZZZZZZZZ")
        #expect(model.typed == "ABCD-EFGH" && model.phase == .deciding(Self.request))
        gate.answer(0, with: .success(()))
        await deciding.value
        #expect(model.phase == .approved && gate.codes == ["ABCDEFGH"] && !model.canEditCode)
    }

    /// Added after review: the decision sends the code of the request shown, not whatever the field holds.
    @Test func theDecisionIsForTheRequestShown() async {
        let calls = Calls()
        let model = model(calls: calls) // answers ABCD-EFGH whatever is looked up
        model.type("ZZZZZZZZ")
        await model.lookUp()
        await model.decide(.deny)
        #expect(calls.decided.map(\.0) == ["ABCDEFGH"])
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
