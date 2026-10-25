import Foundation

struct Modifiers: OptionSet, Equatable {
    let rawValue: UInt64
    static let capsLock = Modifiers(rawValue: 1 << 16)
    static let shift = Modifiers(rawValue: 1 << 17)
    static let control = Modifiers(rawValue: 1 << 18)
    static let option = Modifiers(rawValue: 1 << 19)
    static let command = Modifiers(rawValue: 1 << 20)
    static let function = Modifiers(rawValue: 1 << 23)
    static let relevant: Modifiers = [.shift, .control, .option, .command]
}

enum KeyPhase { case down, up, flags }

struct KeyInput {
    var code: UInt16
    var phase: KeyPhase
    var modifiers: Modifiers
    var repeatKey = false
    var timestamp: UInt64 = 0
}

struct ShortcutOptions {
    var common = true
    var browser = true
    var navigation = false
    var inputSwitch = false
    var shiftInputSwitch = true
    var capsLockCase = true
}

enum KeyTextCase { case uppercase, lowercase }

struct KeyDecision {
    var code: UInt16
    var modifiers: Modifiers
    var consume = false
    var switchInput = false
    var textCase: KeyTextCase?
}

/// Pure state machine. No permission checks, disk I/O, app discovery or UI work here.
final class ShortcutEngine {
    private struct Rule {
        let sourceCode: UInt16
        let sourceModifiers: Modifiers
        let targetCode: UInt16
        let targetModifiers: Modifiers
    }

    private static let commonRules: [Rule] = {
        let plain: [UInt16] = [0, 1, 3, 6, 7, 8, 9, 13, 31, 35, 45]
        let shifted: [UInt16] = [1, 3, 6, 13, 45]
        return plain.map { Rule(sourceCode: $0, sourceModifiers: .control, targetCode: $0, targetModifiers: .command) } +
            shifted.map { Rule(sourceCode: $0, sourceModifiers: [.control, .shift], targetCode: $0, targetModifiers: [.command, .shift]) } +
            [Rule(sourceCode: 16, sourceModifiers: .control, targetCode: 6, targetModifiers: [.command, .shift])]
    }()

    private static let browserRules: [Rule] = {
        let plain: [UInt16] = [15, 17, 24, 27, 29, 37, 18, 19, 20, 21, 22, 23, 25, 26, 28]
        let shifted: [UInt16] = [15, 17, 24]
        return plain.map { Rule(sourceCode: $0, sourceModifiers: .control, targetCode: $0, targetModifiers: .command) } +
            shifted.map { Rule(sourceCode: $0, sourceModifiers: [.control, .shift], targetCode: $0, targetModifiers: [.command, .shift]) }
    }()

    private static let navigationRules: [Rule] = {
        [false, true].flatMap { shift -> [Rule] in
            let source: Modifiers = shift ? [.control, .shift] : .control
            let word: Modifiers = shift ? [.option, .shift] : .option
            let document: Modifiers = shift ? [.command, .shift] : .command
            return [UInt16(123), 124, 51, 117].map {
                Rule(sourceCode: $0, sourceModifiers: source, targetCode: $0, targetModifiers: word)
            } + [Rule(sourceCode: 115, sourceModifiers: source, targetCode: 126, targetModifiers: document),
                 Rule(sourceCode: 119, sourceModifiers: source, targetCode: 125, targetModifiers: document)]
        }
    }()

    private struct PressedMapping {
        let code: UInt16
        let replacement: Modifiers?
        let consume: Bool
    }
    private var pressed: [UInt16: PressedMapping] = [:]
    private var heldKeys: Set<UInt16> = []
    private var shiftWasDown = false
    private var shiftTap: (code: UInt16, timestamp: UInt64)?
    var hasHeldMappings: Bool { !pressed.isEmpty }

    func cancelShiftTap() { shiftTap = nil }

    func reset() {
        // Key-up pairing survives foreground changes via process(), rather than reset().
        pressed.removeAll()
        heldKeys.removeAll()
        shiftWasDown = false
        cancelShiftTap()
    }

