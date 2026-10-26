import AppKit
@preconcurrency import ApplicationServices
import OSLog

/// Applies window commands over AX. See docs/features/window-management.md#applying-a-placement.
@MainActor
final class WindowMover {
    /// `CFEqual`/`CFHash` are the supported identity; the pid separates two processes' elements.
    private struct ExternalKey: Hashable {
        let pid: pid_t
        let element: AXUIElement

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pid == rhs.pid && CFEqual(lhs.element, rhs.element)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(pid)
            hasher.combine(CFHash(element))
        }
    }

    /// A closed window's identifier can be reused; `decide` rejects the stale record on its frame.
    private enum WindowKey: Hashable {
        case external(ExternalKey)
        case own(ObjectIdentifier)
    }

    /// One of ours or another app's: an AX call into our own process would stall the main thread.
    @MainActor
    private enum Surface {
        case external(application: AXUIElement, window: AXUIElement)
        case own(NSWindow)

        var isFullScreen: Bool {
            switch self {
            case .external(_, let window): AXWindowAccess.isFullScreen(window)
            case .own(let window): window.styleMask.contains(.fullScreen)
            }
        }

        var canMove: Bool {
            switch self {
            case .external(_, let window):
                AXWindowAccess.isSettable(kAXPositionAttribute, on: window)
            case .own(let window): window.isMovable
            }
        }

        var canResize: Bool {
            switch self {
            case .external(_, let window):
                AXWindowAccess.isSettable(kAXSizeAttribute, on: window)
            case .own(let window): window.styleMask.contains(.resizable)
            }
        }

        func setFullScreen(_ enabled: Bool) -> Bool {
            switch self {
            case .external(_, let window):
                return AXWindowAccess.setFullScreen(enabled, on: window)
            case .own(let window):
                guard window.styleMask.contains(.resizable),
                    window.collectionBehavior.isDisjoint(with: [.fullScreenAuxiliary, .fullScreenNone])
                else { return false }
                if isFullScreen != enabled { window.toggleFullScreen(nil) }
                return true
            }
        }

        func frame(in geometry: AXGeometry) -> CGRect? {
            switch self {
            case .external(_, let window): AXWindowAccess.frame(of: window)
            case .own(let window): window.isVisible ? geometry.flip(window.frame) : nil
            }
        }

        /// Nothing to suppress on our own windows: it is a remote app's Accessibility setting.
        func suppressEnhancedUserInterface() -> () -> Void {
            guard case .external(let application, _) = self else { return {} }
            return AXWindowAccess.suppressEnhancedUserInterface(on: application)
        }

        func write(
            _ placement: WindowPlacementEngine.Placement, current: CGRect, canResize: Bool,
            canvas: CGRect?, geometry: AXGeometry
        ) -> CGRect? {
            switch self {
            case .external(_, let window):
                AXWindowAccess.write(
                    placement.frame, anchor: placement.anchor, to: window, current: current,
                    canResize: canResize, canvas: canvas)
            case .own(let window):
                Self.writeOwn(
                    placement, to: window, current: current, canResize: canResize,
                    canvas: canvas, geometry: geometry)
            }
        }

        /// `setFrame` is atomic and local, so AX's size → position → size sequence buys nothing.
        private static func writeOwn(
            _ placement: WindowPlacementEngine.Placement, to window: NSWindow, current: CGRect,
            canResize: Bool, canvas: CGRect?, geometry: AXGeometry
        ) -> CGRect? {
            var target =
                canResize
                ? placement.frame : placement.anchor.place(current.size, in: placement.frame)
            if !canResize, let canvas {
                target = WindowPlacementEngine.clamped(target, into: canvas)
            }
            window.setFrame(geometry.flip(WindowPlacementEngine.rounded(target)), display: true)
            var actual = geometry.flip(window.frame)

            // `contentMinSize` can refuse the width or height; re-seat once, per the anchor.
            if actual.width > target.width + AXWindowAccess.clampTolerance
                || actual.height > target.height + AXWindowAccess.clampTolerance
            {
                var slot = placement.anchor.place(actual.size, in: placement.frame)
                if let canvas { slot = WindowPlacementEngine.clamped(slot, into: canvas) }
                window.setFrameOrigin(geometry.flip(WindowPlacementEngine.rounded(slot)).origin)
                actual = geometry.flip(window.frame)
            }
            return actual
        }
    }

    private var memory = WindowActionMemory<WindowKey>()
    private var terminationToken: NotificationToken?
    private var windowCloseToken: NotificationToken?
    private var displayResize: Task<Void, Never>?
    private var displayResizeID: UUID?
    private var fullScreenTransfer: Task<Void, Never>?
    private var fullScreenTransferID: UUID?
    private static let logger = Logger(subsystem: "com.tinycast", category: "WindowManagement")

    init() {
        // Drop a quit app's windows rather than waiting for LRU eviction to reclaim them.
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication
            else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated {
                self?.memory.forget { key in
                    guard case .external(let external) = key else { return false }
                    return external.pid == pid
                }
            }
        }
        terminationToken = NotificationToken(token, center: NSWorkspace.shared.notificationCenter)

        // A closed window's identifier can be reused, so drop its record while it is still ours.
        let closeToken = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let closed = note.object as? NSWindow else { return }
            let key = WindowKey.own(ObjectIdentifier(closed))
            Task { @MainActor [weak self] in self?.memory.forget(key: key) }
        }
        windowCloseToken = NotificationToken(closeToken, center: .default)
    }

    isolated deinit {
        displayResize?.cancel()
        fullScreenTransfer?.cancel()
    }

    /// The window a command targets, resolved once per press.
    private struct FocusedWindow {
        let surface: Surface
        let key: WindowKey
    }

    private typealias Resolver = (
        _ current: CGRect, _ screens: [WindowPlacementEngine.Screen],
        _ decision: WindowActionMemory<WindowKey>.Decision
    ) -> WindowPlacementEngine.Placement?

    /// Runs `command` against `target`'s focused window, returning whether anything changed.
    @discardableResult
    func perform(
        _ command: WindowCommand.ID, target: WindowTarget?, gap: CGFloat, cycle: WindowCycle
    ) -> Bool {
        if fullScreenTransfer != nil, command == .nextDisplay || command == .previousDisplay {
            return false
        }
        cancelDisplayResize()
        cancelFullScreenTransfer()
        guard let catalogued = WindowCommandCatalog.command(id: command),
            let focused = focusedWindow(of: target)
        else { return false }

        if catalogued.kind == .fullscreen {
            guard focused.surface.setFullScreen(!focused.surface.isFullScreen) else { return false }
            // The size chain is moot, but the pre-Tinycast frame is still the Restore target.
            memory.forgetCycle(key: focused.key)
            return true
        }
        if focused.surface.isFullScreen, command == .nextDisplay || command == .previousDisplay {
            return moveFullScreen(focused, command: command, gap: gap)
        }
        return place(
            focused, command: command, gap: gap,
            cycleLength: {
                WindowPlacementEngine.cycleLength(for: command, screens: $0, cycle: cycle)
            }
        ) { current, screens, decision in
            WindowPlacementEngine.placement(
                for: WindowPlacementEngine.Input(
                    command: command, windowFrame: current, screens: screens, gap: gap,
                    step: decision.step, cycle: cycle, originScreenID: decision.originScreenID,
                    restoreFrame: decision.canRestore ? decision.restoreFrame : nil,
                    lastTileCommand: decision.lastTileCommand))
        }
    }

    /// Applies `size` to `target`'s focused window; Restore undoes it like any command.
    @discardableResult
    func perform(_ size: CustomWindowSize, target: WindowTarget?, gap: CGFloat) -> Bool {
        cancelDisplayResize()
        cancelFullScreenTransfer()
        guard let focused = focusedWindow(of: target) else { return false }
        return place(
            focused, command: nil, gap: gap, cycleLength: { _ in 1 },
            resolve: { current, screens, _ in
                size.placement(for: current, screens: screens, gap: gap)
            })
    }

    private func focusedWindow(of target: WindowTarget?) -> FocusedWindow? {
        switch target {
        case .own(let window):
            // No Accessibility grant is involved in placing one of our own windows.
            guard window.isVisible else { return nil }
            return FocusedWindow(surface: .own(window), key: .own(ObjectIdentifier(window)))
        case .external(let app):
            // Invoked from an explicit user gesture, so prompting for the grant is right here.
            guard Permissions.ensureAccessibility() else { return nil }
            guard !app.isTerminated,
                app.processIdentifier != ProcessInfo.processInfo.processIdentifier
            else { return nil }

            let application = AXWindowAccess.application(for: app.processIdentifier)
            guard let window = AXWindowAccess.targetWindow(in: application) else { return nil }
            AXUIElementSetMessagingTimeout(window, AXWindowAccess.messagingTimeout)
            return FocusedWindow(
                surface: .external(application: application, window: window),
                key: .external(ExternalKey(pid: app.processIdentifier, element: window)))
        case nil:
            return nil
        }
    }

    /// The one decide → resolve → write → commit sequence every geometry press runs through.
    private func place(
        _ focused: FocusedWindow, command: WindowCommand.ID?, gap: CGFloat,
        cycleLength: ([WindowPlacementEngine.Screen]) -> Int, resolve: Resolver
    ) -> Bool {
        let surface = focused.surface
        let systemScreens = NSScreen.screens
        let geometry = AXGeometry(screens: systemScreens)
        // Tiling a natively fullscreen window fights the window server; leave it alone.
        guard !surface.isFullScreen, let current = surface.frame(in: geometry) else { return false }

        let screens = AXScreens.converted(systemScreens, geometry: geometry)
        guard let host = WindowPlacementEngine.screen(containing: current, in: screens) else {
            return false
        }

        // One timestamp for the whole command, so the cycle timeout can't straddle two readings.
        let now = Date()
        let decision = memory.decide(
            key: focused.key, command: command, currentFrame: current, currentScreenID: host.id,
            cycleLength: cycleLength(screens), now: now)
        guard let placement = resolve(current, screens, decision) else { return false }

        // Checked before any write, so an unpositionable window is left untouched.
        guard surface.canMove else { return false }
        let canResize = placement.resizes && surface.canResize

        let destination = screens.first { $0.id == placement.screenID }
        let canvas = destination.map {
            WindowPlacementEngine.canvas(
                $0.visibleFrame,
                gap: WindowPlacementEngine.sanitizedGap(gap, in: $0.visibleFrame))
        }
        let restoreEnhancedUI = canResize ? surface.suppressEnhancedUserInterface() : {}
        defer { restoreEnhancedUI() }

        guard
            let applied = surface.write(
                placement, current: current, canResize: canResize, canvas: canvas,
                geometry: geometry)
        else { return false }

        let landedOn =
            WindowPlacementEngine.screen(containing: applied, in: screens)?.id
            ?? placement.screenID
        memory.commit(
            key: focused.key, command: command, decision: decision, appliedFrame: applied,
            screenID: landedOn, now: now)
        if let command, command == .nextDisplay || command == .previousDisplay,
            host.id != placement.screenID, let destination, canResize,
            case .external = surface,
            applied.width < placement.frame.width - AXWindowAccess.clampTolerance
                || applied.height < placement.frame.height - AXWindowAccess.clampTolerance
        {
            scheduleDisplayResize(
                focused, command: command, decision: decision, placement: placement,
                applied: applied, destination: destination, canvas: canvas)
        }
        return !applied.equalTo(current)
    }

    private func cancelDisplayResize() {
        displayResize?.cancel()
        displayResize = nil
        displayResizeID = nil
    }

    private func scheduleDisplayResize(
        _ focused: FocusedWindow, command: WindowCommand.ID,
        decision: WindowActionMemory<WindowKey>.Decision,
        placement: WindowPlacementEngine.Placement, applied: CGRect,
        destination: WindowPlacementEngine.Screen, canvas: CGRect?
    ) {
        let id = UUID()
        displayResizeID = id
        displayResize = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled, let self, self.displayResizeID == id else { return }
            defer {
                self.displayResize = nil
                self.displayResizeID = nil
            }

            let systemScreens = NSScreen.screens
            let geometry = AXGeometry(screens: systemScreens)
            let screens = AXScreens.converted(systemScreens, geometry: geometry)
            let surface = focused.surface
            guard screens.contains(destination), !surface.isFullScreen,
                surface.canMove, surface.canResize,
                let current = surface.frame(in: geometry), current.equalTo(applied),
                WindowPlacementEngine.screen(containing: current, in: screens)?.id == destination.id
            else { return }

            let restoreEnhancedUI = surface.suppressEnhancedUserInterface()
            defer { restoreEnhancedUI() }
            guard let actual = surface.write(
                placement, current: current, canResize: true, canvas: canvas, geometry: geometry)
            else { return }
            let landedOn =
                WindowPlacementEngine.screen(containing: actual, in: screens)?.id
                ?? placement.screenID
            self.memory.commit(
                key: focused.key, command: command, decision: decision, appliedFrame: actual,
                screenID: landedOn, now: Date())
            Self.logger.debug("Deferred display frame: \(NSStringFromRect(actual), privacy: .public)")
        }
    }

    // MARK: - Fullscreen

    private func cancelFullScreenTransfer() {
        fullScreenTransfer?.cancel()
        fullScreenTransfer = nil
        fullScreenTransferID = nil
    }

    private func moveFullScreen(
        _ focused: FocusedWindow, command: WindowCommand.ID, gap: CGFloat
    ) -> Bool {
        let systemScreens = NSScreen.screens
        let geometry = AXGeometry(screens: systemScreens)
        let screens = AXScreens.converted(systemScreens, geometry: geometry)
        guard let current = focused.surface.frame(in: geometry),
            let source = WindowPlacementEngine.screen(containing: current, in: screens),
            let placement = WindowPlacementEngine.placement(
                for: .init(command: command, windowFrame: current, screens: screens, gap: gap)),
            placement.screenID != source.id, focused.surface.setFullScreen(false)
        else { return false }

        memory.forgetCycle(key: focused.key)
        let id = UUID()
        fullScreenTransferID = id
        Self.logger.debug("Moving fullscreen from display \(source.id) to \(placement.screenID)")
        let transfer = FullScreenTransfer(
            surface: focused.surface, command: command, gap: gap, displays: screens,
            sourceID: source.id, destinationID: placement.screenID)
        fullScreenTransfer = Task { @MainActor [weak self] in
            let result = await transfer.run { [weak self] in self?.fullScreenTransferID == id }
            guard let self, self.fullScreenTransferID == id else { return }
            self.fullScreenTransfer = nil
            self.fullScreenTransferID = nil
            guard let result else { return }
            let now = Date()
            let decision = self.memory.decide(
                key: focused.key, command: command, currentFrame: result.original,
                currentScreenID: transfer.sourceID, cycleLength: 1, now: now)
            self.memory.commit(
                key: focused.key, command: command, decision: decision, appliedFrame: result.applied,
                screenID: transfer.destinationID, now: now)
            Self.logger.debug("Fullscreen moved to display \(transfer.destinationID)")
        }
        return true
    }

    @MainActor
    private struct FullScreenTransfer {
        let surface: Surface
        let command: WindowCommand.ID
        let gap: CGFloat
        let displays: [WindowPlacementEngine.Screen]
        let sourceID: Int
        let destinationID: Int

        func run(isCurrent: () -> Bool) async -> (original: CGRect, applied: CGRect)? {
            guard let original = await settledFrame(
                fullScreen: false, displayID: sourceID, delay: .milliseconds(500), isCurrent: isCurrent)
            else {
                restoreFullScreen(isCurrent: isCurrent)
                return nil
            }
            let (screens, geometry) = environment()
            WindowMover.logger.debug("Exited fullscreen: \(NSStringFromRect(original), privacy: .public)")
            guard valid(screens, isCurrent: isCurrent), surface.canMove, surface.canResize,
                let placement = WindowPlacementEngine.placement(
                    for: .init(command: command, windowFrame: original, screens: screens, gap: gap)),
                placement.screenID == destinationID,
                let destination = screens.first(where: { $0.id == destinationID })
            else {
                restoreFullScreen(isCurrent: isCurrent)
                return nil
            }
            let canvas = WindowPlacementEngine.canvas(
                destination.visibleFrame,
                gap: WindowPlacementEngine.sanitizedGap(gap, in: destination.visibleFrame))
            guard var applied = write(placement, current: original, canvas: canvas, geometry: geometry)
            else {
                restoreFullScreen(isCurrent: isCurrent)
                return nil
            }

            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
            let (landedScreens, landedGeometry) = environment()
            guard valid(landedScreens, isCurrent: isCurrent) else {
                restoreFullScreen(isCurrent: isCurrent)
                return nil
            }
            guard !surface.isFullScreen,
                let current = surface.frame(in: landedGeometry), current.equalTo(applied)
            else { return nil }
            guard WindowPlacementEngine.screen(containing: current, in: landedScreens)?.id == destinationID
            else {
                restoreFullScreen(isCurrent: isCurrent)
                return nil
            }
            if case .external = surface,
                applied.width < placement.frame.width - AXWindowAccess.clampTolerance
                    || applied.height < placement.frame.height - AXWindowAccess.clampTolerance,
                surface.canMove, surface.canResize,
                let corrected = write(placement, current: current, canvas: canvas, geometry: landedGeometry)
            {
                applied = corrected
            }
            guard let settled = await settledFrame(
                fullScreen: false, displayID: destinationID, delay: .milliseconds(150),
                isCurrent: isCurrent)
            else {
                if !valid(environment().0, isCurrent: isCurrent) {
                    restoreFullScreen(isCurrent: isCurrent)
                }
                return nil
            }
            guard settled.equalTo(applied), surface.setFullScreen(true) else { return nil }
            WindowMover.logger.debug("Entering fullscreen after move: \(NSStringFromRect(settled), privacy: .public)")
            guard await settledFrame(
                fullScreen: true, displayID: destinationID, delay: .milliseconds(500),
                isCurrent: isCurrent) != nil
            else { return nil }
            return (original, applied)
        }

        private func environment() -> ([WindowPlacementEngine.Screen], AXGeometry) {
            let systemScreens = NSScreen.screens
            let geometry = AXGeometry(screens: systemScreens)
            return (AXScreens.converted(systemScreens, geometry: geometry), geometry)
        }

        private func valid(_ screens: [WindowPlacementEngine.Screen], isCurrent: () -> Bool) -> Bool {
            !Task.isCancelled && isCurrent() && screens.count == displays.count
                && displays.allSatisfy { display in
                    screens.contains { $0.id == display.id && $0.frame == display.frame }
                }
        }

        private func settledFrame(
            fullScreen: Bool, displayID: Int, delay: Duration, isCurrent: () -> Bool
        ) async -> CGRect? {
            let started = ContinuousClock.now
            let deadline = started.advanced(by: .seconds(5))
            var previous: CGRect?
            var stableSince = started
            while ContinuousClock.now < deadline {
                let (screens, geometry) = environment()
                guard valid(screens, isCurrent: isCurrent), let frame = surface.frame(in: geometry)
                else { return nil }
                let now = ContinuousClock.now
                if surface.isFullScreen != fullScreen || previous != frame {
                    stableSince = now
                }
                previous = frame
                if surface.isFullScreen == fullScreen,
                    WindowPlacementEngine.screen(containing: frame, in: screens)?.id == displayID,
                    now - started >= delay, now - stableSince >= .milliseconds(150)
                {
                    return frame
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
            }
            WindowMover.logger.debug("Fullscreen display transfer timed out")
            return nil
        }

        private func write(
            _ placement: WindowPlacementEngine.Placement, current: CGRect, canvas: CGRect,
            geometry: AXGeometry
        ) -> CGRect? {
            let restoreEnhancedUI = surface.suppressEnhancedUserInterface()
            defer { restoreEnhancedUI() }
            return surface.write(
                placement, current: current, canResize: true, canvas: canvas, geometry: geometry)
        }

        private func restoreFullScreen(isCurrent: () -> Bool) {
            guard !Task.isCancelled, isCurrent(),
                surface.frame(in: environment().1) != nil
            else { return }
            _ = surface.setFullScreen(true)
        }
    }
}
