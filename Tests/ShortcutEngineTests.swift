import Foundation
import CoreGraphics

@main
enum ShortcutEngineTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        count += 1
        guard condition() else { fatalError("FAILED: \(name)") }
    }

    static func main() {
        let options = ShortcutOptions()
        func input(_ code: UInt16, _ modifiers: Modifiers, _ phase: KeyPhase = .down,
                   repeatKey: Bool = false, timestamp: UInt64 = 0) -> KeyInput {
            KeyInput(code: code, phase: phase, modifiers: modifiers, repeatKey: repeatKey, timestamp: timestamp)
        }

        // Every advertised letter is verified against an explicit expected macOS shortcut.
        for code: UInt16 in [0, 1, 3, 6, 7, 8, 9, 13, 31, 35, 45, 15, 17, 37] {
            let engine = ShortcutEngine()
            let result = engine.process(input(code, .control), options: options, active: true)
            check(result.code == code && result.modifiers == .command && !result.consume,
                  "Ctrl key \(code) maps to Command")
        }

        let redo = ShortcutEngine().process(input(16, .control), options: options, active: true)
        check(redo.code == 6 && redo.modifiers == [.command, .shift], "Ctrl+Y redo")

        for code: UInt16 in [1, 3, 6, 13, 45, 15, 17, 24] {
            let result = ShortcutEngine().process(input(code, [.control, .shift]), options: options, active: true)
            check(result.modifiers == [.command, .shift], "Explicit Ctrl+Shift shortcut \(code)")
        }

        for modifiers: Modifiers in [[.control, .option], [.control, .command], [.command, .option], [.option], []] {
            let result = ShortcutEngine().process(input(8, modifiers), options: options, active: true)
            check(result.modifiers == modifiers && !result.consume, "Extra modifiers pass through")
        }
        for code: UInt16 in [0, 1, 3, 6, 7, 8, 9, 13, 31, 35, 45, 15, 17, 24, 27, 29, 37, 18, 19, 20, 21, 22, 23, 25, 26, 28] {
            let result = ShortcutEngine().process(input(code, .command), options: options, active: true)
            check(result.consume, "Corresponding Command shortcut \(code) disabled")
        }
        for code: UInt16 in [1, 3, 6, 13, 45, 15, 17, 24] {
            let result = ShortcutEngine().process(input(code, [.command, .shift]), options: options, active: true)
            check(result.consume, "Corresponding Command+Shift shortcut \(code) disabled")
        }
        for code: UInt16 in [12, 40] {
            let result = ShortcutEngine().process(input(code, .command), options: options, active: true)
            check(!result.consume && result.modifiers == .command, "Unrelated Command shortcut \(code) untouched")
        }
        let blocked = ShortcutEngine()
        check(blocked.process(input(8, .command), options: options, active: true).consume, "Native copy down blocked")
        check(blocked.process(input(8, [], repeatKey: true), options: options, active: false).consume,
              "Blocked repeat remains swallowed after pause/focus/modifier changes")
        check(blocked.process(input(8, [], .up), options: options, active: false).consume,
              "Blocked key-up remains swallowed after pause/focus/modifier changes")
        check(!blocked.hasHeldMappings, "Blocked key release clears tracking")
        check(!blocked.process(input(8, .command), options: options, active: false).consume,
              "New Command shortcut restored when paused/excluded")
        let unknown = ShortcutEngine().process(input(40, .control), options: options, active: true)
        check(unknown.modifiers == .control, "Ctrl+K left untouched")
        let shiftC = ShortcutEngine().process(input(8, [.control, .shift]), options: options, active: true)
        check(shiftC.modifiers == [.control, .shift], "Unlisted Ctrl+Shift+C untouched")

        let paused = ShortcutEngine().process(input(8, .control), options: options, active: false)
        check(paused.modifiers == .control, "Disabled/excluded app passes Ctrl+C through")
        let caps = Modifiers(rawValue: 1 << 16)
        let capsResult = ShortcutEngine().process(input(8, [.control, caps]), options: options, active: true)
        check(capsResult.modifiers == [.command, caps], "Caps Lock preserved")
        check(ShortcutEngine().process(input(8, [.command, caps]), options: options, active: true).consume,
              "Caps Lock does not bypass Command blocking")

        let pairing = ShortcutEngine()
        _ = pairing.process(input(16, .control), options: options, active: true)
        let repeatResult = pairing.process(input(16, .control, repeatKey: true), options: options, active: false)
        check(repeatResult.code == 6, "Repeat stays paired after focus changes")
        let release = pairing.process(input(16, [], .up), options: options, active: false)
        check(release.code == 6 && release.modifiers == [.command, .shift], "Key-up remains paired after Ctrl release/pause")
        check(!pairing.hasHeldMappings, "Key-up clears mapping")

        for modifier: Modifiers in [.command, .option, .control] {
            for shifted in [false, true] {
                let modifiers: Modifiers = shifted ? modifier.union(.shift) : modifier
                let modifierCode: UInt16 = modifier == .command ? 55 : (modifier == .option ? 58 : 59)
                let tab = ShortcutEngine()
                let events = [input(modifierCode, modifier, .flags),
                              input(48, modifiers), input(48, modifiers, repeatKey: true),
                              input(48, modifiers, .up), input(48, modifiers),
                              input(modifierCode, [], .flags), input(48, [], .up)]
                for (index, event) in events.enumerated() {
                    // A foreground change during switching must preserve native release events.
                    let result = tab.process(event, options: options, active: index < 5)
                    check(result.code == event.code && result.modifiers == event.modifiers &&
                          !result.consume && !result.switchInput,
                          "Tab chord and modifier releases pass through unchanged: \(modifiers), event \(index)")
                }
                check(!tab.hasHeldMappings, "Native Tab chords never create remapped keys")
            }
        }

        let tabDuringMapping = ShortcutEngine()
        _ = tabDuringMapping.process(input(16, .control), options: options, active: true)
        _ = tabDuringMapping.process(input(48, .command), options: options, active: true)
        let afterAppSwitch = tabDuringMapping.process(input(16, [], .up), options: options, active: false)
        check(afterAppSwitch.code == 6 && afterAppSwitch.modifiers == [.command, .shift],
              "Native app switching preserves other held key-up pairs")

        let interrupted = ShortcutEngine()
        _ = interrupted.process(input(8, .control), options: options, active: true)
        interrupted.reset()
        check(!interrupted.hasHeldMappings, "Stopping clears held mappings")

        var inputOptions = options
        inputOptions.inputSwitch = true
        let ime = ShortcutEngine()
        let space = ime.process(input(49, .control), options: inputOptions, active: true)
        check(space.consume && space.switchInput, "Ctrl+Space switches exactly once")
        let repeatedSpace = ime.process(input(49, .control, repeatKey: true), options: inputOptions, active: true)
        check(repeatedSpace.consume && !repeatedSpace.switchInput, "Held Ctrl+Space does not cycle repeatedly")
        let spaceUp = ime.process(input(49, [], .up), options: inputOptions, active: false)
        check(spaceUp.consume && !spaceUp.switchInput, "Consumed Space-up paired across pause")
        let defaultSpace = ShortcutEngine().process(input(49, .control), options: options, active: true)
        check(!defaultSpace.consume, "Input-switch feature off leaves Ctrl+Space untouched")

        for code: UInt16 in [56, 60] {
            let shift = ShortcutEngine()
            let down = shift.process(input(code, .shift, .flags, timestamp: 1_000), options: options, active: true)
            check(!down.switchInput && !down.consume && down.modifiers == .shift, "Shift-down remains native \(code)")
            let up = shift.process(input(code, [], .flags, timestamp: 100_001_000), options: options, active: true)
            check(up.switchInput && !up.consume && up.modifiers.isEmpty, "Single left/right Shift switches once on release \(code)")
            check(!shift.process(input(code, [], .flags), options: options, active: true).switchInput,
                  "Repeated release does not switch again")
        }

        let typing = ShortcutEngine()
        _ = typing.process(input(56, .shift, .flags), options: options, active: true)
        let capital = typing.process(input(0, .shift), options: options, active: true)
        check(!capital.consume && capital.modifiers == .shift, "Shift+A still types a capital letter")
        _ = typing.process(input(0, .shift, .up), options: options, active: true)
        check(!typing.process(input(56, [], .flags), options: options, active: true).switchInput,
              "Typing with Shift never switches input")

        let selecting = ShortcutEngine()
        _ = selecting.process(input(56, .shift, .flags), options: options, active: true)
        let selection = selecting.process(input(123, .shift), options: options, active: true)
        check(selection.code == 123 && selection.modifiers == .shift && !selection.consume, "Shift+arrow selection remains native")
        check(!selecting.process(input(56, [], .flags), options: options, active: true).switchInput,
              "Selection with Shift does not toggle language")

        let shortcutShift = ShortcutEngine()
        _ = shortcutShift.process(input(56, .shift, .flags), options: options, active: true)
        _ = shortcutShift.process(input(59, [.control, .shift], .flags), options: options, active: true)
        let saveAs = shortcutShift.process(input(1, [.control, .shift]), options: options, active: true)
        check(saveAs.modifiers == [.command, .shift] && !saveAs.consume, "Ctrl+Shift shortcuts still map normally")
        check(!shortcutShift.process(input(56, [], .flags), options: options, active: true).switchInput,
              "Modifier combinations cancel a Shift tap")

        let alreadyHeld = ShortcutEngine()
        _ = alreadyHeld.process(input(0, []), options: options, active: true)
        _ = alreadyHeld.process(input(56, .shift, .flags), options: options, active: true)
        check(!alreadyHeld.process(input(56, [], .flags), options: options, active: true).switchInput,
              "A key held before Shift prevents a language toggle")

        for other: Modifiers in [.control, .option, .command, .function] {
            let chord = ShortcutEngine()
            _ = chord.process(input(56, [.shift, other], .flags), options: options, active: true)
            check(!chord.process(input(56, other, .flags), options: options, active: true).switchInput,
                  "Shift pressed with another modifier is not a tap")
        }

        let twoShifts = ShortcutEngine()
        _ = twoShifts.process(input(56, .shift, .flags), options: options, active: true)
        _ = twoShifts.process(input(60, .shift, .flags), options: options, active: true)
        _ = twoShifts.process(input(56, .shift, .flags), options: options, active: true)
        check(!twoShifts.process(input(60, [], .flags), options: options, active: true).switchInput,
              "Both Shift keys together do not switch")

        for reason in ["mouse click/scroll", "foreground app change"] {
            let cancelled = ShortcutEngine()
            _ = cancelled.process(input(56, .shift, .flags), options: options, active: true)
            cancelled.cancelShiftTap()
            check(!cancelled.process(input(56, [], .flags), options: options, active: true).switchInput,
                  "\(reason) cancels the pending Shift tap")
            _ = cancelled.process(input(56, .shift, .flags), options: options, active: true)
            check(cancelled.process(input(56, [], .flags), options: options, active: true).switchInput,
                  "A fresh Shift tap works after cancellation")
        }

        for (start, end, expected) in [(UInt64(10), UInt64(500_000_010), true),
                                      (10, 500_000_011, false), (10, 9, false)] {
            let duration = ShortcutEngine()
            _ = duration.process(input(56, .shift, .flags, timestamp: start), options: options, active: true)
            check(duration.process(input(56, [], .flags, timestamp: end), options: options, active: true).switchInput == expected,
                  "Only a short Shift press with a valid timestamp switches input")
        }

        let pausedShift = ShortcutEngine()
        _ = pausedShift.process(input(56, .shift, .flags), options: options, active: true)
        check(!pausedShift.process(input(56, [], .flags), options: options, active: false).switchInput,
              "Pausing or entering an excluded app cancels Shift")
        let startedPaused = ShortcutEngine()
        _ = startedPaused.process(input(56, .shift, .flags), options: options, active: false)
        check(!startedPaused.process(input(56, [], .flags), options: options, active: true).switchInput,
              "Re-enabling during a held Shift cannot switch input")
        var shiftOff = options
        shiftOff.shiftInputSwitch = false
        let disabledShift = ShortcutEngine()
        _ = disabledShift.process(input(56, .shift, .flags), options: options, active: true)
        check(!disabledShift.process(input(56, [], .flags), options: shiftOff, active: true).switchInput,
              "Disabling the Shift option cancels its pending tap")
        let resetShift = ShortcutEngine()
        _ = resetShift.process(input(56, .shift, .flags), options: options, active: true)
        resetShift.reset()
        check(!resetShift.process(input(56, [], .flags), options: options, active: true).switchInput,
              "Stopping/sleep reset cancels the pending tap")

        for flags: Modifiers in [caps, []] {
            let capsEvent = ShortcutEngine().process(input(57, flags, .flags), options: inputOptions, active: true)
            check(!capsEvent.consume && !capsEvent.switchInput && capsEvent.modifiers == flags,
                  "Caps Lock is forwarded unchanged, without an input-source request")
        }
        // All eight configurations must keep case control separate from both input gestures.
        for caseEnabled in [false, true] {
            for shiftEnabled in [false, true] {
                for spaceEnabled in [false, true] {
                    var independent = options
                    independent.capsLockCase = caseEnabled
                    independent.shiftInputSwitch = shiftEnabled
                    independent.inputSwitch = spaceEnabled
                    let engine = ShortcutEngine()
                    let expectedCaps: Modifiers = caseEnabled ? caps : []
                    let capsOn = engine.process(input(57, caps, .flags), options: independent, active: true)
                    check(capsOn.modifiers == expectedCaps && !capsOn.switchInput && !capsOn.consume,
                          "Caps Lock case follows only its own switch")
                    for phase: KeyPhase in [.down, .up] {
                        let letter = engine.process(input(0, caps, phase), options: independent, active: true)
                        check(letter.modifiers == expectedCaps && !letter.consume && !letter.switchInput,
                              "Case setting applies to letter down and up")
                    }
                    _ = engine.process(input(56, [.shift, caps], .flags), options: independent, active: true)
                    let capital = engine.process(input(0, [.shift, caps]), options: independent, active: true)
                    check(capital.modifiers == expectedCaps.union(.shift) && !capital.switchInput,
                          "Shift can type capitals independently of Caps Lock")
                    _ = engine.process(input(0, [.shift, caps], .up), options: independent, active: true)
                    _ = engine.process(input(56, caps, .flags), options: independent, active: true)
                    _ = engine.process(input(56, [.shift, caps], .flags), options: independent, active: true)
                    let shiftUp = engine.process(input(56, caps, .flags), options: independent, active: true)
                    check(shiftUp.switchInput == shiftEnabled && shiftUp.modifiers == expectedCaps,
                          "Shift language switch is independent of Caps Lock and Ctrl+Space")
                    let spaceDown = engine.process(input(49, [.control, caps]), options: independent, active: true)
                    check(spaceDown.switchInput == spaceEnabled && spaceDown.consume == spaceEnabled,
                          "Ctrl+Space language switch is independent of Caps Lock and Shift")
                    _ = engine.process(input(49, [], .up), options: independent, active: true)
                    for event in [input(57, caps, .flags), input(0, caps), input(0, caps, .up)] {
                        let pausedCaps = engine.process(event, options: independent, active: false)
                        check(pausedCaps.modifiers == caps && !pausedCaps.switchInput && !pausedCaps.consume,
                              "Pause/exclusion restores native Caps Lock")
                    }
                    let copy = engine.process(input(8, [.control, caps]), options: independent, active: true)
                    check(copy.modifiers == expectedCaps.union(.command),
                          "Shortcut remapping respects the independent case switch")
                    _ = engine.process(input(8, [], .up), options: independent, active: true)
                    let capsOff = engine.process(input(57, [], .flags), options: independent, active: true)
                    check(capsOff.modifiers.isEmpty && !capsOff.switchInput,
                          "Caps Lock off never triggers a language switch")
                }
            }
        }
        var caseOff = options
        caseOff.capsLockCase = false
        let caseChangedWhileHeld = ShortcutEngine()
        _ = caseChangedWhileHeld.process(input(8, [.control, caps]), options: options, active: true)
        check(caseChangedWhileHeld.process(input(8, caps, .up), options: caseOff, active: true).modifiers == .command,
              "Disabling case while a mapped key is held suppresses Caps Lock on release")
        check(ShortcutEngine().process(input(8, [.command, caps]), options: caseOff, active: true).consume,
              "Disabling case preserves native Command shortcut blocking")
        // A Caps Lock indicator can be on while the event still carries cached lowercase text.
        // Check the delivered text as well as flags; preserving flags alone misses this failure.
        for (modifiers, active, caseEnabled, originalText, expectedText):
            (Modifiers, Bool, Bool, String, String) in [
                (caps, true, true, "a", "A"),
                (caps, true, true, "A", "A"),
                (caps, true, true, "é", "É"),
                (caps, true, true, "你1!", "你1!"),
                (caps, true, false, "A", "a"),
                (caps, false, true, "a", "a"),
                (caps, false, false, "A", "A"),
                ([], true, true, "a", "a"),
                ([caps, .shift], true, true, "a", "a"),
                ([caps, .shift], true, false, "A", "A"),
                ([caps, .control], true, true, "a", "a"),
                ([caps, .command], true, true, "a", "a"),
                ([caps, .option], true, true, "å", "å")
            ] {
            for phase: KeyPhase in [.down, .up] {
                var caseOptions = options
                caseOptions.capsLockCase = caseEnabled
                let key = input(40, modifiers, phase)
                let decision = ShortcutEngine().process(key, options: caseOptions, active: active)
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: phase == .down)!
                event.flags = CGEventFlags(rawValue: modifiers.rawValue)
                let original = Array(originalText.utf16)
                original.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                EventMonitor.apply(decision, to: event, input: key)
                var characters = [UniChar](repeating: 0, count: 16)
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length,
                                               unicodeString: &characters)
                check(String(utf16CodeUnits: characters, count: length) == expectedText,
                      "Caps Lock delivers the selected case despite stale text, respecting pause and chords")
                let expectedFlags = active && !caseEnabled ? modifiers.subtracting(.capsLock) : modifiers
                check(event.flags.rawValue == expectedFlags.rawValue,
                      "Correcting cached case preserves the selected event flags")
            }
        }
        for (modifiers, active, expectedText) in [
            (caps, true, "a"), (caps, false, "A"),
            (caps.union(.shift), true, "A"), (caps.union(.option), true, "A"),
            (caps.union(.command), true, "A")
        ] {
            for phase: KeyPhase in [.down, .up] {
                let key = input(0, modifiers, phase)
                let decision = ShortcutEngine().process(key, options: caseOff, active: active)
                let event = CGEvent(keyboardEventSource: nil, virtualKey: key.code, keyDown: phase == .down)!
                event.flags = CGEventFlags(rawValue: modifiers.rawValue)
                let originalText = Array("A".utf16)
                originalText.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                EventMonitor.apply(decision, to: event, input: key)
                var characters = [UniChar](repeating: 0, count: 8)
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &length,
                                               unicodeString: &characters)
                check(String(utf16CodeUnits: characters, count: length) == expectedText,
                      "Cached event text respects case suppression, Shift, shortcuts and pause")
                check(event.flags.contains(.maskAlphaShift) == !active,
                      "Event Caps Lock flag matches the case decision")
            }
        }
        let capsShift = ShortcutEngine()
        _ = capsShift.process(input(56, [.shift, caps], .flags), options: options, active: true)
        check(capsShift.process(input(56, caps, .flags), options: options, active: true).switchInput,
              "Shift language toggle also works with Caps Lock on")
        let bothInputGestures = ShortcutEngine()
        _ = bothInputGestures.process(input(56, .shift, .flags), options: inputOptions, active: true)
        check(bothInputGestures.process(input(56, [], .flags), options: inputOptions, active: true).switchInput,
              "Shift works with Ctrl+Space enabled")
        check(bothInputGestures.process(input(49, .control), options: inputOptions, active: true).switchInput,
              "Ctrl+Space still switches after a Shift tap")

        let abc = InputSourceDescriptor(id: "ABC", languages: ["en"], isKeyboardLayout: true, isASCIICapable: true)
        let us = InputSourceDescriptor(id: "US", languages: ["en-US"], isKeyboardLayout: true, isASCIICapable: true)
        let pinyin = InputSourceDescriptor(id: "Pinyin", languages: ["zh-Hans"], isASCIICapable: true)
        let zhuyin = InputSourceDescriptor(id: "Zhuyin", languages: ["zh-Hant"])
        let japanese = InputSourceDescriptor(id: "Japanese", languages: ["ja", "en"], isASCIICapable: true)
        let sources = [abc, us, pinyin, zhuyin, japanese]
        check(pinyin.isChinese && !pinyin.isEnglish, "A Chinese IME with ASCII mode is still Chinese")
        check(!japanese.isEnglish, "An unrelated IME with secondary English support is not an English target")
        check(InputSourceSelection.targetID(currentID: "Pinyin", available: sources, lastChineseID: nil, lastEnglishID: nil) == "ABC",
              "Chinese toggles directly to English/ABC")
        check(InputSourceSelection.targetID(currentID: "ABC", available: sources, lastChineseID: nil, lastEnglishID: nil) == "Pinyin",
              "English toggles directly to Chinese")
        check(InputSourceSelection.targetID(currentID: "Pinyin", available: sources, lastChineseID: nil, lastEnglishID: "US") == "US",
              "Remember the preferred English layout")
        check(InputSourceSelection.targetID(currentID: "ABC", available: sources, lastChineseID: "Zhuyin", lastEnglishID: nil) == "Zhuyin",
              "Remember the preferred Chinese IME")
        check(InputSourceSelection.targetID(currentID: "Japanese", available: sources, lastChineseID: "Zhuyin", lastEnglishID: nil) == "Zhuyin",
              "Another language returns to the preferred Chinese IME")
        check(InputSourceSelection.targetID(currentID: "ABC", available: sources, lastChineseID: "Removed", lastEnglishID: nil) == "Pinyin",
              "A removed remembered source falls back to an available source")
        check(InputSourceSelection.targetID(currentID: "Pinyin", available: [pinyin, japanese], lastChineseID: nil, lastEnglishID: nil) == nil,
              "Missing English reports unavailable instead of cycling to another language")
        check(InputSourceSelection.targetID(currentID: "ABC", available: [abc, japanese], lastChineseID: nil, lastEnglishID: nil) == nil,
              "Missing Chinese reports unavailable")

        var navigation = options
        navigation.navigation = true
        let arrow = ShortcutEngine().process(input(123, [.control, .shift]), options: navigation, active: true)
        check(arrow.modifiers == [.option, .shift], "Ctrl+Shift+Left word selection")
        let home = ShortcutEngine().process(input(115, .control), options: navigation, active: true)
        check(home.code == 126 && home.modifiers == .command, "Ctrl+Home document start")
        let plainHome = ShortcutEngine().process(input(115, []), options: navigation, active: true)
        check(plainHome.code == 115 && plainHome.modifiers.isEmpty, "Plain Home unchanged")
        for code: UInt16 in [125, 126] {
            for modifiers: Modifiers in [.command, [.command, .shift]] {
                check(ShortcutEngine().process(input(code, modifiers), options: navigation, active: true).consume,
                      "Native document navigation disabled with navigation on")
                check(!ShortcutEngine().process(input(code, modifiers), options: options, active: true).consume,
                      "Native document navigation restored with navigation off")
            }
        }
        check(!ShortcutEngine().process(input(123, .option), options: navigation, active: true).consume,
              "Option word navigation remains available")

        var off = options
        off.common = false; off.browser = false
        for code: UInt16 in [8, 13, 3, 16, 17, 37] {
            let result = ShortcutEngine().process(input(code, .control), options: off, active: true)
            check(result.modifiers == .control && result.code == code, "Feature switch disables mapping \(code)")
        }
        for code: UInt16 in [8, 13, 3, 6, 17, 37, 48] {
            check(!ShortcutEngine().process(input(code, .command), options: off, active: true).consume,
                  "Disabled group restores native Command shortcut \(code)")
        }
        var commonOff = options
        commonOff.common = false
        check(!ShortcutEngine().process(input(8, .command), options: commonOff, active: true).consume,
              "Common toggle restores Command+C independently")
        check(ShortcutEngine().process(input(17, .command), options: commonOff, active: true).consume,
              "Browser replacement stays enabled independently")
        var browserOff = options
        browserOff.browser = false
        check(!ShortcutEngine().process(input(17, .command), options: browserOff, active: true).consume,
              "Browser toggle restores Command+T independently")
        check(ShortcutEngine().process(input(8, .command), options: browserOff, active: true).consume,
              "Common replacement stays enabled independently")
        print("PASS: \(count) shortcut/state checks")
    }
}
