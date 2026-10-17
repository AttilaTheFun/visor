// The agent's questions (Claude Code's AskUserQuestion), answered from
// here: each one's options to pick (several, where it allows), or words of
// the user's own. Sent, the answers go back as the tool's own input; skipped,
// the agent hears that the user did not answer.

import AgentUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct QuestionSheet: View {
    let request: ApprovalRequest
    let host: AgentServerConnection
    let sessionID: String
    @Environment(\.dismiss) private var dismiss
    /// The options picked, by question.
    @State private var picked: [String: Set<String>] = [:]
    /// Words of the user's own, by question.
    @State private var own: [String: String] = [:]

    private var questions: [AgentQuestion] { request.questions ?? [] }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(questions, id: \.question) { question in
                    Section {
                        Text(question.question).font(.headline)
                        ForEach(question.options, id: \.label) { option in
                            ApprovalChoice(title: option.label, detail: option.description,
                                           chosen: picked[question.question]?.contains(option.label) == true) {
                                pick(option.label, in: question)
                            }
                        }
                        TextField(question.options.isEmpty ? "Your answer" : "Something else", text: ownWords(for: question))
                            .accessibilityIdentifier("question-own")
                    } header: {
                        Text(question.header.isEmpty ? "Question" : question.header)
                    } footer: {
                        if question.multiSelect { Text("Pick as many as apply.") }
                    }
                }
            }
            .insetGroupedForm()
            .navigationTitle(questions.count == 1 ? "Question" : "\(questions.count) Questions")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        host.answer(sessionID, id: request.id, answers: nil)
                        dismiss()
                    }
                    .accessibilityIdentifier("question-skip")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { send() }
                        .disabled(!answered)
                        .accessibilityIdentifier("question-send")
                }
            }
        }
        .presentationDetentsMediumLarge()
    }

    /// One option picked, or picked again to take it back. A question that
    /// takes one answer takes the option in place of any other, and of
    /// words of the user's own.
    private func pick(_ label: String, in question: AgentQuestion) {
        var chosen = picked[question.question] ?? []
        if chosen.contains(label) {
            chosen.remove(label)
        } else if question.multiSelect {
            chosen.insert(label)
        } else {
            chosen = [label]
            own[question.question] = ""
        }
        picked[question.question] = chosen
    }

    /// The user's own words for a question; for a question that takes one
    /// answer, typing them takes back the option picked.
    private func ownWords(for question: AgentQuestion) -> Binding<String> {
        Binding(get: { own[question.question] ?? "" }, set: { words in
            own[question.question] = words
            if !question.multiSelect, !words.isEmpty { picked[question.question] = [] }
        })
    }

    /// One question's answer: the options picked, in the order offered,
    /// then the user's own words; "" when there is none.
    private func answer(to question: AgentQuestion) -> String {
        let chosen = question.options.map(\.label).filter { picked[question.question]?.contains($0) == true }
        let words = own[question.question] ?? ""
        let trimmed = String(String(words.drop(while: \.isWhitespace).reversed()).drop(while: \.isWhitespace).reversed())
        return (chosen + (trimmed.isEmpty ? [] : [trimmed])).joined(separator: ", ")
    }

    private var answered: Bool { !questions.isEmpty && questions.allSatisfy { !answer(to: $0).isEmpty } }

    private func send() {
        let answers = Dictionary(questions.map { ($0.question, answer(to: $0)) }, uniquingKeysWith: { first, _ in first })
        host.answer(sessionID, id: request.id, answers: answers)
        dismiss()
    }
}
