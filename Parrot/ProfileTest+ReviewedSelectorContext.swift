import Foundation
enum ReviewedSelectorContextChecks {
    static func run(_ check:(String,Bool)->Void) {
        func make(_ mode:ReviewedSelectorContext.Mode,_ h:String,_ p:String,_ q:String="Current question?")->ReviewedSelectorContext.Window {
            ReviewedSelectorContext.window(mode:mode,history:h,previous:p,question:q)
        }
        func count(_ text:String,_ value:String)->Int { text.components(separatedBy:value).count-1 }
        let isolated=make(.isolated,"EARLIER_HISTORY","FIXTURE_PREVIOUS")
        check("selector context isolated is question-only",isolated.transcript=="Them: Current question?")
        let equal=make(.rolling,"Earlier question?","Earlier question?")
        check("selector context equal prior field is not duplicated",count(equal.transcript,"Earlier question?")==1)
        check("selector context rolling history stays free of injected speaker labels",equal.nextHistory=="Earlier question? Current question?")
        let extends=make(.rolling,"One?","One? Two?")
        check("selector context explicit prior can extend history once",extends.transcript=="One? Two?\nThem: Current question?")
        let contains=make(.rolling,"One? Two?","One?")
        check("selector context history retains contained prior once",contains.transcript=="One? Two?\nThem: Current question?")
        let overlap=make(.rolling,"One? Two?","Two? Three?")
        check("selector context suffix-prefix overlap appears once",overlap.transcript=="One? Two? Three?\nThem: Current question?")
        let unrelated=make(.rolling,"One?","Unrelated condition.")
        check("selector context unrelated explicit condition is preserved",unrelated.transcript=="One? Unrelated condition.\nThem: Current question?")
        let whitespace=make(.rolling,"Earlier question?","Earlier\nquestion?")
        check("selector context whitespace variants do not duplicate prior",count(whitespace.transcript,"Earlier question?")==1 && !whitespace.transcript.contains("Earlier\nquestion?"))
        let negative=make(.rolling,"I know.","no")
        check("selector context never drops negation as a word substring",negative.transcript=="I know. no\nThem: Current question?")
        let repeated=make(.rolling,"Repeated?","","Repeated?")
        check("selector context intentionally repeated current question remains",count(repeated.transcript,"Repeated?")==2 && count(repeated.nextHistory,"Repeated?")==2)
        let blank=make(.rolling,"","","Current question?")
        check("selector context blank prior still asks newest question",blank.transcript=="Them: Current question?")
        let bounded=make(.rolling,String(repeating:"long history ",count:1000),"","Newest question?")
        check("selector context window is bounded and ends with newest question",bounded.transcript.count<=2500 && bounded.transcript.hasSuffix("Them: Newest question?"))
    }
}
