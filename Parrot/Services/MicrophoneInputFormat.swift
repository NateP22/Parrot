import Foundation

/// Real-device capture uses the input hardware's format without conversion.
/// Keep this pure so invalid hardware can be checked without opening a tap.
enum MicrophoneInputFormat {
    static func hasInputChannels(_ channelCounts: [UInt32]) -> Bool {
        channelCounts.contains { $0 > 0 }
    }

    static func isUsable(hardwareRate: Double, hardwareChannels: UInt32,
                         tapRate: Double, tapChannels: UInt32) -> Bool {
        hardwareRate.isFinite && hardwareRate > 0 && hardwareChannels > 0
            && tapRate.isFinite && tapRate > 0 && tapChannels > 0
            && hardwareRate == tapRate && hardwareChannels == tapChannels
    }
}
