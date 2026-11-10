import GymData
import SwiftUI

/// "+ Add a private gym": a name and an optional address. A private gym stays on this phone.
struct AddPrivateGymSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onSaved: (Gym) -> Void
    @State private var name = ""
    @State private var address = ""
    @State private var errorText: String?

    private var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Gym name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("privateGym.name")
                    TextField("Address (optional)", text: $address)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("privateGym.address")
                } footer: {
                    Text("A private gym stays on this phone.")
                }
                if let errorText {
                    Text(errorText).foregroundStyle(Theme.destructive)
                        .accessibilityIdentifier("privateGym.error")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Add a private gym")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("privateGym.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave).accessibilityIdentifier("privateGym.save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        do {
            let gym = try env.gyms.addPrivateGym(name: name, address: address.isEmpty ? nil : address)
            onSaved(gym)
            dismiss()
        } catch GymDataError.invalidInput(let message) {
            errorText = message
        } catch {
            AppEnvironment.log.error("Add private gym failed: \(error.localizedDescription, privacy: .public)")
            errorText = "Couldn't save the gym. Try again."
        }
    }
}
