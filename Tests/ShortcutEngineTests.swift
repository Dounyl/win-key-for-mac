import Foundation

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
                   repeatKey: Bool = false) -> KeyInput {
            KeyInput(code: code, phase: phase, modifiers: modifiers, repeatKey: repeatKey)
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

        let disabledWhileHeld = ShortcutEngine()
        _ = disabledWhileHeld.process(input(16, .control), options: options, active: true)
        _ = disabledWhileHeld.finishAppSwitch()
        let afterDisable = disabledWhileHeld.process(input(16, [], .up), options: options, active: false)
        check(afterDisable.code == 6, "Disabling app switching preserves other held key-up pairs")

        let alt = ShortcutEngine()
        let firstTab = alt.process(input(48, .option), options: options, active: true)
        check(firstTab.modifiers == .command && firstTab.commandTransition == true, "Alt+Tab starts held Command")
        _ = alt.process(input(48, .option, .up), options: options, active: true)
        let secondTab = alt.process(input(48, [.option, .shift]), options: options, active: true)
        check(secondTab.modifiers == [.command, .shift] && secondTab.commandTransition == nil, "Shift reverses without duplicate Command-down")
        let altUp = alt.process(input(58, [], .flags), options: options, active: false)
        check(altUp.commandTransition == false && !alt.switchingApps, "Alt-up releases Command even after foreground exclusion")
        let tabUp = alt.process(input(48, [], .up), options: options, active: true)
        check(!tabUp.modifiers.contains(.command), "Tab-up after Alt-up cannot reintroduce Command")
        check(!alt.reset(), "Reset after clean release sends no extra Command-up")

        let interrupted = ShortcutEngine()
        _ = interrupted.process(input(48, .option), options: options, active: true)
        check(interrupted.reset(), "Stopping during Alt+Tab requires Command release")
        check(!interrupted.hasHeldMappings, "Stopping clears held keys")

        let native = ShortcutEngine().process(input(48, .command), options: options, active: true)
        check(native.consume && native.commandTransition == nil, "Native Command+Tab disabled")
        check(ShortcutEngine().process(input(48, [.command, .shift]), options: options, active: true).consume,
              "Native Command+Shift+Tab disabled")
        let ctrlTab = ShortcutEngine().process(input(48, .control), options: options, active: true)
        check(ctrlTab.modifiers == .control, "Ctrl+Tab preserves tab cycling")

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
        off.common = false; off.browser = false; off.appSwitch = false
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