    func process(_ input: KeyInput, options: ShortcutOptions, active: Bool) -> KeyDecision {
        var key = input
        if active && !options.capsLockCase { key.modifiers.remove(.capsLock) }
        var result = KeyDecision(code: key.code, modifiers: key.modifiers)
        let relevant = key.modifiers.intersection(.relevant)
        if active, input.modifiers.contains(.capsLock), relevant.isEmpty,
           key.phase != .flags {
            result.textCase = options.capsLockCase ? .uppercase : .lowercase
        }
        result.switchInput = trackShiftTap(key, options: options, active: active)

        if key.phase == .flags { return result }

        // Pair key-up/repeat with its original key-down even after focus/option changes.
        if let mapping = pressed[key.code] {
            if key.phase == .up { pressed.removeValue(forKey: key.code) }
            result.code = mapping.code
            result.consume = mapping.consume
            if let replacement = mapping.replacement {
                result.modifiers.remove([.control, .option, .command])
                result.modifiers.formUnion(replacement)
            }
            return result
        }

        guard key.phase == .down, active else { return result }

        // Replacement, not an extra alias: swallow only Command targets of enabled rules.
        // Events returned by our tap are forwarded downstream, never processed here twice.
        let replacesCommand = relevant.contains(.command) && (
            (options.common && Self.commonRules.contains { $0.targetCode == key.code && $0.targetModifiers == relevant }) ||
            (options.browser && Self.browserRules.contains { $0.targetCode == key.code && $0.targetModifiers == relevant }) ||
            (options.navigation && Self.navigationRules.contains { $0.targetCode == key.code && $0.targetModifiers == relevant }))
        if replacesCommand {
            result.consume = true
            pressed[key.code] = PressedMapping(code: key.code, replacement: nil, consume: true)
            return result
        }

        if options.inputSwitch, key.code == 49, relevant == .control {
            result.consume = true
            result.switchInput = !key.repeatKey
            pressed[key.code] = PressedMapping(code: key.code, replacement: nil, consume: true)
            return result
        }

        // Both the new chord and its disabled original are derived from the same rules.
        let rule = (options.common ? Self.commonRules.first { $0.sourceCode == key.code && $0.sourceModifiers == relevant } : nil) ??
                   (options.browser ? Self.browserRules.first { $0.sourceCode == key.code && $0.sourceModifiers == relevant } : nil) ??
                   (options.navigation ? Self.navigationRules.first { $0.sourceCode == key.code && $0.sourceModifiers == relevant } : nil)
        if let rule {
            return mapped(key, to: rule.targetCode, replacement: rule.targetModifiers)
        }
        return result
    }

    private func trackShiftTap(_ key: KeyInput, options: ShortcutOptions, active: Bool) -> Bool {
        let shiftDown = key.modifiers.contains(.shift)
        defer { shiftWasDown = shiftDown }
        if !active || !options.shiftInputSwitch { cancelShiftTap() }

        if key.phase != .flags {
            if key.phase == .down { heldKeys.insert(key.code) }
            else { heldKeys.remove(key.code) }
            cancelShiftTap()
            return false
        }

        guard key.code == 56 || key.code == 60 else {
            cancelShiftTap()
            return false
        }
        let modifiers = key.modifiers.intersection(Modifiers.relevant.union(.function))
        if shiftDown && !shiftWasDown {
            if active && options.shiftInputSwitch && modifiers == .shift && heldKeys.isEmpty {
                shiftTap = (key.code, key.timestamp)
            }
            return false
        }
        if !shiftDown && shiftWasDown {
            let tap = shiftTap
            cancelShiftTap()
            // CGEvent timestamps are monotonic nanoseconds. Long holds are ordinary Shift.
            return active && options.shiftInputSwitch && modifiers.isEmpty &&
                tap?.code == key.code && tap.map {
                    key.timestamp >= $0.timestamp && key.timestamp - $0.timestamp <= 500_000_000
                } == true
        }
        // Two Shift keys together are a chord, even while the aggregate Shift flag stays set.
        cancelShiftTap()
        return false
    }

    private func mapped(_ key: KeyInput, to code: UInt16, replacement: Modifiers) -> KeyDecision {
        pressed[key.code] = PressedMapping(code: code, replacement: replacement, consume: false)
        var flags = key.modifiers
        flags.remove([.control, .option, .command, .shift])
        flags.formUnion(replacement)
        return KeyDecision(code: code, modifiers: flags)
    }
}
