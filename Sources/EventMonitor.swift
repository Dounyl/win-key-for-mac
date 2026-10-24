import AppKit
import ApplicationServices
import Carbon

struct MonitorSnapshot {
    var options = ShortcutOptions()
    var enabled = false
    var excluded = false
    var suspended = false
}

/// Owns one event-tap thread inside the app; no helper process or driver.
final class EventMonitor {
    static let syntheticTag: Int64 = 0x57494E4B455953
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
        let mustRelease = (snapshot.enabled && !value.enabled) ||
                          (!snapshot.suspended && value.suspended) ||
                          (snapshot.options.appSwitch && !value.options.appSwitch)
        snapshot = value
        let currentLoop = loop
        lock.unlock()
        if mustRelease, let currentLoop {
            CFRunLoopPerformBlock(currentLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                self?.releaseHeldCommand(clearMappings: false)
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
                self?.releaseHeldCommand()
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
            let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
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
            releaseHeldCommand()
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
        releaseHeldCommand()
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
            releaseHeldCommand()
            emit("监听被系统暂停，请手动重新启用。", ok: false)
            CFRunLoopStop(CFRunLoopGetCurrent())
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticTag {
            return Unmanaged.passUnretained(event)
        }
        lock.lock(); let current = snapshot; lock.unlock()
        let phase: KeyPhase = type == .flagsChanged ? .flags : (type == .keyUp ? .up : .down)
        let input = KeyInput(code: UInt16(event.getIntegerValueField(.keyboardEventKeycode)),
                             phase: phase, modifiers: Modifiers(rawValue: event.flags.rawValue),
                             repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        // No app enumeration or UI calls inside the event callback.
        let decision = engine.process(input, options: current.options,
            active: current.enabled && !current.excluded && !current.suspended)
        if let down = decision.commandTransition {
            postCommand(down: down, flags: decision.modifiers, proxy: proxy)
        }
        if decision.switchInput {
            DispatchQueue.main.async { [weak self] in self?.inputRequested?() }
        }
        if decision.consume { return nil }
        if decision.code != input.code {
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(decision.code))
        }
        if decision.modifiers != input.modifiers {
            event.flags = normalizedFlags(decision.modifiers)
        }
        return Unmanaged.passUnretained(event)
    }

    private func postCommand(down: Bool, flags: Modifiers, proxy: CGEventTapProxy? = nil) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 55, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = normalizedFlags(flags)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        if let proxy { event.tapPostEvent(proxy) }
        else { event.post(tap: .cgSessionEventTap) }
    }

    private func normalizedFlags(_ flags: Modifiers) -> CGEventFlags {
        // NX device-side Ctrl/Option/Command bits must not contradict the new generic flags.
        CGEventFlags(rawValue: flags.rawValue & ~UInt64(0x2079))
    }

    private func releaseHeldCommand(clearMappings: Bool = true) {
        if clearMappings ? engine.reset() : engine.finishAppSwitch() {
            var flags = Modifiers(rawValue: CGEventSource.flagsState(.hidSystemState).rawValue)
            flags.remove(.command)
            postCommand(down: false, flags: flags)
        }
    }
}

enum InputSources {
    static func selectNext() -> String? {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let unmanaged = TISCreateInputSourceList(filter, false) else {
            return "读取输入法失败，请检查系统输入法设置。"
        }
        let sources = unmanaged.takeRetainedValue() as! [TISInputSource]
        guard sources.count > 1 else { return "至少启用两种系统输入法才能切换。" }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return "无法读取当前输入法。"
        }
        func id(_ source: TISInputSource) -> String {
            guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
            return Unmanaged<CFString>.fromOpaque(value).takeUnretainedValue() as String
        }
        let index = sources.firstIndex { id($0) == id(current) } ?? -1
        let next = sources[(index + 1) % sources.count]
        return TISSelectInputSource(next) == noErr ? nil : "输入法切换失败，请使用原来的系统切换键。"
    }
}
