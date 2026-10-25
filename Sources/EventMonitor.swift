import AppKit
import ApplicationServices
import Carbon

struct MonitorSnapshot {
    var options = ShortcutOptions()
    var enabled = false
    var excluded = false
    var suspended = false
    var frontAppID = ""
}

/// Owns one event-tap thread inside the app; no helper process or driver.
final class EventMonitor {
    private static let pointerEvents: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
    private let lock = NSLock()
    private var snapshot = MonitorSnapshot()
    private var worker: Thread?
    private var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var running = false
    private var stopping = false
    private let engine = ShortcutEngine()
    private var recoveryTimes: [TimeInterval] = []
    var report: ((String, Bool) -> Void)?
    var inputRequested: (() -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func update(_ value: MonitorSnapshot) {
        lock.lock()
        let cancelShift = snapshot.enabled != value.enabled || snapshot.excluded != value.excluded ||
            snapshot.suspended != value.suspended || snapshot.frontAppID != value.frontAppID ||
            snapshot.options.shiftInputSwitch != value.options.shiftInputSwitch
        snapshot = value
        let currentLoop = loop
        lock.unlock()
        if cancelShift, let currentLoop {
            CFRunLoopPerformBlock(currentLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                self?.engine.cancelShiftTap()
            }
            CFRunLoopWakeUp(currentLoop)
        }
    }

    func start() {
        lock.lock()
        guard worker == nil else { lock.unlock(); return }
        stopping = false
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "WinKeyForMac keyboard events"
        thread.qualityOfService = .userInteractive
        worker = thread
        lock.unlock()
        thread.start()
    }

    func stop() {
        lock.lock()
        stopping = true
        let currentLoop = loop
        lock.unlock()
        if let currentLoop {
            CFRunLoopPerformBlock(currentLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                self?.engine.reset()
                CFRunLoopStop(currentLoop)
            }
            CFRunLoopWakeUp(currentLoop)
        }
    }

    func checkHealth() {
        lock.lock()
        let currentLoop = loop
        lock.unlock()
        guard let currentLoop else { return }
        CFRunLoopPerformBlock(currentLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) { self.recover(reason: "监听已恢复") }
        }
        CFRunLoopWakeUp(currentLoop)
    }

    private func emit(_ message: String, ok: Bool) {
        DispatchQueue.main.async { [weak self] in self?.report?(message, ok) }
    }

