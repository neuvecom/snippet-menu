import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import SwiftUI

// MARK: - Model

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var text: String

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.isEmpty ? "（無題）" : String(first.prefix(30))
    }
}

final class SnippetStore: ObservableObject {
    @Published var snippets: [Snippet] = [] {
        didSet { if snippets != oldValue { save() } }
    }

    private let url: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnippetMenu", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("snippets.json")
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([Snippet].self, from: data) {
            snippets = loaded
        } else {
            snippets = [
                Snippet(title: "サンプル/あいさつ", text: "お世話になっております。\nよろしくお願いいたします。")
            ]
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(snippets) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Text insertion (never touches NSPasteboard)

enum Inserter {
    static func insert(_ raw: String) {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if insertViaAccessibility(text) { return }
        typeViaKeyEvents(text)
    }

    // Direct insertion. It bypasses the input method, so it is tried first.

    private struct AXSnapshot: Equatable {
        let value: String?
        let count: Int?
        let location: Int?
        let length: Int?
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func snapshot(_ element: AXUIElement) -> AXSnapshot {
        var location: Int?
        var length: Int?
        if let raw = attribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(raw) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(raw as! AXValue, .cfRange, &range) {
                location = range.location
                length = range.length
            }
        }
        return AXSnapshot(
            value: attribute(element, kAXValueAttribute) as? String,
            count: attribute(element, kAXNumberOfCharactersAttribute) as? Int,
            location: location,
            length: length
        )
    }

    private static func insertViaAccessibility(_ text: String) -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let focused = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else { return false }

        // Some apps report success without inserting anything, so the result is
        // confirmed by comparing state. Without readable state, fall back to typing.
        let before = snapshot(element)
        guard before.value != nil || before.count != nil else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
        else { return false }

        for _ in 0..<6 {
            usleep(50_000)
            if snapshot(element) != before { return true }
        }
        return false
    }

    // Fallback for apps without usable accessibility text support.

    private static func typeViaKeyEvents(_ text: String) {
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        let ascii = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
        let needsSwitch = sourceID(previous) != sourceID(ascii)
        if needsSwitch {
            TISSelectInputSource(ascii)
            usleep(40_000)
        }
        defer {
            if needsSwitch {
                usleep(60_000)
                TISSelectInputSource(previous)
            }
        }

        let source = CGEventSource(stateID: .privateState)
        var buffer: [UniChar] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            post(source, keyCode: 0, flags: [], unicode: buffer)
            buffer.removeAll()
            usleep(4_000)
        }

        for character in text {
            if character == "\n" {
                flush()
                // Shift+Return avoids sending the message in chat apps.
                post(source, keyCode: CGKeyCode(kVK_Return), flags: .maskShift, unicode: nil)
                usleep(20_000)
            } else {
                let units = Array(String(character).utf16)
                if buffer.count + units.count > 16 { flush() }
                buffer.append(contentsOf: units)
            }
        }
        flush()
    }

