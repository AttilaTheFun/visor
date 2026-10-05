// Numbers off the wire as whole ones. A JSON number is a Double, and
// `Int(_: Double)` traps on one it cannot hold: on a 32-bit platform (the
// web's wasm32, where `Int` is 32 bits) that is anything past two billion,
// which a count of tokens passes. Nothing read from the wire may trap.

extension FixedWidthInteger {
    /// `value` as a whole number, whatever it is: its whole part where
    /// that fits, the nearest end where it is past one, and 0 for what is
    /// not a number.
    public init(whole value: Double) {
        if let exact = Self(exactly: value.rounded(.towardZero)) {
            self = exact
        } else if value.isNaN {
            self = 0
        } else {
            self = value < 0 ? .min : .max
        }
    }
}
