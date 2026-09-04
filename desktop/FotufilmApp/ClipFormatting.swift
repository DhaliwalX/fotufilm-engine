import Foundation

/// Clock time for a playhead or a duration, the way both apps' scrubbers print it.
func clockString(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    let rounded = Int(seconds.rounded())
    let hours = rounded / 3600
    let minutes = (rounded % 3600) / 60
    let remainder = rounded % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%d:%02d", minutes, remainder)
}

func frameRateString(_ rate: Double) -> String {
    guard rate > 0 else { return "Variable fps" }
    return rate.rounded() == rate
        ? "\(Int(rate)) fps"
        : String(format: "%.2f fps", rate)
}
