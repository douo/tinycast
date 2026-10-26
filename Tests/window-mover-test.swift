import AppKit
@preconcurrency import ApplicationServices

@MainActor
enum Permissions {
    static func ensureAccessibility() -> Bool { true }
}

struct AXGeometry {
    init(screens: [NSScreen]) {}
    func flip(_ frame: CGRect) -> CGRect { frame }
}

@MainActor
enum AXScreens {
    static let source = WindowPlacementEngine.Screen(
        id: 1, frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
        visibleFrame: CGRect(x: 0, y: 33, width: 1470, height: 923))
    static let destination = WindowPlacementEngine.Screen(
        id: 2, frame: CGRect(x: -247, y: -1080, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -247, y: -1050, width: 1920, height: 1050))
    static var screens = [source, destination]

    static func converted(
        _ screens: [NSScreen], geometry: AXGeometry
    ) -> [WindowPlacementEngine.Screen] { self.screens }
}

struct CustomWindowSize {
    func placement(
        for frame: CGRect, screens: [WindowPlacementEngine.Screen], gap: CGFloat
    ) -> WindowPlacementEngine.Placement? {
        WindowPlacementEngine.placement(
            for: .init(command: .reasonableSize, windowFrame: frame, screens: screens, gap: gap))
    }
}

@MainActor
enum AXWindowAccess {
    static let messagingTimeout: Float = 1
    static let clampTolerance: CGFloat = 2
    static let fullScreenAttribute = "AXFullScreen" as CFString
    static let fullScreenButtonAttribute = "AXFullScreenButton" as CFString
    static let window = AXUIElementCreateApplication(getpid())
    static var current: CGRect? = AXScreens.source.visibleFrame
    static var writes = 0
    static var clipsFirstWrite = true
    static var clipsEveryWrite = false
    static var canResize = true
    static var fullScreen = false

    static func reset() {
        current = AXScreens.source.visibleFrame
        writes = 0
        clipsFirstWrite = true
        clipsEveryWrite = false
        canResize = true
        fullScreen = false
        AXScreens.screens = [AXScreens.source, AXScreens.destination]
    }

    static func application(for pid: pid_t) -> AXUIElement { window }
    static func targetWindow(in application: AXUIElement) -> AXUIElement? { window }
    static func frame(of window: AXUIElement) -> CGRect? { current }
    static func isFullScreen(_ window: AXUIElement) -> Bool { fullScreen }
    static func element(_ window: AXUIElement, _ attribute: String) -> AXUIElement? { nil }
    static func suppressEnhancedUserInterface(on application: AXUIElement) -> () -> Void { {} }

    static func isSettable(_ attribute: String, on window: AXUIElement) -> Bool {
        attribute == kAXPositionAttribute || (attribute == kAXSizeAttribute && canResize)
    }

    static func write(
        _ target: CGRect, anchor: WindowPlacementEngine.Anchor, to window: AXUIElement,
        current: CGRect, canResize: Bool, canvas: CGRect?
    ) -> CGRect? {
        writes += 1
        var frame = canResize ? target : anchor.place(current.size, in: target)
        if canResize, (writes == 1 && clipsFirstWrite) || clipsEveryWrite { frame.size.width -= 203 }
        self.current = frame
        return frame
    }
}

@main
@MainActor
struct WindowMoverTests {
    static var passes = 0
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() { passes += 1 } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func settle() async {
        do { try await Task.sleep(for: .milliseconds(120)) } catch { preconditionFailure() }
    }

    static func move(_ mover: WindowMover, target: WindowTarget) {
        expect(
            mover.perform(.nextDisplay, target: target, gap: 0, cycle: .off),
            "the initial transfer returns synchronously")
    }

