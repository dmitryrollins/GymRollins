import GymCore
import GymData
import SwiftUI
import UniformTypeIdentifiers

/// Onboarding step 2/3 (also Settings/Log → Import): import a CSV exported from Fitbod, Strong, Hevy or FitNotes
/// (building an `ImportPlan` from it) or start fresh. The source picker defaults to auto-detect; the owner can pin
/// the app, and a file whose header belongs to a different app is rejected with the detected app's name. When the
/// file doesn't say which weight unit it uses (Strong's current export), a kg/lb choice appears, defaulting to the
/// profile's unit. Once a plan is built, this same screen swaps to `ImportResultView` in place (rather than a
/// further `NavigationStack` push) — the mockup treats "match your exercises" / "import complete" as part of this
/// one step (no step dots of its own), and it avoids threading the plan back out through a callback into a
/// *second* push.
struct ImportCSVView: View {
    @Environment(AppEnvironment.self) private var env
    let onBack: () -> Void
    /// Proceed to Connect Claude, either via "Start fresh" or after Import Result's own "Continue".
    let onDone: () -> Void

    @State private var showFilePicker = false
    /// nil = auto-detect.
    @State private var source: ImportSource?
    @State private var weightUnit: WeightUnit = .kg
    /// The profile's unit seeds `weightUnit` once; later reappearances (back from the preview) keep the owner's pick.
    @State private var weightUnitSeeded = false
    /// The picked file, kept so changing the source or unit re-parses without picking it again.
    @State private var fileText: String?
    @State private var fileName: String?
    @State private var rowCount: Int?
    @State private var needsWeightUnit = false
    @State private var plan: ImportPlan?
    @State private var building = false
    /// Bumped per parse so a slower, stale parse can't overwrite a newer one.
    @State private var parseGeneration = 0
    @State private var error: String?
    /// Set by tapping "Import" once a plan is built; swaps this same screen to `ImportResultView` (a plain local
    /// state flip, not a further `NavigationStack` push threading the plan back out through a callback).
    @State private var showResult = false

    #if DEBUG
    private let launchOptions = LaunchOptions()
    #endif

    var body: some View {
        if showResult, let plan {
            ImportResultView(plan: plan, onBack: { showResult = false }, onContinue: onDone)
        } else {
            picker
        }
    }