    private func run() {
        autoreleasepool {
            let mask = ([CGEventType.keyDown, .keyUp, .flagsChanged] + Self.pointerEvents).reduce(CGEventMask(0)) {
                $0 | (CGEventMask(1) << $1.rawValue)
            }
            let callback: CGEventTapCallBack = { proxy, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<EventMonitor>.fromOpaque(context).takeUnretainedValue()
                return owner.handle(proxy: proxy, type: type, event: event)
            }
            guard let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                lock.lock(); worker = nil; running = false; lock.unlock()
                emit("监听未启动：请检查辅助功能；如仍失败，再检查输入监控权限。", ok: false)
                return
            }
            guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
                CFMachPortInvalidate(eventTap)
                lock.lock(); worker = nil; running = false; lock.unlock()
                emit("无法创建键盘监听，请重新启用。", ok: false)
                return
            }
            let currentLoop = CFRunLoopGetCurrent()!
            lock.lock()
            tap = eventTap
            loop = currentLoop
            running = true
            let shouldStop = stopping
            lock.unlock()
            CFRunLoopAddSource(currentLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            recoveryTimes.removeAll()
            emit("键盘监听运行中", ok: true)
            if !shouldStop { CFRunLoopRun() }
            engine.reset()
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFRunLoopRemoveSource(currentLoop, source, .commonModes)
            CFMachPortInvalidate(eventTap)
            lock.lock()
            tap = nil; loop = nil; running = false; worker = nil
            lock.unlock()
        }
    }

    private func recover(reason: String) {
        guard let tap else { return }
        engine.reset()
        let now = Date.timeIntervalSinceReferenceDate
        recoveryTimes = recoveryTimes.filter { now - $0 < 60 }
        guard recoveryTimes.count < 3 else {
            emit("监听在一分钟内多次失效，已停止。请检查权限后重新启用。", ok: false)
            CFRunLoopStop(CFRunLoopGetCurrent())
            return
        }
        recoveryTimes.append(now)
        CGEvent.tapEnable(tap: tap, enable: true)
        emit(reason, ok: CGEvent.tapIsEnabled(tap: tap))
    }

    private func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            recover(reason: "监听超时，已自动恢复")
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            // Respect the system/user disabling a tap; do not fight repeated disable requests.
            engine.reset()
            emit("监听被系统暂停，请手动重新启用。", ok: false)
            CFRunLoopStop(CFRunLoopGetCurrent())
            return Unmanaged.passUnretained(event)
        }
        if Self.pointerEvents.contains(type) {
            engine.cancelShiftTap()
            return Unmanaged.passUnretained(event)
        }
        lock.lock(); let current = snapshot; lock.unlock()
        let phase: KeyPhase = type == .flagsChanged ? .flags : (type == .keyUp ? .up : .down)
        let input = KeyInput(code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                             phase: phase, modifiers: Modifiers(rawValue: event.flags.rawValue),
                             repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                             timestamp: event.timestamp)
        // No app enumeration or UI calls inside the event callback.
        let decision = engine.process(input, options: current.options,
            active: current.enabled && !current.excluded && !current.suspended)
        if decision.switchInput {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock(); let latest = self.snapshot; self.lock.unlock()
                guard latest.enabled && !latest.excluded && !latest.suspended,
                      latest.frontAppID == current.frontAppID else { return }
                self.inputRequested?()
            }
        }
        if decision.consume { return nil }
        Self.apply(decision, to: event, input: input)
        return Unmanaged.passUnretained(event)
    }

    static func apply(_ decision: KeyDecision, to event: CGEvent, input: KeyInput) {
        if decision.code != input.code {
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(decision.code))
        }
        if decision.modifiers != input.modifiers {
            event.flags = normalizedFlags(decision.modifiers)
        }
        // Some clients use cached text even when it disagrees with the Caps Lock flag.
        // Apply the active case rule to that text, preserving native Shift/chord behavior.
        if let textCase = decision.textCase,
           decision.modifiers.intersection(.relevant).isEmpty,
           input.code == decision.code, input.phase == .down || input.phase == .up {
            var length = 0
            event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
            if length > 0 {
                var characters = [UniChar](repeating: 0, count: length)
                event.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length,
                                               unicodeString: &characters)
                let text = String(utf16CodeUnits: characters, count: length)
                let converted = Array((textCase == .uppercase ? text.uppercased() : text.lowercased()).utf16)
                converted.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
            }
        }
    }

    private static func normalizedFlags(_ flags: Modifiers) -> CGEventFlags {
        // NX device-side Ctrl/Option/Command bits must not contradict the new generic flags.
        CGEventFlags(rawValue: flags.rawValue & ~UInt64(0x2079))
    }

}

enum InputSources {
    static func toggleChineseEnglish() -> String? {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
                      kTISPropertyInputSourceIsSelectCapable as String: true,
                      kTISPropertyInputSourceIsEnabled as String: true] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else {
            return "读取输入法失败，请检查系统输入法设置。"
        }
        let sources = unmanaged.takeRetainedValue() as! [TISInputSource]
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return "无法读取当前输入法。"
        }
        func string(_ source: TISInputSource, _ key: CFString) -> String {
            guard let value = TISGetInputSourceProperty(source, key) else { return "" }
            return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        }
        func descriptor(_ source: TISInputSource) -> InputSourceDescriptor {
            var languages: [String] = []
            if let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
                languages = Unmanaged<CFArray>.fromOpaque(value).takeUnretainedValue() as? [String] ?? []
            }
            let ascii = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable).map {
                CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue())
            } ?? false
            return InputSourceDescriptor(id: string(source, kTISPropertyInputSourceID), languages: languages,
                isKeyboardLayout: string(source, kTISPropertyInputSourceType) == kTISTypeKeyboardLayout as String,
                isASCIICapable: ascii)
        }
        let defaults = UserDefaults.standard
        let currentDescriptor = descriptor(current)
        let chineseKey = "lastChineseInputSource"
        let englishKey = "lastEnglishInputSource"
        if currentDescriptor.isChinese { defaults.set(currentDescriptor.id, forKey: chineseKey) }
        if currentDescriptor.isEnglish { defaults.set(currentDescriptor.id, forKey: englishKey) }
        guard let targetID = InputSourceSelection.targetID(currentID: currentDescriptor.id,
            available: sources.map(descriptor), lastChineseID: defaults.string(forKey: chineseKey),
            lastEnglishID: defaults.string(forKey: englishKey)),
            let target = sources.first(where: { string($0, kTISPropertyInputSourceID) == targetID }) else {
            return "请在系统键盘设置中同时启用中文输入法和英文 / ABC 输入法。"
        }
        guard TISSelectInputSource(target) == noErr else { return "中英文切换失败，请检查系统输入法设置。" }
        defaults.set(targetID, forKey: descriptor(target).isChinese ? chineseKey : englishKey)
        return nil
    }
}
