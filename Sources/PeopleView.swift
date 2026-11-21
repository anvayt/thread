import SwiftUI
import UIKit

// MARK: - People

/// Everyone in your network, as Contacts lists them: alphabetical, with an
/// index down the side. People Thread added without a name come first, so
/// they get named.
struct PeopleView: View {
    @State private var people: [RosterPerson] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var errorText: String?
    @State private var showEnroll = false
    @State private var renaming: NameTarget?
    @State private var forgetting: RosterPerson?
    @State private var addingSamples = false
    @State private var query = ""

    /// Everyone, or those whose name, role or company has what is typed in
    /// the search field.
    private var shown: [RosterPerson] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return people }
        return people.filter {
            $0.name.localizedCaseInsensitiveContains(text)
                || $0.subtitle.localizedCaseInsensitiveContains(text)
        }
    }

    /// People added without a name, waiting for one.
    private var unnamed: [RosterPerson] {
        shown.filter { FaceCache.isPlaceholder($0.name) }
    }

    /// Everyone else, grouped by the first letter of their name.
    private var groups: [(letter: String, people: [RosterPerson])] {
        let named = shown
            .filter { !FaceCache.isPlaceholder($0.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let grouped = Dictionary(grouping: named) { person -> String in
            let first = person.name.prefix(1).uppercased()
            return first.rangeOfCharacter(from: .letters) == nil ? "#" : first
        }
        return grouped.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        .map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !unnamed.isEmpty {
                    Section {
                        ForEach(unnamed) { person in
                            row(person)
                        }
                    } header: {
                        Text("Needs a Name")
                    } footer: {
                        Text("Thread added these faces because nobody said a name.")
                    }
                }
                ForEach(groups, id: \.letter) { group in
                    Section(group.letter) {
                        ForEach(group.people) { person in
                            row(person)
                        }
                    }
                    .sectionIndexLabel(group.letter)
                }
            }
            .listStyle(.plain)
            .listSectionSpacing(0)
            .overlay { emptyState }
            .searchable(text: $query, prompt: "Search")
            .navigationTitle("People")
            .navigationSubtitle(countLine)
            .navigationDestination(for: String.self) { name in
                let person = people.first { $0.name == name }
                ContactView(
                    name: name,
                    knownSubtitle: person?.subtitle ?? "",
                    hasFace: person?.enrolledFace,
                    onChanged: { await reload() }
                )
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Person", systemImage: "plus") { showEnroll = true }
                }
            }
            .sheet(isPresented: $showEnroll) {
                EnrollSheet(onDone: { await reload() })
            }
            .sheet(item: $renaming) { target in
                RenameSheet(placeholder: target.name, onDone: { await reload() })
            }
            .confirmationDialog(
                "Forget \(forgetting?.name ?? "")?",
                isPresented: Binding(
                    get: { forgetting != nil },
                    set: { if !$0 { forgetting = nil } }
                ),
                titleVisibility: .visible,
                presenting: forgetting
            ) { person in
                Button("Forget", role: .destructive) {
                    Task { await forget(person) }
                }
            } message: { _ in
                Text("Their face, their notes and every meeting are permanently deleted.")
            }
            .refreshable { await reload() }
            .task { await reload() }
        }
    }

    private var countLine: String {
        guard loaded, errorText == nil, !people.isEmpty else { return "" }
        return people.count == 1 ? "1 person" : "\(people.count) people"
    }

    private func row(_ person: RosterPerson) -> some View {
        NavigationLink(value: person.name) {
            PersonRow(
                name: person.name,
                subtitle: person.subtitle.isEmpty ? person.relationship : person.subtitle
            )
        }
        .swipeActions(edge: .trailing) {
            Button("Forget", systemImage: "trash", role: .destructive) {
                forgetting = person
            }
        }
        .contextMenu {
            if FaceCache.frame(for: person.name) != nil {
                Button(
                    FaceCache.isPlaceholder(person.name) ? "Add Name" : "Rename",
                    systemImage: "pencil"
                ) {
                    renaming = NameTarget(name: person.name)
                }
            }
            Button("Forget", systemImage: "trash", role: .destructive) {
                forgetting = person
            }
        } preview: {
            PersonHeader(name: person.name, subtitle: person.subtitle, avatarSize: 88)
                .padding(24)
                .frame(width: 300)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !people.isEmpty, shown.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if people.isEmpty {
            if loading, !loaded {
                ProgressView()
            } else if let errorText {
                ContentUnavailableView {
                    Label("Can't Reach the Backend", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorText)
                } actions: {
                    Button("Try Again") { Task { await reload() } }
                        .buttonStyle(.glass)
                }
            } else if loaded {
                ContentUnavailableView {
                    Label("No People Yet", systemImage: "person.2")
                } description: {
                    Text("People you meet appear here. You can also add someone yourself.")
                } actions: {
                    Button("Add Person") { showEnroll = true }
                        .buttonStyle(.glassProminent)
                    Button("Add Sample People") {
                        Task { await addSamples() }
                    }
                    .disabled(addingSamples)
                }
            }
        }
    }

    // MARK: Data

    private func reload() async {
        loading = true
        defer {
            loading = false
            loaded = true
        }
        do {
            people = try await BackendAPI.roster()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func forget(_ person: RosterPerson) async {
        do {
            try await BackendAPI.forget(name: person.name)
            FaceCache.forget(person.name)
            FaceCache.clearPlaceholder(person.name)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            errorText = "Couldn't forget them. \(error.localizedDescription)"
        }
        await reload()
    }

    private func addSamples() async {
        addingSamples = true
        defer { addingSamples = false }
        try? await BackendAPI.seed()
        await reload()
    }
}

// MARK: - Avatar

/// The contact's picture: the frame Thread captured when it met them, falling
/// back to their initials, the way Contacts shows a person with no photo.
///
/// The picture lives on the phone in `FaceCache`, keyed by the resolved name,
/// which is why a rename re-keys the cache instead of leaving the photo
/// stranded under "New contact 03".
struct Avatar: View {
    let name: String
    var size: CGFloat = 40

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        return String(letters).uppercased()
    }

    var body: some View {
        ZStack {
            if let photo = FaceCache.image(for: name) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.systemGray2)
                Text(initials.isEmpty ? "?" : initials)
                    .font(.system(size: size * 0.4, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

// MARK: - Contact page

/// One person, laid out like a contact card: their photo and name at the top
/// with actions under it, then everything Thread knows about them.
struct ContactView: View {
    let name: String
    /// Their role and company, when the list that opened this page knows it.
    var knownSubtitle = ""
    /// Whether a face is on file for them, when the list knows it.
    var hasFace: Bool?
    var onChanged: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var card: PersonCard?
    @State private var errorText: String?
    @State private var confirmForget = false
    @State private var forgetting = false
    @State private var renaming = false
    @State private var drafting = false
    @State private var showsTitle = false

    /// A rename is only possible when we still hold the frame this person was
    /// enrolled from: the backend has no rename endpoint, so renaming means
    /// re-enrolling under the real name.
    private var canRename: Bool { FaceCache.frame(for: name) != nil }
    private var isPlaceholder: Bool { FaceCache.isPlaceholder(name) }

    /// Their role and company: from the list that opened the page, or else
    /// the first emphasised line of their page.
    private var subtitle: String {
        if !knownSubtitle.isEmpty { return knownSubtitle }
        guard let md = card?.md else { return "" }
        for raw in md.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*"), line.hasSuffix("*"), !line.hasPrefix("**"), line.count > 2 {
                return String(line.dropFirst().dropLast())
            }
        }
        return ""
    }

    /// A line under the name when something about them is missing.
    private var caption: String {
        if isPlaceholder { return "Added without a name" }
        if hasFace == false { return "No face on file, so Thread can't recognise them yet" }
        return ""
    }

    /// Their page as plain text, to share.
    private var shareText: String {
        guard let md = card?.md else { return name }
        return md.components(separatedBy: .newlines)
            .map { raw -> String in
                var line = raw.trimmingCharacters(in: .whitespaces)
                while line.hasPrefix("#") { line.removeFirst() }
                if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2) }
                if line.hasPrefix("> ") { line = String(line.dropFirst(2)) }
                return line.replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 18) {
                    PersonHeader(
                        name: name,
                        subtitle: subtitle,
                        caption: caption
                    )
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            if canRename {
                                HeaderAction(
                                    title: isPlaceholder ? "Add Name" : "Rename",
                                    systemImage: "pencil"
                                ) {
                                    renaming = true
                                }
                            }
                            ShareLink(item: shareText) {
                                HeaderActionLabel(title: "Share", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                            .disabled(card == nil)
                            // Someone with no name yet has nobody to write to.
                            if !isPlaceholder {
                                HeaderAction(title: "Follow-Up", systemImage: "square.and.pencil") {
                                    drafting = true
                                }
                                .accessibilityLabel("Draft Follow-Up")
                                .disabled(card == nil)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
                .onScrollVisibilityChange(threshold: 0.2) { visible in
                    withAnimation(.easeOut(duration: 0.15)) { showsTitle = !visible }
                }
            } footer: {
                if isPlaceholder, !canRename {
                    Text("The photo this contact was added from isn't on this phone, so they can't be named here. Add them again from Meet.")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .listRowBackground(Color.clear)

            if let card {
                MarkdownSections(md: card.md, skipsSubtitle: true)
            } else if let errorText {
                Section {
                    ProblemLabel(errorText)
                }
            } else {
                Section {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                }
            }

            if card != nil {
                Section {
                    Button(role: .destructive) {
                        confirmForget = true
                    } label: {
                        HStack {
                            Text("Forget This Person")
                            if forgetting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(forgetting)
                } footer: {
                    Text("Deletes their face, their notes and every meeting. This can't be undone.")
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Like Contacts: the name moves into the bar only once the header
            // has scrolled away.
            ToolbarItem(placement: .principal) {
                Text(name)
                    .font(.headline)
                    .opacity(showsTitle ? 1 : 0)
            }
        }
        .confirmationDialog(
            "Forget \(name)?",
            isPresented: $confirmForget,
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) { Task { await forget() } }
        } message: {
            Text("Their face, their notes and every meeting are permanently deleted.")
        }
        .sheet(isPresented: $renaming) {
            RenameSheet(
                placeholder: name,
                onDone: {
                    await onChanged()
                    dismiss()
                }
            )
        }
        .sheet(isPresented: $drafting) {
            FollowUpSheet(name: name)
        }
        .task {
            do {
                card = try await BackendAPI.personCard(name: name)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func forget() async {
        forgetting = true
        defer { forgetting = false }
        do {
            try await BackendAPI.forget(name: name)
            FaceCache.forget(name)
            FaceCache.clearPlaceholder(name)
            await onChanged()
            dismiss()
        } catch {
            errorText = "Couldn't forget them. \(error.localizedDescription)"
        }
    }
}

// MARK: - Draft follow-up

/// The follow-up message to one person, written by the backend's language
/// model (Nemotron) from what is on record about them. Thread drafts it and
/// never sends it: Copy and Share hand it to whichever app does.
struct FollowUpSheet: View {
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var message: String?
    @State private var errorText: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                if let message {
                    Section {
                        Text(message)
                            .textSelection(.enabled)
                    } header: {
                        Text("To \(name)")
                    } footer: {
                        Text("Written by Nemotron from what Thread has on record. Read it before you send it.")
                    }

                    Section {
                        Button {
                            UIPasteboard.general.string = message
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        ShareLink(item: message) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            Task { await write() }
                        } label: {
                            Label("Write Again", systemImage: "arrow.clockwise")
                        }
                    }
                } else if let errorText {
                    Section {
                        ProblemLabel(errorText)
                        Button("Try Again") { Task { await write() } }
                    }
                } else {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Nemotron is writing…")
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Draft Follow-Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await write() }
    }

    private func write() async {
        message = nil
        errorText = nil
        copied = false
        do {
            let draft = try await BackendAPI.followup(name: name)
            if draft.isEmpty {
                errorText = "The backend sent back an empty message."
            } else {
                message = draft
            }
        } catch {
            errorText = "Couldn't write the message. \(error.localizedDescription)"
        }
    }
}

// MARK: - Rename

/// Renames a contact.
///
/// API limitation: the backend has no rename endpoint. `enroll` finds an
/// existing person by exact-or-fuzzy NAME only,
/// so the only way to rename is to re-enrol the cached reference frame under
/// the real name (which also merges into a record `ingest` may already have
/// created) and then `forget` the placeholder.
struct RenameSheet: View {
    let placeholder: String
    var onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var role = ""
    @State private var org = ""
    @State private var saving = false
    @State private var errorText: String?

    private var trimmedName: String {
        newName.trimmingCharacters(in: .whitespaces)
    }

    private var placeholderTitle: String {
        FaceCache.isPlaceholder(placeholder) ? "Add Name" : "Rename"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $newName)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                    TextField("Role", text: $role)
                    TextField("Company", text: $org)
                } footer: {
                    Text("Their photo moves to the new name, so they are still recognised. If someone with this name is already in your network, the face is attached to them.")
                }

                if let errorText {
                    Section {
                        ProblemLabel(errorText)
                    }
                }
            }
            .navigationTitle(placeholderTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(trimmedName.isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        guard !trimmedName.isEmpty else { return }
        guard let jpeg = FaceCache.frame(for: placeholder) else {
            errorText = "Their photo isn't on this phone any more. Add them again from Meet."
            return
        }
        saving = true
        defer { saving = false }
        do {
            let outcome = try await BackendAPI.rename(
                from: placeholder,
                to: trimmedName,
                photoJpeg: jpeg,
                role: role.trimmingCharacters(in: .whitespaces),
                org: org.trimmingCharacters(in: .whitespaces)
            )
            FaceCache.move(from: placeholder, to: outcome.name)
            FaceCache.clearPlaceholder(placeholder)
            dismiss()
            await onDone()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Enroll sheet

struct EnrollSheet: View {
    var onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var role = ""
    @State private var org = ""
    @State private var relationship = ""
    @State private var photo: UIImage?
    @State private var showCamera = false
    @State private var saving = false
    @State private var errorText: String?

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && photo != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .textInputAutocapitalization(.words)
                    TextField("Role", text: $role)
                    TextField("Company", text: $org)
                    TextField("Where you met", text: $relationship)
                }

                Section {
                    if let photo {
                        Image(uiImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(Circle())
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                    Button(photo == nil ? "Take Photo" : "Retake Photo") {
                        showCamera = true
                    }
                } header: {
                    Text("Photo")
                } footer: {
                    Text("A photo of their face is needed so Thread can recognise them. If they are already in your network, the photo is attached to them.")
                }

                if let errorText {
                    Section {
                        ProblemLabel(errorText)
                    }
                }
            }
            .navigationTitle("New Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Add") { Task { await save() } }
                            .disabled(!canSave)
                    }
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker(image: $photo)
                    .ignoresSafeArea()
            }
        }
    }

    private func save() async {
        guard let jpeg = photo?.jpegData(compressionQuality: 0.8) else {
            errorText = "Take a photo of their face first."
            return
        }
        saving = true
        defer { saving = false }
        do {
            _ = try await BackendAPI.enroll(
                name: name.trimmingCharacters(in: .whitespaces),
                role: role.trimmingCharacters(in: .whitespaces),
                org: org.trimmingCharacters(in: .whitespaces),
                relationship: relationship.trimmingCharacters(in: .whitespaces),
                photoJpeg: jpeg
            )
            await onDone()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Camera picker

/// UIImagePickerController wrapper: camera when available, photo library
/// otherwise (simulator-friendly).
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType =
            UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIImagePickerController, context: Context
    ) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate,
        UINavigationControllerDelegate
    {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            parent.image =
                (info[.editedImage] as? UIImage)
                ?? (info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
