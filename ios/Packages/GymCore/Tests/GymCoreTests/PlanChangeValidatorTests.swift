import Foundation
import Testing
@testable import GymCore

private struct Fixture: Decodable {
    struct Case: Decodable {
        struct V: Decodable, Hashable { let changeId: String?; let field: String }
        let name: String
        let proposal: PlanProposal
        let violations: [V]
    }
    /// The owner's date the fixture's `today` changes are checked against.
    let today: String
    let library: [String]
    let plan: PlanSnapshot
    let cases: [Case]
}

@Suite struct PlanChangeValidatorTests {
    fileprivate static let fixture: Fixture = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // GymCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // GymCore
            .deletingLastPathComponent() // Packages
            .deletingLastPathComponent() // ios
            .deletingLastPathComponent() // app
            .appendingPathComponent("fixtures/plan-changes.json")
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    @Test(arguments: PlanChangeValidatorTests.fixture.cases.map(\.name))
    func sharedFixture(caseName: String) throws {
        let fx = Self.fixture
        let testCase = try #require(fx.cases.first { $0.name == caseName })
        let library = Set(fx.library)
        let validator = PlanChangeValidator(plan: fx.plan, exerciseExists: { library.contains($0) }, today: fx.today)
        let got = Set(validator.validate(testCase.proposal).map { Fixture.Case.V(changeId: $0.changeId, field: $0.field) })
        #expect(got == Set(testCase.violations))
    }

    @Test func tooManyChanges() {
        let changes = (0..<26).map { PlanChange(id: "c\($0)", type: .sets, routineId: "push", exerciseId: "bench", sets: 3) }
        let validator = PlanChangeValidator(plan: Self.fixture.plan, exerciseExists: { _ in true })
        let got = validator.validate(PlanProposal(summary: "Many", changes: changes))
        #expect(got.contains { $0.field == "changes" })
    }

    @Test func routineLimit() {
        let adds = (0..<5).map { PlanChange(id: "a\($0)", type: .addRoutine, routineId: "r\($0)", name: "R\($0)") }
        let validator = PlanChangeValidator(plan: Self.fixture.plan, exerciseExists: { _ in true })
        let got = validator.validate(PlanProposal(summary: "Lots", changes: adds))
        #expect(got.contains { $0.changeId == "a4" && $0.field == "routineId" })
    }

    @Test func changeTypeJSONNames() throws {
        let data = try JSONEncoder().encode(PlanChangeType.swapExercise)
        #expect(String(decoding: data, as: UTF8.self) == "\"swap-exercise\"")
    }
}
