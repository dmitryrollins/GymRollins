import GymCore
import GymData
import SwiftUI

/// Why something is being reported, and an optional note. Sending queues the report and hides the listing; the sheet
/// then thanks the user. Signed out, Send asks for a sign-in first and sends only after one.
struct ReportContentSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let subject: ReportContentModel.Subject
    /// Queues the report. Throws a `GymDataError.invalidInput` whose message the sheet shows.
    let send: (ReportReason, String?) throws -> Void
    @State private var reason: ReportReason?
    @State private var note = ""
    @State private var errorText: String?
    @State private var sent = false
    @State private var signIn = SignInGate()

    private var noteProblem: String? {
        ReportContentModel.hasRefusedCharacters(note) ? ReportContentModel.noteProblem : nil
    }

    private var canSend: Bool { noteProblem == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if sent { thanks } else { form }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.gutter).padding(.top, 16).padding(.bottom, 24)
            }
            .background(Theme.background)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(sent ? "Done" : "Cancel") { dismiss() }.accessibilityIdentifier("report.cancel")
                }
            }
            .signInForSharing(gate: signIn)
        }
        .presentationDetents([.large])
    }

    private var thanks: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ReportContentModel.thanks).font(.headline).foregroundStyle(Theme.textPrimary)
                .accessibilityIdentifier("report.thanks")
            PrimaryGlassButton(title: "Done", identifier: "report.done") { dismiss() }
        }
    }

    @ViewBuilder
    private var form: some View {
        SectionLabel(text: "What's wrong?")
        VStack(spacing: 8) {
            ForEach(ReportContentModel.reasons(for: subject), id: \.self) { option in row(option) }
        }
        SectionLabel(text: "Note (optional)")
        TextField("Add a note", text: $note, axis: .vertical)
            .lineLimit(2...5)
            .padding(12).frame(minHeight: Theme.minTapSize)
            .background(Theme.cardInner, in: .rect(cornerRadius: 12))
            .onChange(of: reason) { errorText = nil }
            .onChange(of: note) { _, text in
                if text.count > DomainLimits.reportNoteMax { note = String(text.prefix(DomainLimits.reportNoteMax)) }
            }
            .accessibilityIdentifier("report.note")
        if let problem = noteProblem ?? errorText {
            Text(problem).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("report.error")
        }
        PrimaryGlassButton(title: "Send report", identifier: "report.send", action: submit).disabled(!canSend)
    }

    private func row(_ option: ReportReason) -> some View {
        Button { reason = option } label: {
            HStack {
                Text(ReportContentModel.title(option)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if reason == option { Image(systemName: "checkmark").foregroundStyle(Theme.textPrimary) }
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: Theme.minTapSize, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(reason == option ? .isSelected : [])
        .accessibilityIdentifier("report.reason.\(option.rawValue)")
    }

    private func submit() {
        guard let reason else {
            errorText = "Pick what's wrong first."
            return
        }
        let text = ReportContentModel.cleanNote(note)
        let work = {
            do {
                try send(reason, text)
                errorText = nil
                sent = true
            } catch GymDataError.invalidInput(let message) {
                errorText = message
            } catch {
                AppEnvironment.log.error("Report failed: \(error.localizedDescription, privacy: .public)")
                errorText = "Couldn't send the report. Try again."
            }
        }
        guard env.sharingUserId != nil else {
            signIn.ask(.report, then: work)
            return
        }
        work()
    }
}
