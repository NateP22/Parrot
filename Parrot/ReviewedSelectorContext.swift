import Foundation

/// Diagnostic fixture context only; never changes live meeting selection.
enum ReviewedSelectorContext {
    enum Mode:String { case isolated,rolling }
    struct Window { let transcript:String;let nextHistory:String }
    static func window(mode:Mode,history:String,previous:String,question:String) -> Window {
        let context=mode == .rolling ? merged(history:history,previous:previous) : ""
        let transcript=String([context,"Them: "+question].filter{!$0.isEmpty}.joined(separator:"\n").suffix(2500))
        let next=String([context,question].filter{!$0.isEmpty}.joined(separator:" ").suffix(2500))
        return Window(transcript:transcript,nextHistory:next)
    }
    /// Collapse spacing only in historical context. Whole-token containment and
    /// suffix/prefix overlap avoid repeating fixture-supplied history. The new
    /// question is always appended, even when it was intentionally asked again.
    private static func merged(history:String,previous:String) -> String {
        func normalize(_ text:String)->String { text.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ") }
        let before=normalize(history),explicit=normalize(previous)
        if before.isEmpty { return explicit }
        if explicit.isEmpty { return before }
        if (" "+before+" ").contains(" "+explicit+" ") { return before }
        if (" "+explicit+" ").contains(" "+before+" ") { return explicit }
        let oldWords=before.split(separator:" "),newWords=explicit.split(separator:" ")
        for size in stride(from:min(oldWords.count,newWords.count),through:1,by:-1) {
            if oldWords.suffix(size).elementsEqual(newWords.prefix(size)) {
                return (oldWords+newWords.dropFirst(size)).joined(separator:" ")
            }
        }
        return before+" "+explicit
    }
}
