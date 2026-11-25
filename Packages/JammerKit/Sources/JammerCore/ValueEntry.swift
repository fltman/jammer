import Foundation

/// A value typed beside a slider (COMFORT 17): read as people write it, in either language. nil when it isn't one.
public enum ValueEntry {
    /// A number with a comma or a point, a typographic minus or a plus, and a unit or a side letter around it.
    static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespaces)
        let digits = t.filter { "0123456789.-+".contains($0) }
        guard !digits.isEmpty, digits != "-", digits != "+" else { return nil }
        return Double(digits)
    }

    /// A level in dB ("-3", "−3,5 dB", "+2"), kept within `range`.
    public static func decibels(_ s: String, range: ClosedRange<Double> = -60...12) -> Double? {
        number(s).map { min(range.upperBound, max(range.lowerBound, ($0 * 10).rounded() / 10)) }
    }

    /// A pan from −1 (left) to 1 (right): "-30" or "L 30" / "V 30" for left, "R 30" / "H 30" for right, "C" or "M"
    /// for the middle; the numbers are percent.
    public static func pan(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        if ["C", "M", "0"].contains(t) || t.hasPrefix("CENT") || t.hasPrefix("MITT") { return 0 }
        guard let n = number(t) else { return nil }
        let left = t.hasPrefix("L") || t.hasPrefix("V")
        let v = (left ? -abs(n) : (t.hasPrefix("R") || t.hasPrefix("H")) ? abs(n) : n) / 100
        return min(1, max(-1, (v * 100).rounded() / 100))
    }
}
