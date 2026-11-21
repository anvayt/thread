import SwiftUI

/// What is being searched for and what came back. The root view owns it, so
/// a search survives switching tabs.
@MainActor
final class SearchModel: ObservableObject {
    @Published var query = "" {
        didSet {
            if trimmedQuery.isEmpty {
                answer = nil
                askedQuestion = ""
            }
        }
    }
    @Published private(set) var answer: NetworkAnswer?
    @Published private(set) var askedQuestion = ""
    @Published private(set) var asking = false

    var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Asks the whole network the question in the field.
    func ask() async {
        let text = trimmedQuery
        guard !text.isEmpty, !asking else { return }
        asking = true
        askedQuestion = text
        defer { asking = false }
        do {
            answer = try await BackendAPI.query(question: text)
        } catch {
            answer = NetworkAnswer(
                matches: [],
                reason: "Couldn't ask. \(error.localizedDescription)",
                searched: 0
            )
        }
    }
}

/// Search. Typing finds people by name, role or company as you type; pressing
/// Search asks the whole network the question in plain words, such as who you
/// met working on payments.
struct SearchView: View {
    @ObservedObject var model: SearchModel
    @State private var people: [RosterPerson] = []
    @FocusState private var searchFocused: Bool

    /// Questions to start from, shown before anything is typed.
    private let suggestions = [
        "Who did I meet working on payments?",
        "Who is raising a round?",
        "Who do I owe a follow-up?",
        "Who works in healthcare?",
    ]

    private var trimmedQuery: String { model.trimmedQuery }

    /// People whose name, role, company or where you met contains the text.
    private var matchingPeople: [RosterPerson] {
        guard !trimmedQuery.isEmpty else { return [] }
        return people.filter { person in
            [person.name, person.role, person.org, person.relationship]
                .contains { $0.localizedCaseInsensitiveContains(trimmedQuery) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if model.asking {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking through your network…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let answer = model.answer {
                    answerSection(answer)
                }

                if trimmedQuery.isEmpty, model.answer == nil, !model.asking {
                    Section("Try Asking") {
                        ForEach(suggestions, id: \.self) { suggestion in
                            Button {
                                model.query = suggestion
                                submit()
                            } label: {
                                Label {
                                    Text(suggestion)
                                        .foregroundStyle(Color.primary)
                                } icon: {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundStyle(Color.secondary)
                                }
                            }
                        }
                    }
                }

                if !trimmedQuery.isEmpty, !model.asking, trimmedQuery != model.askedQuestion {
                    Section {
                        Button {
                            submit()
                        } label: {
                            Label("Ask “\(trimmedQuery)”", systemImage: "text.magnifyingglass")
                        }
                    } footer: {
                        Text("Thread reads everything it knows about your network to answer.")
                    }
                }

                if !matchingPeople.isEmpty {
                    Section("People") {
                        ForEach(matchingPeople) { person in
                            NavigationLink(value: person.name) {
                                PersonRow(name: person.name, subtitle: person.subtitle)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .searchable(text: $model.query, prompt: "People, or ask a question")
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { submit() }
            .navigationDestination(for: String.self) { name in
                let person = people.first { $0.name == name }
                ContactView(
                    name: name,
                    knownSubtitle: person?.subtitle ?? "",
                    hasFace: person?.enrolledFace,
                    onChanged: { await loadPeople() }
                )
            }
            .task { await loadPeople() }
        }
    }

    private func answerSection(_ answer: NetworkAnswer) -> some View {
        Section {
            if !answer.reason.isEmpty {
                Text(answer.reason)
                    .padding(.vertical, 2)
            }
            if answer.matches.isEmpty {
                Text("No one fits that yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(answer.matches) { match in
                NavigationLink(value: match.name) {
                    PersonRow(
                        name: match.name,
                        subtitle: match.org.isEmpty ? match.last : match.org
                    )
                }
            }
        } header: {
            Text(model.askedQuestion)
                .textCase(nil)
        } footer: {
            if answer.searched > 0 {
                Text(
                    answer.searched == 1
                        ? "Looked through 1 person."
                        : "Looked through \(answer.searched) people."
                )
            }
        }
    }

    /// Asks the question and lowers the keyboard, so the answer can be read.
    private func submit() {
        searchFocused = false
        Task { await model.ask() }
    }

    // MARK: Data

    private func loadPeople() async {
        people = (try? await BackendAPI.roster()) ?? people
    }
}
