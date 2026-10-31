import GymData
import SwiftUI

/// Settings > Moderation (admins only): what three reports hid, with Restore and Remove. The server decides who may
/// see it; this screen only reports what it says.
struct ModerationView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: ModerationModel?
    @State private var confirming: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let model { content(model) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.gutter).padding(.top, 12).padding(.bottom, 24)
        }
        .background(Theme.background)
        .navigationTitle("Moderation")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let created = ModerationModel(transport: env.gymSharing.transport)
            model = created
            await created.load()
        }
        .refreshable { await model?.load() }
    }

    @ViewBuilder
    private func content(_ model: ModerationModel) -> some View {
        if let error = model.error {
            message(error, identifier: "moderation.error")
        }
        if let notice = model.notice {
            message(notice, identifier: "moderation.notice")
        }
        if model.loaded, model.error == nil, model.entries.isEmpty {
            Text("Nothing is waiting for review.").foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("moderation.empty")
        }
        ForEach(model.entries) { entry in
            ModerationRow(entry: entry, model: model, confirming: $confirming)
        }
    }

    private func message(_ text: String, identifier: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Theme.destructive)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}

private struct ModerationRow: View {
    let entry: ModerationEntry
    let model: ModerationModel
    @Binding var confirming: UUID?

    private var busy: Bool { model.busy.contains(entry.id) }

    var body: some View {
        SolidCard {
            VStack(alignment: .leading, spacing: 10) {
                header
                ForEach(entry.reasons, id: \.reason) { item in
                    Text(ModerationModel.reasonLine(item)).font(.subheadline).foregroundStyle(Theme.textPrimary)
                }
                ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                    Text("\u{201C}\(note)\u{201D}").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                if confirming == entry.id { confirmCard } else { actions }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("moderation.row.\(entry.id.uuidString)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ModerationPhoto(path: entry.photoPath)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(.headline).foregroundStyle(Theme.textPrimary)
                Text(entry.targetType == .gym ? "Gym" : "Equipment").font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Text(ModerationModel.statusLine(entry)).font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("moderation.status.\(entry.id.uuidString)")
                if let address = entry.address {
                    Text(address).font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                if let words = entry.listingNotes {
                    Text("Notes: \(words)").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { buttons }
            VStack(spacing: 10) { buttons }
        }
        .disabled(busy)
    }

    /// A removed listing is only waiting for its photo to go: Restore would bring back a listing whose picture is
    /// about to be deleted, so the only thing left to do is Remove again.
    @ViewBuilder
    private var buttons: some View {
        if !entry.photoStillToDelete {
            SecondaryGlassButton(title: "Restore", identifier: "moderation.restore.\(entry.id.uuidString)") {
                Task { await model.restore(entry) }
            }
        }
        SecondaryGlassButton(title: "Remove", identifier: "moderation.remove.\(entry.id.uuidString)") {
            if entry.photoStillToDelete { Task { await model.remove(entry) } } else { confirming = entry.id }
        }
    }

    private var confirmCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remove this for everyone?").font(.headline).foregroundStyle(Theme.textPrimary)
            Text(entry.targetType == .gym
                 ? "The gym and its equipment leave the shared catalogue."
                 : "The listing leaves the shared catalogue and its photo is deleted. The photo can't be brought back.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { confirmButtons }
                VStack(spacing: 10) { confirmButtons }
            }
        }
        .padding(12)
        .background(Theme.background, in: .rect(cornerRadius: Theme.cardRadius))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var confirmButtons: some View {
        SecondaryGlassButton(title: "Cancel", identifier: "moderation.removeCancel.\(entry.id.uuidString)") {
            confirming = nil
        }
        PrimaryGlassButton(title: "Remove", identifier: "moderation.removeConfirm.\(entry.id.uuidString)") {
            confirming = nil
            Task { await model.remove(entry) }
        }
    }
}

/// The reported picture, loaded the way a borrowed one is: shown, never saved. Without one, or while it loads, the
/// dumbbell placeholder stands in.
private struct ModerationPhoto: View {
    @Environment(AppEnvironment.self) private var env
    let path: String?
    @State private var image: UIImage?

    var body: some View {
        GymPhotoView(fileName: nil, width: 64, cornerRadius: 10, placeholderSymbol: "dumbbell")
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true)
                        .frame(width: 64, height: 64).clipped()
                }
            }
            .clipShape(.rect(cornerRadius: 10))
            .accessibilityHidden(true)
            .task(id: path) {
                guard let path else { image = nil; return }
                image = await env.catalogPhoto(path)
            }
    }
}
