#!/usr/bin/env swift
import AppKit
import ApplicationServices

struct ProbeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

@MainActor
func waitFor<T>(_ description: String, until deadline: TimeInterval, _ read: () throws -> T?) async throws -> T {
    while now() < deadline {
        if let result = try read() { return result }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw ProbeError("Timed out waiting for \(description).")
}

func attribute(_ element: AXUIElement, _ key: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key, &value) == .success else { return nil }
    return value
}

func elementAttribute(_ element: AXUIElement, _ key: CFString) -> AXUIElement? {
    guard let value = attribute(element, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func menuItem(_ app: AXUIElement, in menu: String, matching predicate: (String) -> Bool) -> AXUIElement? {
    func children(_ item: AXUIElement) -> [AXUIElement] {
        attribute(item, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }
    func title(_ item: AXUIElement) -> String { attribute(item, kAXTitleAttribute as CFString) as? String ?? "" }
    guard let bar = elementAttribute(app, kAXMenuBarAttribute as CFString),
          let owner = children(bar).first(where: { title($0) == menu }),
          let contents = children(owner).first else { return nil }
    return children(contents).first {
        predicate(title($0)) && attribute($0, kAXEnabledAttribute as CFString) as? Bool == true
    }
}

func press(_ item: AXUIElement, named name: String) throws {
    let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
    guard result == .success else { throw ProbeError("Could not perform \(name) (Accessibility error \(result.rawValue)).") }
}

@MainActor
func measure(bundle: URL, configuration: NSWorkspace.OpenConfiguration, label: String) async throws {
    let existingPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
    let start = now()
    let deadline = start + 60
    let app = try await NSWorkspace.shared.openApplication(at: bundle, configuration: configuration)
    guard !existingPIDs.contains(app.processIdentifier) else {
        throw ProbeError("Launch Services returned an existing application.")
    }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(ax, 1)

    func title(_ window: AXUIElement) -> String? { attribute(window, kAXTitleAttribute as CFString) as? String }
    do {
        guard app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == bundle else {
            throw ProbeError("Launch Services returned a different bundle.")
        }
        let document = try await waitFor("the initial Untitled document", until: deadline) { () throws -> AXUIElement? in
            guard !app.isTerminated else { throw ProbeError("Glims exited during launch.") }
            guard let window = elementAttribute(ax, kAXMainWindowAttribute as CFString),
                  title(window)?.hasPrefix("Untitled @ ") == true else { return nil }
            return window
        }
        let windowTime = now() - start
        let duplicate = try await waitFor("Layer > Duplicate Layer", until: deadline) {
            menuItem(ax, in: "Layer", matching: { $0 == "Duplicate Layer" })
        }
        try press(duplicate, named: "Duplicate Layer")
        _ = try await waitFor("the edited document title", until: deadline) {
            title(document)?.hasPrefix("• Untitled @ ") == true ? true : nil
        }
        let editTime = now() - start
        let undo = try await waitFor("Edit > Undo", until: deadline) {
            menuItem(ax, in: "Edit", matching: { $0 == "Undo" || $0.hasPrefix("Undo ") })
        }
        try press(undo, named: "Undo")
        _ = try await waitFor("Undo to restore the clean document", until: deadline) {
            title(document)?.hasPrefix("Untitled @ ") == true ? true : nil
        }
        app.terminate()
        _ = try await waitFor("Glims to quit", until: now() + 10) { app.isTerminated ? true : nil }
        print(String(format: "%@: document %.3f s, first edit %.3f s (Undo verified)", label, windowTime, editTime))
    } catch let failure {
        // This instance was created solely for the probe and owns only a disposable document.
        if !app.isTerminated {
            app.forceTerminate()
            do {
                _ = try await waitFor("the probe instance to exit", until: now() + 10) { app.isTerminated ? true : nil }
            } catch {
                throw ProbeError("\(failure.localizedDescription) Cleanup also failed: \(error.localizedDescription)")
            }
        }
        throw failure
    }
}

@MainActor
func run() async throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    let shellLocale = arguments.first == "--shell-locale"
    if shellLocale { arguments.removeFirst() }
    guard arguments.count == 1 else { throw ProbeError("Usage: measure-first-edit.swift [--shell-locale] PATH/TO/Glims.app") }
    let bundle = URL(fileURLWithPath: arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
    guard Bundle(url: bundle)?.bundleIdentifier == "ch.lkmc.Glims",
          FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/libglimsengine.dylib").path)
    else { throw ProbeError("Supply a Glims.app containing its packaged engine.") }
    guard AXIsProcessTrusted() else { throw ProbeError("The measuring process needs macOS Accessibility access.") }

    let manager = FileManager.default
    let profile = manager.temporaryDirectory.appendingPathComponent("glims-first-edit-\(UUID().uuidString)")
    try manager.createDirectory(at: profile, withIntermediateDirectories: false)
    defer { try? manager.removeItem(at: profile) }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    configuration.addsToRecentItems = false
    configuration.allowsRunningApplicationSubstitution = false
    configuration.promptsUserIfNeeded = false
    var environment = shellLocale ? ProcessInfo.processInfo.environment.filter {
        $0.key == "LANG" || $0.key == "LANGUAGE" || $0.key.hasPrefix("LC_")
    } : [:]
    for (key, leaf) in [("HOME", "home"), ("CFFIXED_USER_HOME", "home"), ("XDG_CACHE_HOME", "cache"),
                        ("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "data"), ("XDG_STATE_HOME", "state"),
                        ("TMPDIR", "tmp")] {
        let directory = profile.appendingPathComponent(leaf)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        environment[key] = directory.path
    }
    configuration.environment = environment
    try await measure(bundle: bundle, configuration: configuration, label: "Fresh profile")
    let registry = profile.appendingPathComponent("home/Library/Application Support/Glims/Engine/pluginrc")
    guard manager.fileExists(atPath: registry.path) else { throw ProbeError("Missing registry in the disposable profile.") }
    try await measure(bundle: bundle, configuration: configuration, label: "Reused profile")
}

do { try await run() }
catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
