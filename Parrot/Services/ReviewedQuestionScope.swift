import Foundation

/// These labels are independently reviewed metadata, not inferred from a
/// provider's display name. The source identity binds the label to its text.
enum ReviewedSourceAuthority: String, Codable { case productHelp, vendorReference }

enum ReviewedScopeCategory: String, Codable {
    case productControl, vendorFundamental
    var authority: ReviewedSourceAuthority {
        self == .productControl ? .productHelp : .vendorReference
    }
}

enum ReviewedQuestionForm: String, Codable, Hashable {
    case procedure, capability, behavior, definition, condition, diagnosis, location, actor, clientState

    /// Read every interrogative clause, including "can ... and how ...".
    /// Unrecognized questions do not acquire a permissive default form.
    static func forms(in question: String) -> Set<Self> {
        // Wh-questions may follow an arbitrary spoken preface ("also, where").
        // Auxiliary-only clauses also begin after a contrast or follow-up.
        let pattern = "(?:\\b(how|what|when|which|why|where|who|whom|whose)\\b|(?:^|[.!?;,:]|\\b(?:and|or|but|also|then|so)\\s+)\\s*(can|could|may|might|will|would|shall|does|do|is|are|was|were|should|did|has|have|had)\\b)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let matches = regex.matches(in: question, range: NSRange(question.startIndex..., in: question))
        var result = Set<Self>()
        for (index, match) in matches.enumerated() {
            let word = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
            guard let wordRange = Range(word, in: question) else { continue }
            let end = index + 1 < matches.count
                ? Range(matches[index + 1].range, in: question)!.lowerBound : question.endIndex
            let clause = ReviewedQuestionScope.normalize(String(question[wordRange.lowerBound..<end]))
            let first = clause.split(separator: " ").first.map(String.init) ?? ""
            if requestsClientState(clause) {
                result.insert(.clientState)
                continue
            }
            switch first {
            case "did", "has", "have", "had", "was", "were": result.insert(.clientState)
            case "is", "are": result.insert(.capability)
            case "how":
                if ["how do i ", "how do we ", "how can i ", "how can we ", "how to "].contains(where: clause.hasPrefix) {
                    result.insert(.procedure)
                } else if clause.hasPrefix("how does ") || clause.hasPrefix("how do ") {
                    result.insert(.behavior)
                } else { result.insert(.definition) }
            case "can", "could", "may", "might": result.insert(.capability)
            case "will", "would", "shall", "does", "do": result.insert(.behavior)
            case "what", "which": result.insert(.definition)
            case "where": result.insert(.location)
            case "who", "whom", "whose": result.insert(.actor)
            case "when": result.insert(.condition)
            case "why": result.insert(.diagnosis)
            case "should": result.insert(.procedure)
            default: break
            }
        }
        return result
    }

    /// Published help describes general behavior, not a client's actual file.
    /// These conservative exclusions are routing gates, not a semantic proof.
    private static func requestsClientState(_ clause: String) -> Bool {
        func matches(_ pattern: String) -> Bool {
            clause.range(of: pattern, options: .regularExpression) != nil
        }
        // Instructions can mention "my document" without asserting its state.
        if ["how do i ", "how do we ", "how can i ", "how can we ", "how to "]
            .contains(where: clause.hasPrefix) { return false }
        // A help article cannot establish present availability or completion.
        // Apply this to auxiliary clauses too, not only wh-questions.
        if matches("\\b(?:now|currently|already|yet|still|anymore)\\b") { return true }
        // Ownership anywhere in a non-procedure clause can make a general
        // capability question an account entitlement or current-file question.
        if matches("\\b(?:my|our|your|their|this|that) (?:[a-z0-9]+ ){0,4}(?:account|workspace|file|document|publication|project|budget|selection|styles|images|photos)\\b") { return true }
        if matches("^(?:does|do|will|would|can|could|may|might|is|are|should) (?:my|our|your|their|this|that|these|those)\\b") { return true }
        if matches("^(?:is|are|does|do|will|would) the (?:[a-z0-9]+ ){0,8}(?:file|document|account|publication|project|budget)\\b") { return true }
        if matches("^(?:is|are)\\b"),
           matches("\\b(?:enabled|disabled|active|inactive|on|off|running|configured|selected|connected|installed)\\b") { return true }
        if matches("^(?:how|what|which|where|who|whom|whose|why|when)\\b"),
           matches("\\b(?:did|has|have|had|was|were|now|currently|already|last|latest|selected|assigned|configured)\\b") { return true }
        return false
    }
}