    static func main() async {
        _ = NSApplication.shared
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier != getpid() && !$0.isTerminated
        }) else { preconditionFailure("This harness needs a macOS login session") }
        // AX is stubbed above; the running app supplies only a distinct pid, never a real window.
        let target = WindowTarget.external(app)

        AXWindowAccess.reset()
        let mover = WindowMover()
        move(mover, target: target)
        expect(AXWindowAccess.current?.width == 1717, "the fixture clips the initial AX resize")
        expect(AXWindowAccess.writes == 1, "the correction does not run inside the AX write")
        await settle()
        expect(AXWindowAccess.writes == 2, "a clipped transfer gets one deferred correction")
        expect(
            AXWindowAccess.current == AXScreens.destination.visibleFrame,
            "the correction fills the destination without another display move")
        expect(
            mover.perform(.restore, target: target, gap: 0, cycle: .off),
            "Restore still has the original frame")
        expect(AXWindowAccess.current == AXScreens.source.visibleFrame, "the correction preserves Restore")

        AXWindowAccess.reset()
        let superseded = WindowMover()
        move(superseded, target: target)
        _ = superseded.perform(.reasonableSize, target: target, gap: 0, cycle: .off)
        let newerFrame = AXWindowAccess.current
        await settle()
        expect(AXWindowAccess.writes == 2, "a newer command cancels the pending correction")
        expect(AXWindowAccess.current == newerFrame, "a correction never overwrites a newer command")

        AXWindowAccess.reset()
        let custom = WindowMover()
        move(custom, target: target)
        _ = custom.perform(CustomWindowSize(), target: target, gap: 0)
        await settle()
        expect(AXWindowAccess.writes == 2, "a custom size also cancels the pending correction")

        AXWindowAccess.reset()
        let dragged = WindowMover()
        move(dragged, target: target)
        AXWindowAccess.current?.origin.x += 10
        let userFrame = AXWindowAccess.current
        await settle()
        expect(AXWindowAccess.writes == 1, "a user drag prevents a deferred write")
        expect(AXWindowAccess.current == userFrame, "a user drag stays where the user left it")

        AXWindowAccess.reset()
        let resized = WindowMover()
        move(resized, target: target)
        AXWindowAccess.current?.size.width -= 50
        await settle()
        expect(AXWindowAccess.writes == 1, "a user resize prevents a deferred write")

        AXWindowAccess.reset()
        let reconfigured = WindowMover()
        move(reconfigured, target: target)
        AXScreens.screens.removeLast()
        await settle()
        expect(AXWindowAccess.writes == 1, "an unplugged destination prevents a deferred write")

        AXWindowAccess.reset()
        let layoutChanged = WindowMover()
        move(layoutChanged, target: target)
        AXScreens.screens[1] = .init(
            id: AXScreens.destination.id, frame: AXScreens.destination.frame,
            visibleFrame: AXScreens.destination.visibleFrame.insetBy(dx: 10, dy: 10))
        await settle()
        expect(AXWindowAccess.writes == 1, "a changed usable area prevents a stale placement")

        AXWindowAccess.reset()
        let closed = WindowMover()
        move(closed, target: target)
        AXWindowAccess.current = nil
        await settle()
        expect(AXWindowAccess.writes == 1, "a closed window prevents a deferred write")

        AXWindowAccess.reset()
        let fullscreen = WindowMover()
        move(fullscreen, target: target)
        AXWindowAccess.fullScreen = true
        await settle()
        expect(AXWindowAccess.writes == 1, "entering fullscreen prevents a deferred write")

        AXWindowAccess.reset()
        AXWindowAccess.clipsFirstWrite = false
        let honored = WindowMover()
        move(honored, target: target)
        await settle()
        expect(AXWindowAccess.writes == 1, "an honored resize needs no deferred work")

        AXWindowAccess.reset()
        AXWindowAccess.canResize = false
        let fixedSize = WindowMover()
        move(fixedSize, target: target)
        await settle()
        expect(AXWindowAccess.writes == 1, "a non-resizable window never gets a deferred resize")

        AXWindowAccess.reset()
        AXWindowAccess.clipsEveryWrite = true
        let constrained = WindowMover()
        move(constrained, target: target)
        await settle()
        await settle()
        expect(AXWindowAccess.writes == 2, "an app that refuses the correction is never retried again")

        AXWindowAccess.reset()
        var released: WindowMover? = WindowMover()
        weak var weakMover = released
        move(released!, target: target)
        released = nil
        expect(weakMover == nil, "a pending correction does not retain its mover")
        await settle()
        expect(AXWindowAccess.writes == 1, "destroying the mover cancels its pending correction")

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
