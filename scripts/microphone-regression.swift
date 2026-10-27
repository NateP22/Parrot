import Foundation

var failures = 0
func check(_ name: String, hardwareRate: Double = 44_100, hardwareChannels: UInt32 = 1,
           tapRate: Double = 44_100, tapChannels: UInt32 = 1, expected: Bool) {
    let actual = MicrophoneInputFormat.isUsable(
        hardwareRate: hardwareRate, hardwareChannels: hardwareChannels,
        tapRate: tapRate, tapChannels: tapChannels)
    if actual == expected { print("PASS \(name)") }
    else { print("FAIL \(name): expected \(expected), got \(actual)"); failures += 1 }
}
check("valid mono 44.1k", expected: true)
check("valid stereo 48k", hardwareRate: 48_000, hardwareChannels: 2,
      tapRate: 48_000, tapChannels: 2, expected: true)
check("missing hardware with plausible tap format", hardwareRate: 0, hardwareChannels: 0,
      tapRate: 44_100, tapChannels: 2, expected: false)
check("zero hardware rate", hardwareRate: 0, expected: false)
check("zero hardware channels", hardwareChannels: 0, expected: false)
check("negative hardware rate", hardwareRate: -1, expected: false)
check("NaN hardware rate", hardwareRate: .nan, expected: false)
check("infinite hardware rate", hardwareRate: .infinity, expected: false)
check("zero tap rate", tapRate: 0, expected: false)
check("zero tap channels", tapChannels: 0, expected: false)
check("negative tap rate", tapRate: -1, expected: false)
check("NaN tap rate", tapRate: .nan, expected: false)
check("infinite tap rate", tapRate: .infinity, expected: false)
check("hardware and tap rate mismatch", tapRate: 48_000, expected: false)
check("hardware and tap channel mismatch", tapChannels: 2, expected: false)
if failures > 0 { print("\(failures) failures"); exit(1) }
print("ALL PASS: 15 microphone format checks")
