import GymCore
import GymData
import SwiftUI

/// Reviews one Claude proposal: a card per change with a toggle (valid ones on by default; changes that don't fit
/// the current plan are disabled with the reason), then "Apply N changes" or "Dismiss all". Applying saves a
/// snapshot; Today then offers "Undo" (and Claude's screen does, for 7 days).
struct ProposalReviewView: View {
    let proposalId: UUID
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var proposal: Proposal?
    @State private var rows: [ProposalModel.Row] = []
    @State private var selected: Set<String> = []
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let proposal {
                    header(proposal)
                    ForEach(rows) { card($0) }
                    Text("A snapshot is saved; you can undo for 7 days.")
                        .font(.footnote).foregroundStyle(Theme.textTertiary)
                } else {
                    Text("This proposal is no longer available.").foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("proposal.missing")
                }
                if let error {
                    Text(error).foregroundStyle(Theme.destructive).accessibilityIdentifier("proposal.error")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            if proposal?.status == .pending { actionBar }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: env.planRevision) { load() }
    }

    private func header(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.createdAt.formatted(.dateTime.day().month(.abbreviated)))
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            DisplayTitle(text: "Plan change from Claude", size: 34)
                .accessibilityIdentifier("proposal.review")
            Text(p.summary).foregroundStyle(Theme.textPrimary).accessibilityIdentifier("proposal.summary")
            if p.status != .pending {
                Badge(text: statusText(p), kind: .neutral).accessibilityIdentifier("proposal.status")
            }
        }
        .padding(.top, 8)
    }

    private func card(_ row: ProposalModel.Row) -> some View {
        SolidCard {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Badge(text: row.label, kind: .neutral)
                    Text(row.text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("proposal.text.\(row.id)")
                    if let reason = row.reason, !reason.isEmpty {
                        Text(reason).font(.footnote).foregroundStyle(Theme.textSecondary)
                    }
                    if let invalid = row.invalidReason {
                        Text("Can't apply: \(invalid)").font(.footnote).foregroundStyle(Theme.destructive)
                            .accessibilityIdentifier("proposal.invalid.\(row.id)")
                    }
                }
                Spacer(minLength: 0)
                if proposal?.status == .pending {
                    Toggle("Apply", isOn: binding(for: row.id))
                        .labelsHidden()
                        .tint(Theme.primaryFill)
                        .disabled(row.invalidReason != nil)
                        .accessibilityIdentifier("proposal.change.\(row.id)")
                }
            }
        }
        .opacity(row.invalidReason == nil ? 1 : 0.55)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            GlassPillButton(title: "Dismiss all", identifier: "proposal.dismiss") { dismissAll() }
                .controlSize(.large)
            PrimaryGlassButton(title: applyTitle, identifier: "proposal.apply") { apply() }
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 8)
    }

    private var applyTitle: String {
        selected.count == 1 ? "Apply 1 change" : "Apply \(selected.count) changes"
    }

    private func statusText(_ p: Proposal) -> String {
        switch p.status {
        case .pending: "Pending"
        case .applied: p.autoApplied ? "Applied automatically" : "Applied"
        case .partial: "Partly applied"
        case .dismissed: "Dismissed"
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { selected.contains(id) }, set: { on in
            if on { selected.insert(id) } else { selected.remove(id) }
        })
    }

    private func load() {
        do {
            guard let p = try env.proposals.proposal(proposalId) else { proposal = nil; return }
            let invalid = p.status == .pending ? try env.proposalService().violations(for: p) : [:]
            let firstLoad = proposal?.id != p.id
            proposal = p
            rows = ProposalModel.rows(for: p.changes, plan: try env.routines.planState(), library: env.library,
                                      unit: env.profile.unit, now: env.now(), violations: invalid)
            if firstLoad { selected = Set(rows.filter { $0.invalidReason == nil }.map(\.id)) }
            selected = selected.filter { id in rows.contains { $0.id == id && $0.invalidReason == nil } }
        } catch {
            AppEnvironment.log.error("Load proposal failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Couldn't load this proposal."
        }
    }

    private func apply() {
        do {
            try env.applyProposal(proposalId, changeIds: selected)
            dismiss()
        } catch {
            AppEnvironment.log.error("Apply proposal failed: \(String(describing: error), privacy: .public)")
            self.error = "Couldn't apply these changes. Your plan wasn't changed."
        }
    }

    private func dismissAll() {
        do {
            try env.dismissProposal(proposalId)
            dismiss()
        } catch {
            AppEnvironment.log.error("Dismiss proposal failed: \(String(describing: error), privacy: .public)")
            self.error = "Couldn't dismiss this proposal. Please try again."
        }
    }
}