    private static func sourceID(_ source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func post(_ source: CGEventSource?, keyCode: CGKeyCode, flags: CGEventFlags, unicode: [UniChar]?) {
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: isDown) else { continue }
            event.flags = flags
            if let unicode {
                unicode.withUnsafeBufferPointer {
                    event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
            }
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - Editor

struct EditorView: View {
    @ObservedObject var store: SnippetStore
    @State private var selection: UUID?

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<Snippet, String>) -> Binding<String> {
        Binding(
            get: { store.snippets.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let index = store.snippets.firstIndex(where: { $0.id == id }) {
                    store.snippets[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.snippets) { snippet in
                        Text(snippet.displayTitle).lineLimit(1).tag(snippet.id)
                    }
                    .onMove { store.snippets.move(fromOffsets: $0, toOffset: $1) }
                }
                Divider()
                HStack {
                    Button {
                        let snippet = Snippet(title: "", text: "")
                        store.snippets.append(snippet)
                        selection = snippet.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        if let selection { store.snippets.removeAll { $0.id == selection } }
                        selection = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 220)

            Divider()

            if let selection, store.snippets.contains(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("タイトル（「分類/名前」でサブメニュー）", text: binding(selection, \.title))
                    TextEditor(text: binding(selection, \.text))
                        .font(.body)
                        .border(Color.secondary.opacity(0.3))
                }
                .padding(12)
                .id(selection)
            } else {
                Text("左の一覧から選択するか、＋で追加してください")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
    }
}

// MARK: - App

private let optionClickKey = "optionRightClickEnabled"
private var swallowRightMouseUp = false

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        appDelegate.reenableEventTap()
    case .rightMouseDown:
        let flags = event.flags
        let onlyOption = flags.contains(.maskAlternate)
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl) && !flags.contains(.maskShift)
        if onlyOption && UserDefaults.standard.bool(forKey: optionClickKey) {
            swallowRightMouseUp = true
            DispatchQueue.main.async { appDelegate.showPopupMenu() }
            return nil
        }
    case .rightMouseUp:
        if swallowRightMouseUp {
            swallowRightMouseUp = false
            return nil
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SnippetStore()
    private var statusItem: NSStatusItem!
    private var editorWindow: NSWindow?
    private var eventTap: CFMachPort?
    private var hotKey: EventHotKeyRef?
    private var tapTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [optionClickKey: true])
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "定型文")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerHotKey()

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        installEventTapWhenTrusted()
    }

    // Accessory apps need a main menu for Cmd+C / Cmd+V to work in the editor.
    private func installMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "編集")
        edit.addItem(withTitle: "取り消す", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { appDelegate.showPopupMenu() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey),
            EventHotKeyID(signature: OSType(0x534E_4950), id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    private func installEventTapWhenTrusted() {
        if installEventTap() { return }
        tapTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            if self?.installEventTap() == true { timer.invalidate() }
        }
    }

    private func installEventTap() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let mask = (CGEventMask(1) << CGEventType.rightMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.rightMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: nil
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        return true
    }

    func reenableEventTap() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    // MARK: Menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        fill(menu, includeSettings: true)
    }

    func showPopupMenu() {
        let menu = NSMenu()
        fill(menu, includeSettings: false)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func fill(_ menu: NSMenu, includeSettings: Bool) {
        menu.removeAllItems()
        var groups: [String: NSMenu] = [:]

        for snippet in store.snippets {
            let parts = snippet.displayTitle.split(separator: "/", maxSplits: 1).map(String.init)
            let item = NSMenuItem(
                title: parts.count == 2 ? parts[1] : snippet.displayTitle,
                action: #selector(pick(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = snippet.text
            item.toolTip = String(snippet.text.prefix(200))

            if parts.count == 2 {
                if let group = groups[parts[0]] {
                    group.addItem(item)
                } else {
                    let group = NSMenu(title: parts[0])
                    group.addItem(item)
                    groups[parts[0]] = group
                    let parent = NSMenuItem(title: parts[0], action: nil, keyEquivalent: "")
                    parent.submenu = group
                    menu.addItem(parent)
                }
            } else {
                menu.addItem(item)
            }
        }

        if store.snippets.isEmpty {
            let empty = NSMenuItem(title: "定型文がありません", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        addCommand(menu, "UUIDを入力", #selector(insertUUID))
        addCommand(menu, "定型文を編集…", #selector(openEditor))
        guard includeSettings else { return }

        if !AXIsProcessTrusted() {
            addCommand(menu, "アクセシビリティを許可…", #selector(openAccessibilitySettings))
        }
        addCommand(menu, "⌥+右クリックで開く", #selector(toggleOptionClick)).state =
            UserDefaults.standard.bool(forKey: optionClickKey) ? .on : .off
        addCommand(menu, "ログイン時に起動", #selector(toggleLoginItem)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        addCommand(menu, "終了", #selector(quit))
    }

    @discardableResult
    private func addCommand(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: Actions

    @objc private func insertUUID() {
        insertText(newUUID())
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        // {uuid} becomes one fresh UUID per insertion.
        insertText(text.replacingOccurrences(of: "{uuid}", with: newUUID()))
    }

    private func newUUID() -> String {
        UUID().uuidString.lowercased()
    }

    private func insertText(_ text: String) {
        guard AXIsProcessTrusted() else {
            openAccessibilitySettings()
            return
        }
        // Lets the menu close and focus settle in the target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Inserter.insert(text) }
    }

    @objc private func openEditor() {
        if editorWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "定型文"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: EditorView(store: store))
            window.center()
            editorWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleOptionClick() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: optionClickKey), forKey: optionClickKey)
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let appDelegate = AppDelegate()
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = appDelegate
application.run()