/// A closed, reviewed routing prerequisite. Matching it is NOT proof that a
/// reply fully answers the question; the selector must still check directness.
/// Each group is required, with OR alternatives within a group. Complete words
/// and phrases match after case/diacritic/punctuation normalization.
struct ReviewedQuestionScope: Codable, Equatable {
    let key: String
    let category: ReviewedScopeCategory
    let requiredPhrases: [[String]]
    let forbiddenPhrases: [String]

    var digestParts: [String] {
        var parts = ["scope-v2", key, category.rawValue, String(requiredPhrases.count)]
        for group in requiredPhrases { parts += [String(group.count)] + group }
        return parts + [String(forbiddenPhrases.count)] + forbiddenPhrases
    }

    var isValid: Bool {
        guard key.range(of: "^[a-z][a-z0-9]*(?:[.-][a-z0-9]+)*$", options: .regularExpression) != nil,
              key.count <= 80, (1...8).contains(requiredPhrases.count), forbiddenPhrases.count <= 32 else { return false }
        func validPhrase(_ phrase: String) -> Bool {
            let normalized = Self.normalize(phrase)
            return phrase == phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                && !phrase.contains("\n") && !normalized.isEmpty && phrase.count <= 120
                && normalized.split(separator: " ").count <= 8
        }
        guard requiredPhrases.allSatisfy({ (1...8).contains($0.count) && $0.allSatisfy(validPhrase) }),
              forbiddenPhrases.allSatisfy(validPhrase) else { return false }
        let required = requiredPhrases.flatMap { $0 }.map(Self.normalize)
        let forbidden = forbiddenPhrases.map(Self.normalize)
        return Set(required).count == required.count && Set(forbidden).count == forbidden.count
    }

    func matches(_ question: String) -> Bool {
        let normalized = " " + Self.normalize(question) + " "
        func contains(_ phrase: String) -> Bool { normalized.contains(" " + Self.normalize(phrase) + " ") }
        guard !forbiddenPhrases.contains(where: contains),
              requiredPhrases.allSatisfy({ $0.contains(where: contains) }) else { return false }
        // A negative question needs an explicitly reviewed negative route;
        // positive topic words cannot silently reverse the requested behavior.
        if Self.hasNegation(question) {
            guard requiredPhrases.flatMap({ $0 }).contains(where: { contains($0) && Self.hasNegation($0) }) else { return false }
        }
        return true
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func hasNegation(_ text: String) -> Bool {
        text.range(of: "\\b(?:not|never|without|cannot|can['’]t|don['’]t|doesn['’]t|won['’]t|avoid)\\b",
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func containsQuotedQuestion(_ text: String) -> Bool {
        let patterns = ["[\"“]([^\"”]+)[\"”]", "(?:^|\\s)'([^']+)'(?=\\s|[.,!?;:]|$)", "‘([^’]+)’"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let quoted = String(text[range]), normalized = normalize(quoted)
                if quoted.contains("?") || ["ignore ", "select ", "output ", "answer "].contains(where: normalized.hasPrefix) { return true }
            }
        }
        return false
    }
}

enum ReviewedQuestionRequirement: Equatable {
    case matched(key: String, category: ReviewedScopeCategory, forms: Set<ReviewedQuestionForm>)
    case ambiguous
}