    private var picker: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                VStack(alignment: .leading, spacing: 4) {
                    FieldLabel(text: "Step 2 of 3")
                    DisplayTitle(text: "Bring your history", size: 34)
                }
                ImportSourcePicker(selection: $source, disabled: building)
                VStack(spacing: 10) {
                    importCard
                    if needsWeightUnit && fileText != nil { unitCard }
                    freshCard
                    if let plan { columnMapping(plan.result.source) }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.destructive).accessibilityIdentifier("import.error")
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 58)
            .padding(.bottom, 110)
        }
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if building { ProgressView().tint(Theme.accent) }
                PrimaryGlassButton(title: "Import", identifier: "import.run") { continueWithPlan() }
                    .disabled(plan == nil || building)
                    .opacity(plan == nil ? 0 : 1)
            }
            .padding(.horizontal, Theme.gutter).padding(.bottom, 8)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            handle(result)
        }
        .task {
            guard !weightUnitSeeded else { return }
            weightUnitSeeded = true
            weightUnit = env.profile.unit
        }
        .onChange(of: source) { buildPlan() }
        .onChange(of: weightUnit) { if needsWeightUnit { buildPlan() } }
    }

    private var header: some View {
        HStack {
            OnboardingBackButton(action: onBack)
            Spacer()
            OnboardingProgressDots(step: 2)
        }
    }

    private var importCard: some View {
        Button { chooseFile() } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down").foregroundStyle(Theme.textPrimary)
                    Text("Import CSV from another app").font(.body.weight(.bold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    if plan != nil {
                        Image(systemName: "checkmark").foregroundStyle(Theme.accent).accessibilityHidden(true)
                    }
                }
                if let fileSummary {
                    Text(fileSummary).font(.footnote).foregroundStyle(Theme.textSecondary)
                        .padding(.leading, 34)
                        .accessibilityIdentifier("import.file")
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .disabled(building)
        .accessibilityHint("Choose a CSV file exported from another app")
        .accessibilityIdentifier("import.choose")
    }

    /// "file.csv · 42 rows · Strong" once parsed; just the name while a picked file fails to parse.
    private var fileSummary: String? {
        guard let fileName else { return nil }
        guard let plan, let rowCount else { return fileName }
        return [fileName, "\(rowCount) rows", plan.result.source.displayName].joined(separator: " \u{00B7} ")
    }

    private var unitCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Weights in this file")
            Text("This export doesn't say which unit it uses. Pick the unit set in the app you exported from.")
                .font(.footnote).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            GlassSegmentedControl(options: [(WeightUnit.kg, "kg"), (WeightUnit.lb, "lb")], selection: $weightUnit,
                                  identifierPrefix: "import.unit")
                .disabled(building)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private var freshCard: some View {
        Button { onDone() } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus").foregroundStyle(Theme.textPrimary)
                Text("Start fresh").font(.body.weight(.bold)).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .disabled(building)
        .accessibilityIdentifier("import.skip")
    }

    private func columnMapping(_ source: ImportSource) -> some View {
        VStack(spacing: 0) {
            HStack {
                FieldLabel(text: "Column mapping \u{00B7} \(source.displayName)")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            ForEach(ImportSourceHelp.mapping(for: source), id: \.0) { row in
                HStack {
                    Text(row.0).font(.footnote)
                    Spacer()
                    Text(row.1).font(.footnote).foregroundStyle(row.2 ? Theme.textTertiary : Theme.textSecondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                Divider().background(Theme.divider)
            }
        }
        .background(Theme.card, in: .rect(cornerRadius: Theme.cardRadius))
    }

    private func chooseFile() {
        guard !building else { return }
        #if DEBUG
        if launchOptions.importFixture {
            let fixture = launchOptions.importFixtureSource
            load(text: ImportFixture.csv(for: fixture), name: ImportFixture.fileName(for: fixture))
            return
        }
        #endif
        showFilePicker = true
    }

    private func handle(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try ImportFile.readText(at: url)
                load(text: text, name: url.lastPathComponent)
            } catch {
                self.error = error.message
            }
        case .failure:
            error = "Couldn't read that file."
        }
    }

    private func load(text: String, name: String) {
        fileText = text
        fileName = name
        buildPlan()
    }

    /// Parses the picked file as the selected source (off the main actor: files can be up to 25 MB), then matches
    /// its exercise names into a plan.
    private func buildPlan() {
        guard let text = fileText else { return }
        parseGeneration += 1
        let generation = parseGeneration
        let selected = source
        let options = ImportOptions(weightUnit: weightUnit)
        building = true
        error = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try WorkoutImporters.parse(text, source: selected, options: options) }
            }.value
            guard generation == parseGeneration else { return }
            apply(outcome, text: text, selected: selected)
            building = false
        }
    }

    private func apply(_ outcome: Result<WorkoutImportResult, Error>, text: String, selected: ImportSource?) {
        do {
            let result = try outcome.get()
            let matcher = ExerciseMatcher(library: env.library.exercises)
            plan = ImportPlan.make(result: result, library: env.library, aliases: try ImportAliases.load(result.source),
                                   matcher: matcher)
            rowCount = result.rowCount
            needsWeightUnit = WorkoutImporters.needsWeightUnit(text, source: result.source)
        } catch let importError as WorkoutImportError {
            reset(message: ImportSourceHelp.message(for: importError, selected: selected))
        } catch {
            AppEnvironment.log.error("Import parse failed: \(error.localizedDescription, privacy: .public)")
            reset(message: "Couldn't read that file.")
        }
    }

    private func reset(message: String) {
        plan = nil
        rowCount = nil
        needsWeightUnit = false
        error = message
    }

    private func continueWithPlan() {
        guard plan != nil else { return }
        showResult = true
    }
}
