import Foundation

enum QASetupChecks {
    static func run(_ check: (String, Bool) -> Void) {
        let qa = "com.uygar.parrot.sat54.qa"
        func mode(_ args: [String], _ id: String? = qa, _ flag: Any? = true,
                  boot: Any? = nil, next: Any? = nil) -> QASetupLaunch.Decision {
            QASetupLaunch.decision(arguments: ["Parrot"]+args, bundleID: id, flag: flag,
                                   defaultFlag: boot, nextLaunch: next)
        }
        check("QA setup absent preserves normal QA launch", mode([]) == .normal)
        check("QA setup absent preserves production CLI", mode(["--profile-test"], "com.uygar.parrot", nil) == .normal)
        check("QA setup exact typed admission opens settings only", mode(["--qa-setup"]) == .settingsOnly)
        check("QA setup production identity refuses", mode(["--qa-setup"],"com.uygar.parrot") == .rejected)
        check("QA setup similar identity refuses", mode(["--qa-setup"],qa+".other") == .rejected)
        check("QA setup missing identity refuses", mode(["--qa-setup"],nil) == .rejected)
        check("QA setup false flag refuses", mode(["--qa-setup"],qa,false) == .rejected)
        check("QA setup missing flag refuses", mode(["--qa-setup"],qa,nil) == .rejected)
        check("QA setup numeric one flag refuses", mode(["--qa-setup"],qa,NSNumber(value:1)) == .rejected)
        check("QA setup string flag refuses", mode(["--qa-setup"],qa,"true") == .rejected)
        check("QA setup cannot mix capture CLI", mode(["--qa-setup","--capture-test"]) == .rejected)
        check("QA setup cannot mix another harness", mode(["--qa-setup","--profile-test"]) == .rejected)
        check("QA setup duplicate mode refuses", mode(["--qa-setup","--qa-setup"]) == .rejected)
        check("QA setup unknown option refuses", mode(["--qa-setup","--other"]) == .rejected)
        check("QA setup self-check requires setup flag", mode(["--qa-setup-self-check"]) == .rejected)
        check("QA setup exact bundled self-check allowed", mode(["--qa-setup","--qa-setup-self-check"]) == .settingsOnly)
        check("QA setup self-check cannot mix recording", mode(["--qa-setup","--qa-setup-self-check","--capture-test"]) == .rejected)
        check("QA first GUI boot defaults to lightweight setup", mode([],boot:true) == .settingsOnly)
        check("QA first GUI boot handles native launch argument", mode(["-psn_0_1"],boot:true) == .settingsOnly)
        check("QA setup default refuses a model-capable CLI", mode(["--profile-test"],boot:true) == .rejected)
        check("QA production cannot use setup GUI default", mode([],"com.uygar.parrot",true,boot:true) == .normal)
        check("QA malformed GUI default refuses before model startup", mode([],boot:NSNumber(value:1)) == .rejected)
        check("QA saved next normal launch uses meeting mode", mode([],boot:true,next:false) == .normal)
        check("QA saved next setup launch remains lightweight", mode([],boot:true,next:true) == .settingsOnly)
        check("QA malformed next preference stays lightweight", mode([],boot:true,next:NSNumber(value:0)) == .settingsOnly)
        for owner in ["speech", "speakers", "local", "embedding"] {
            check("QA setup permits isolated owner probe " + owner,
                  mode(["--qa-setup","--qa-setup-self-check",owner]) == .settingsOnly)
        }
        check("QA owner probe refuses unknown owner", mode(["--qa-setup","--qa-setup-self-check","other"]) == .rejected)
        check("QA unknown flag cannot fall through to meeting GUI", mode(["--unexpected"],boot:true) == .rejected)
        check("QA dangling harness cannot fall through to meeting GUI", mode(["--snapshot"],boot:true) == .rejected)
        check("QA setup default allows model-free query probe", mode(["--query-startup-test"],boot:true) == .settingsOnly)
        check("QA chosen normal launch preserves ordinary CLI", mode(["--profile-test"],boot:true,next:false) == .normal)
    }
}
