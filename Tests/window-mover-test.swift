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
    static var displayReadyAt: ContinuousClock.Instant?
    static var canResize = true
    static var canMove = true
    static var fullScreen = false
    static var fullScreenRequests: [Bool] = []
    static var refusesFullScreen = false
    static var ignoresFullScreen = false
    static var refusesMove = false
    static var transitionDelay: Duration = .milliseconds(60)
    static var transition: (ready: ContinuousClock.Instant, fullScreen: Bool, frame: CGRect)?
    static var normalFrame = AXScreens.source.visibleFrame

    static func reset() {
        current = AXScreens.source.visibleFrame
        writes = 0
        clipsFirstWrite = true
        clipsEveryWrite = false
        displayReadyAt = nil
        canResize = true
        canMove = true
        fullScreen = false
        fullScreenRequests = []
        refusesFullScreen = false
        ignoresFullScreen = false
        refusesMove = false
        transitionDelay = .milliseconds(60)
        transition = nil
        normalFrame = AXScreens.source.visibleFrame
        AXScreens.screens = [AXScreens.source, AXScreens.destination]
    }

    static func application(for pid: pid_t) -> AXUIElement { window }
    static func targetWindow(in application: AXUIElement) -> AXUIElement? { window }
    static func frame(of window: AXUIElement) -> CGRect? {
        finishTransition()
        return current
    }
    static func isFullScreen(_ window: AXUIElement) -> Bool {
        finishTransition()
        return fullScreen
    }
    static func setFullScreen(_ enabled: Bool, on window: AXUIElement) -> Bool {
        fullScreenRequests.append(enabled)
        guard !refusesFullScreen else { return false }
        guard !ignoresFullScreen, let current,
            let display = WindowPlacementEngine.screen(containing: current, in: AXScreens.screens)
        else { return true }
        if enabled { normalFrame = current }
        transition = (
            .now.advanced(by: transitionDelay), enabled, enabled ? display.frame : normalFrame)
        return true
    }
    static func finishTransition() {
        guard let transition, ContinuousClock.now >= transition.ready else { return }
        if current != nil {
            fullScreen = transition.fullScreen
            current = transition.frame
        }
        self.transition = nil
    }
    static func element(_ window: AXUIElement, _ attribute: String) -> AXUIElement? { nil }
    static func suppressEnhancedUserInterface(on application: AXUIElement) -> () -> Void { {} }

    static func isSettable(_ attribute: String, on window: AXUIElement) -> Bool {
        (attribute == kAXPositionAttribute && canMove) || (attribute == kAXSizeAttribute && canResize)
    }

    static func write(
        _ target: CGRect, anchor: WindowPlacementEngine.Anchor, to window: AXUIElement,
        current: CGRect, canResize: Bool, canvas: CGRect?
    ) -> CGRect? {
        writes += 1
        if refusesMove { return current }
        var frame = canResize ? target : anchor.place(current.size, in: target)
        if writes == 1, clipsFirstWrite {
            displayReadyAt = .now.advanced(by: .milliseconds(40))
        }
        let settling = displayReadyAt.map { ContinuousClock.now < $0 } ?? false
        if canResize, clipsEveryWrite || settling { frame.size.width = min(frame.width, 1717) }
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

    static func prepareFullScreen() {
        AXWindowAccess.reset()
        AXWindowAccess.fullScreen = true
        AXWindowAccess.current = AXScreens.source.frame
    }

    static func settleFullScreen() async {
        do { try await Task.sleep(for: .milliseconds(1550)) } catch { preconditionFailure() }
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
        move(released!, target: target)
        released = nil
        await settle()
        expect(AXWindowAccess.writes == 1, "destroying the mover cancels its pending correction")

        prepareFullScreen()
        let transfer = WindowMover()
        move(transfer, target: target)
        expect(AXWindowAccess.writes == 0, "a fullscreen transfer waits before writing geometry")
        expect(AXWindowAccess.fullScreenRequests == [false], "the transfer first exits native fullscreen")
        expect(
            !transfer.perform(.nextDisplay, target: target, gap: 0, cycle: .off),
            "a repeated display command does not interrupt a fullscreen transition")
        await settleFullScreen()
        expect(AXWindowAccess.fullScreen, "the transferred window is natively fullscreen")
        expect(AXWindowAccess.current == AXScreens.destination.frame, "fullscreen fills the destination")
        expect(AXWindowAccess.fullScreenRequests == [false, true], "the transfer enters fullscreen once")
        expect(AXWindowAccess.writes == 2, "a fullscreen transfer corrects a clipped resize once")
        expect(
            transfer.perform(.previousDisplay, target: target, gap: 0, cycle: .off),
            "the reverse transfer starts after the first finishes")
        await settleFullScreen()
        expect(AXWindowAccess.fullScreen, "the reverse transfer also preserves native fullscreen")
        expect(AXWindowAccess.current == AXScreens.source.frame, "the reverse transfer fills the source")
        _ = AXWindowAccess.setFullScreen(false, on: AXWindowAccess.window)
        await settle()
        _ = AXWindowAccess.isFullScreen(AXWindowAccess.window)
        _ = transfer.perform(.reasonableSize, target: target, gap: 0, cycle: .off)
        expect(
            transfer.perform(.restore, target: target, gap: 0, cycle: .off),
            "fullscreen transfers retain the original Restore point")
        expect(AXWindowAccess.current == AXScreens.source.visibleFrame, "Restore uses ordinary geometry")

        prepareFullScreen()
        AXScreens.screens = [AXScreens.source]
        expect(
            !WindowMover().perform(.nextDisplay, target: target, gap: 0, cycle: .off),
            "one display leaves native fullscreen untouched")
        expect(AXWindowAccess.fullScreenRequests.isEmpty, "one display never exits fullscreen")

        prepareFullScreen()
        AXWindowAccess.refusesFullScreen = true
        let refused = WindowMover()
        expect(
            !refused.perform(.nextDisplay, target: target, gap: 0, cycle: .off),
            "a refused fullscreen exit is reported synchronously")
        expect(AXWindowAccess.writes == 0, "a refused fullscreen exit writes no geometry")

        prepareFullScreen()
        let disconnected = WindowMover()
        move(disconnected, target: target)
        AXScreens.screens = [AXScreens.source]
        await settleFullScreen()
        expect(AXWindowAccess.writes == 0, "disconnecting a display prevents fullscreen geometry writes")
        expect(
            AXWindowAccess.isFullScreen(AXWindowAccess.window),
            "a disconnected transfer restores fullscreen on the current display")

        prepareFullScreen()
        AXWindowAccess.canMove = false
        let immovable = WindowMover()
        move(immovable, target: target)
        await settleFullScreen()
        expect(AXWindowAccess.writes == 0, "an immovable fullscreen window gets no geometry writes")
        expect(AXWindowAccess.isFullScreen(AXWindowAccess.window), "an immovable window returns to native fullscreen")

        prepareFullScreen()
        AXWindowAccess.refusesMove = true
        let unresponsive = WindowMover()
        move(unresponsive, target: target)
        await settleFullScreen()
        expect(AXWindowAccess.isFullScreen(AXWindowAccess.window), "a refused display move returns to native fullscreen")
        expect(AXWindowAccess.current == AXScreens.source.frame, "a refused move remains on its source")

        prepareFullScreen()
        let interrupted = WindowMover()
        move(interrupted, target: target)
        await settle()
        _ = interrupted.perform(.reasonableSize, target: target, gap: 0, cycle: .off)
        let interruptedFrame = AXWindowAccess.current
        await settleFullScreen()
        expect(AXWindowAccess.current == interruptedFrame, "a newer command cancels fullscreen transfer")
        expect(AXWindowAccess.fullScreenRequests == [false], "a superseded transfer never reenters fullscreen")

        prepareFullScreen()
        let customInterrupted = WindowMover()
        move(customInterrupted, target: target)
        await settle()
        _ = customInterrupted.perform(CustomWindowSize(), target: target, gap: 0)
        let customFrame = AXWindowAccess.current
        await settleFullScreen()
        expect(AXWindowAccess.current == customFrame, "a custom size supersedes fullscreen transfer")

        prepareFullScreen()
        let closedFullScreen = WindowMover()
        move(closedFullScreen, target: target)
        AXWindowAccess.current = nil
        await settleFullScreen()
        expect(AXWindowAccess.writes == 0, "a closed fullscreen window never receives geometry")
        expect(AXWindowAccess.fullScreenRequests == [false], "a closed window is never toggled again")

        prepareFullScreen()
        var releasedFullScreen: WindowMover? = WindowMover()
        move(releasedFullScreen!, target: target)
        releasedFullScreen = nil
        await settleFullScreen()
        expect(AXWindowAccess.writes == 0, "destroying the mover cancels fullscreen transfer")
        expect(AXWindowAccess.fullScreenRequests == [false], "owner teardown never starts a later transition")

        prepareFullScreen()
        let changedInsets = WindowMover()
        move(changedInsets, target: target)
        AXScreens.screens[0] = .init(
            id: AXScreens.source.id, frame: AXScreens.source.frame,
            visibleFrame: AXScreens.source.frame)
        await settleFullScreen()
        expect(AXWindowAccess.fullScreen, "menu bar visibility changes do not cancel a fullscreen transfer")
        expect(AXWindowAccess.current == AXScreens.destination.frame, "the display identity ignores usable insets")

        prepareFullScreen()
        let userMoved = WindowMover()
        move(userMoved, target: target)
        let moveDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while AXWindowAccess.writes < 2, ContinuousClock.now < moveDeadline {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { preconditionFailure() }
        }
        AXWindowAccess.current?.origin.x += 20
        let draggedFrame = AXWindowAccess.current
        await settleFullScreen()
        expect(AXWindowAccess.current == draggedFrame, "a drag during transfer is not overwritten")
        expect(AXWindowAccess.fullScreenRequests == [false], "a drag cancels automatic fullscreen entry")

        prepareFullScreen()
        AXWindowAccess.transitionDelay = .milliseconds(700)
        let slow = WindowMover()
        move(slow, target: target)
        await settle()
        expect(AXWindowAccess.writes == 0, "slow native fullscreen exits do not receive early writes")
        do { try await Task.sleep(for: .milliseconds(2400)) } catch { preconditionFailure() }
        expect(AXWindowAccess.fullScreen, "slow transitions complete in native fullscreen")
        expect(AXWindowAccess.current == AXScreens.destination.frame, "slow transitions reach the destination")

        prepareFullScreen()
        AXWindowAccess.ignoresFullScreen = true
        let ignored = WindowMover()
        move(ignored, target: target)
        do { try await Task.sleep(for: .milliseconds(5300)) } catch { preconditionFailure() }
        expect(AXWindowAccess.writes == 0, "an accepted but ignored fullscreen exit times out without geometry")
        expect(AXWindowAccess.fullScreen, "an ignored fullscreen exit never changes the display")

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }
}
