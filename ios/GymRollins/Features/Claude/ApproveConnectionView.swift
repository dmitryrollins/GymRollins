import GymSync
import SwiftUI

/// Settings › Claude › Approve a connection (spec section 5). Claude's sign-in page in the browser shows a code; the
/// owner types it here, sees which app asks and where an approval sends the browser (with a warning when that isn't
/// Claude's), when and where the page was opened, and a caution (added after the server's whole-flow review), then
/// approves or denies. Approve and Deny each sit on their own row: a Form row fires every button it holds.
struct ApproveConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ApproveConnectionModel
    @FocusState private var codeFocused: Bool

    init(model: ApproveConnectionModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Form {
            codeSection
            if let request = model.request { askingSection(request) }
            if model.request != nil { decisionSection }
            if let result = resultText {
                Section { Text(result).accessibilityIdentifier("connect.result") }
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("connect.error") }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Approve a connection")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }.accessibilityIdentifier("connect.done")
            }
        }
        .task(id: model.complete) { await model.lookUp() }
        .onAppear { codeFocused = true }
    }

    private var codeSection: some View {
        Section {
            TextField("XXXX-XXXX", text: Binding(get: { model.typed }, set: { model.type($0) }))
                .font(.title2.monospaced())
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .focused($codeFocused)
                .disabled(model.isDone)
                .accessibilityLabel("Code")
                .accessibilityIdentifier("connect.code")
            if model.phase == .lookingUp {
                HStack { ProgressView(); Text("Checking the code\u{2026}").foregroundStyle(Theme.textSecondary) }
            }
        } footer: {
            Text("Claude's sign-in page in your browser shows this code. It lasts 10 minutes.")
        }
    }

    private func askingSection(_ request: ConnectRequest) -> some View {
        Section("Asking for access") {
            row("App", request.clientName ?? "An app with no name", id: "connect.client")
            row("Returns to", request.redirectHost, id: "connect.host")
            // Added after review: when and where the page was opened, kept current while the sheet is open.
            TimelineView(.everyMinute) { context in
                Text(ApproveConnectionModel.openedLine(for: request, now: context.date))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("connect.opened")
            }
            if !request.knownHost {
                Text("This isn't Claude's address. Approve only if you started this connection yourself, for example "
                     + "in Claude Code on your computer.")
                    .font(.footnote).foregroundStyle(Theme.destructive)
                    .accessibilityIdentifier("connect.warning")
            }
            Text(ApproveConnectionModel.caution)
                .font(.footnote)
                .accessibilityIdentifier("connect.caution")
        }
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(Theme.textSecondary).accessibilityIdentifier(id)
        }
    }

    private var decisionSection: some View {
        Section {
            Button("Approve") { Task { await model.decide(.approve) } }
                .disabled(deciding)
                .accessibilityIdentifier("connect.approve")
            Button("Deny", role: .destructive) { Task { await model.decide(.deny) } }
                .disabled(deciding)
                .accessibilityIdentifier("connect.deny")
        } footer: {
            Text("Claude can then use what Settings \u{203A} Claude allows, until you disconnect it.")
        }
    }

    private var deciding: Bool {
        if case .deciding = model.phase { return true }
        return false
    }

    private var resultText: String? {
        switch model.phase {
        case .approved: "Approved. Your browser returns to Claude in a moment."
        case .denied: "Denied. Claude wasn't given access."
        default: nil
        }
    }
}
