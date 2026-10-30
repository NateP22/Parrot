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
            let rawClause = String(question[wordRange.lowerBound..<end])
            let clause = ReviewedQuestionScope.normalize(rawClause)
            let first = clause.split(separator: " ").first.map(String.init) ?? ""
            let conditionalStill = (first == "will" || first == "would")
                && hasHypotheticalControlAntecedent(in: question, before: wordRange.lowerBound)
            // A relative qualifier can contain a wh-word too. It must not
            // turn an owned input's availability into a general capability.
            var relativeQualifier = false
            if index + 1 < matches.count,
               let nextRange = Range(matches[index + 1].range, in: question) {
                let next = ReviewedQuestionScope.normalize(String(question[nextRange]))
                let separate = rawClause.range(of: "(?:[.!?;]|\\b(?:and|or|but|also|then|so))\\s*[,;:]?\\s*$",
                    options: [.regularExpression, .caseInsensitive]) != nil
                relativeQualifier = ["which", "who", "whose", "where", "when"].contains(next) && !separate
            }
            if requestsClientState(clause, allowsConditionalStill: conditionalStill,
                                   allowsOwnedStyleInput: !relativeQualifier) {
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
    private static func requestsClientState(_ clause: String, allowsConditionalStill: Bool,
                                           allowsOwnedStyleInput: Bool) -> Bool {
        // "Selected" is part of this command label, not evidence about the
        // user's current selection. Other state words and clauses still count.
        var stateClause = clause.replacingOccurrences(of: "\\bimport selected\\b",
            with: "import command", options: .regularExpression)
        func matches(_ pattern: String) -> Bool {
            stateClause.range(of: pattern, options: .regularExpression) != nil
        }
        // Instructions can mention "my document" without asserting its state.
        if ["how do i ", "how do we ", "how can i ", "how can we ", "how to "]
            .contains(where: clause.hasPrefix) { return false }
        // A generic input class ("already imported records") does not assert
        // that this client's records were imported. Mask only that adjective;
        // another temporal cue, owned file or later question still needs state.
        if matches("^(?:(?:does|do|will|would)\\b|how (?:does|do)\\b|what (?:does|do|happens)\\b|when (?:does|do)\\b)"),
           !matches("\\b(?:selected|assigned|configured|current|last|latest|previous|prior|was|were|did|has|have|had|yesterday|today|ago|previously|earlier)\\b") {
            stateClause = stateClause.replacingOccurrences(
                of: "\\b((?:replace|re place|import|reimport|process|reprocess|handle|overwrite|update|export|format|skip|affect|happens to)(?: [a-z0-9]+){0,3}) already (placed|imported|processed|saved|formatted|published|exported|printed) (items|records|stories|articles|files|documents|images|photos|frames)\\b",
                with: "$1 $2 $3", options: .regularExpression)
        }
        // A help article cannot establish present availability or completion.
        if matches("\\b(?:now|currently|already|yet|anymore)\\b") { return true }
        if matches("\\bstill\\b"), !allowsConditionalStill
            || matches("\\b(?:available|enabled|disabled|active|inactive|running|configured|selected|assigned|connected|installed)\\b") { return true }
        // Only a complete generic role-mapping request can use this operand
        // exception. Free-form complements can hide an actual account or file.
        let genericRoleUse = "^(?:can|could) (?:i|we) (?:map|assign|choose) (?:my|our) own (?:(?:document|paragraph|character|text|custom) ){0,2}styles"
            + "(?: (?:to|for) (?:(?:both|each|all)(?: (?:text )?roles?)?|(?:one|two|three|four|multiple|separate|different|individual|[0-9]+) (?:text )?roles?))?$"
        if allowsOwnedStyleInput,
           matches(genericRoleUse),
           !matches("\\b(?:that|which|who|whose|where|when|selected|assigned|configured|current|mapped|last|latest|previous|prior|was|were|did|has|have|had|yesterday|today|ago|previously|earlier)\\b") {
            stateClause = stateClause.replacingOccurrences(
                of: "\\b(?:my|our) own (?:(?:document|paragraph|character|text|custom) ){0,2}styles\\b",
                with: "style inputs", options: .regularExpression)
        }
        // Ownership anywhere in a non-procedure clause can make a general
        // capability question an account entitlement or current-file question.
        if matches("\\b(?:my|our|your|their|this|that) (?:[a-z0-9]+ ){0,4}(?:account|workspace|file|document|publication|project|budget|selection|styles|images|photos)\\b") { return true }
        if matches("^(?:does|do|will|would|can|could|may|might|is|are|should) (?:my|our|your|their|this|that|these|those)\\b") { return true }
        if matches("^(?:is|are|does|do|will|would) the (?:[a-z0-9]+ ){0,8}(?:file|document|account|publication|project|budget)\\b") { return true }
        if matches("^(?:is|are)\\b"),
           matches("\\b(?:enabled|disabled|active|inactive|on|off|running|configured|selected|connected|installed)\\b") { return true }
        if matches("^(?:how|what|which|where|who|whom|whose|why|when)\\b"),
           matches("\\b(?:did|has|have|had|was|were|now|currently|already|last|latest|selected|assigned|configured)\\b") { return true }
        // A main-clause state predicate asks about actual availability. An
        // adjective in "what does an enabled control do" or a general "when"
        // condition describes behavior and must keep its question form.
        let words = stateClause.split(separator: " ").map(String.init)
        let statePredicates: Set<String> = ["enabled", "disabled", "active", "inactive",
            "running", "connected", "installed"]
        let behaviorWords: Set<String> = ["does", "do", "happens", "can", "could", "may",
            "might", "will", "would", "should", "if", "when", "while"]
        if matches("^(?:what|which|where|who|whom|whose|why)\\b"),
           let copula = words.firstIndex(where: { $0 == "is" || $0 == "are" }),
           !words[..<copula].contains(where: { behaviorWords.contains($0) }),
           words.dropFirst(copula + 1).contains(where: { statePredicates.contains($0) })
            || matches("\\b(?:turned|switched) (?:on|off)\\b") { return true }
        return false
    }

    /// Context belongs only to the immediately attached consequence, never a
    /// subsequent question. A factual or unrelated "if" is not an exemption.
    private static func hasHypotheticalControlAntecedent(in question: String,
                                                        before position: String.Index) -> Bool {
        let prefix = String(question[..<position])
        let pattern = "(?:^|[.!?;])\\s*if\\s+([^.!?;]+?),\\s*(?:then\\s*)?$"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)),
              let range = Range(match.range(at: 1), in: prefix) else { return false }
        let premise = ReviewedQuestionScope.normalize(String(prefix[range]))
        func matches(_ pattern: String) -> Bool {
            premise.range(of: pattern, options: .regularExpression) != nil
        }
        // Require a setting/value relation, not merely an action such as
        // leaving home. "Set" can also describe the past, so retain time cues.
        let settingsContext = "(?:(?: in| under| within) (?:[a-z0-9]+ ){0,4}(?:settings|options|panel|dialog|controls))?"
        let blankSetting = matches("^(?:i|we|you) (?:leave|set) (?:[a-z0-9]+ ){1,8}(?:blank|empty)" + settingsContext + "$")
        let switchSetting = matches("^(?:i|we|you) (?:turn|set|leave) (?:[a-z0-9]+ ){1,8}(?:on|off)" + settingsContext + "$")
        guard blankSetting || switchSetting,
              !matches("\\b(?:now|currently|already|yet|still|last|latest|previous|prior|yesterday|today|ago|previously|earlier|did|has|have|had|was|were|selected|assigned|configured)\\b"),
              !matches("\\b(?:in|on|since|before|after) [0-9]{4}\\b"),
              !matches("\\b(?:account|workspace|subscription|license|entitlement)\\b"),
              !matches("\\b(?:my|our|your|their|this|that) (?:[a-z0-9]+ ){0,4}(?:file|document|publication|project|budget|selection|styles|images|photos)\\b") else { return false }
        return true
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
        // Reviewed synonyms expand one topic; AND groups and phrase bounds stay fixed.
        guard requiredPhrases.allSatisfy({ (1...16).contains($0.count) && $0.allSatisfy(validPhrase) }),
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
