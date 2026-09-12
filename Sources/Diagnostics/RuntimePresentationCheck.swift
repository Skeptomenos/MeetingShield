import AppKit
import Darwin
import Foundation
import SwiftUI

@MainActor
final class RuntimePresentationCheck {
    static let argument = "--runtime-presentation-check"
    static var isRequested: Bool { CommandLine.arguments.contains(argument) }

    private enum Command: String {
        case unchanged, edit, linkless, remove, move, observe, finish, arrival, retime, overdue, menu, copies, retry
        case endSoon = "end-soon"
        case overdueRemove = "overdue-remove"
        case failLaunch = "fail-launch"
        case allowLaunch = "allow-launch"
        case alertAgainSecond = "alert-again-second"
        case restartState = "restart-state"
        case newCopy = "new-copy"
        case removeFirstCopy = "remove-first-copy"
        case presentationOn = "presentation-on"
        case presentationOff = "presentation-off"
        case timeoutBeforeRetry = "timeout-before-retry"
    }

    private struct WindowSnapshot: Encodable {
        var kind: String
        var number: Int
        var level: Int
        var isVisible: Bool
        var isKey: Bool
        var occlusionVisible: Bool
        var orderedIndex: Int?
    }

    private struct Snapshot: Encodable {
        var phase: String
        var preferenceDomain: String
        var observedAt: Date
        var active: [CalendarEventOccurrence]
        var events: [CalendarEventOccurrence]
        var activeMemberIDs: [String: [String]]
        var isPresentationMode: Bool
        var selectedID: String?
        var windowNumbers: [Int]
        var keyWindowNumber: Int?
        var recordedURLs: [URL]
        var failedLaunchCount: Int
        var launchFailureEnabled: Bool
        var recordedSoundTimes: [Date]
        var pendingUrgentSoundDate: Date?
        var fallbackID: String?
        var fallbackErrorMessage: String?
        var fallbackIsShowing: Bool
        var windows: [WindowSnapshot]
        var canAlertAgainIDs: [String]
        var storedAcknowledgements: [String: OccurrenceReminderState.Acknowledgement]
        var statePersistencePending: Bool
        var controllerGeneration: Int
    }

    private var controller: MeetingShieldController?
    private var domain: String?
    private let soundRecorder = PresentationSoundRecorder()
    private var stateStore: ReminderStateStore?
    private var fixtureKeys: Set<OccurrenceKey> = []
    private var menuWindow: NSWindow?
    private var controllerGeneration = 0

    func run() async {
        guard !NSScreen.screens.isEmpty else {
            emit("result=blocked reason=window_server_required")
            exit(78)
        }
        do {
            try await replay()
            cleanup()
            emit("result=completed")
            NSApp.terminate(nil)
        } catch {
            cleanup()
            emit("result=failed reason=runtime_error")
            exit(1)
        }
    }

    private func replay() async throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
        let domain = "com.skeptomenos.meetingshield.presentation.\(UUID().uuidString)"
        self.domain = domain
        guard UserDefaults(suiteName: domain) != nil else { throw CalendarProviderError.invalidResponse }
        let settings = AppSettingsStore(domainName: domain)
        settings.update {
            $0.defaultLeadTime = 900
            $0.defaultBrowserSelection = .systemDefault
            $0.selectedCalendarIDs = ["primary", "secondary"]
            $0.soundEnabled = true
            $0.urgentRepeatSoundEnabled = true
            $0.wakeGraceEnabled = false
            $0.presentationModeDefault = false
        }
        let anchor = Date()
        let first = CalendarEventOccurrence.sample(
            eventID: "presentation-first", title: "Synthetic first meeting",
            startDate: anchor.addingTimeInterval(300),
            location: "https://example.com/meeting-shield-demo/first",
            htmlLink: URL(string: "https://example.com/meeting-shield-demo/first-event")
        )
        let second = CalendarEventOccurrence.sample(
            eventID: "presentation-second", title: "Synthetic second meeting",
            startDate: anchor.addingTimeInterval(420),
            htmlLink: URL(string: "https://example.com/meeting-shield-demo/second-event")
        )
        var fixtureSnapshot = [first, second]
        let provider = PresentationCalendarProvider(events: fixtureSnapshot)
        let recording = RuntimeRecordingBrowserLauncher()
        fixtureKeys = Set([first.occurrenceKey, second.occurrenceKey])
        var controller = makeController(settings: settings, provider: provider, recording: recording, root: root)
        self.controller = controller
        await controller.refresh(reason: "runtime-check")
        try writeSnapshot(phase: "initial", recording: recording)
        emit("checkpoint=initial")
        let commandURL = root.appending(path: "presentation-command.txt")
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            guard let text = try readCommand(at: commandURL) else { continue }
            guard let command = Command(rawValue: text) else { throw CalendarProviderError.invalidResponse }
            try FileManager.default.removeItem(at: commandURL)
            if command == .finish {
                try writeSnapshot(phase: text, recording: recording)
                return
            }
            if command == .unchanged {
                await controller.refresh(reason: "runtime-check")
            } else if command == .failLaunch || command == .allowLaunch {
                recording.shouldFail = command == .failLaunch
            } else if command == .alertAgainSecond {
                controller.alertAgain(second)
            } else if command == .restartState {
                closeMenu()
                controller.clearFallback()
                FullScreenAlertWindowController.shared.hide()
                controller = makeController(settings: settings, provider: provider, recording: recording, root: root)
                self.controller = controller
                await controller.refresh(reason: "runtime-check")
            } else if command == .menu {
                showMenu(controller: controller)
            } else if command == .presentationOn || command == .presentationOff {
                controller.isPresentationMode = command == .presentationOn
            } else if command == .timeoutBeforeRetry {
                controller.fireFallbackTimeoutForRuntimeCheck()
                controller.openAgainFromFallback()
                try await Task.sleep(for: .milliseconds(100))
            } else if command == .retry {
                controller.openAgainFromFallback()
            } else if command == .copies || command == .newCopy || command == .removeFirstCopy {
                if command == .copies {
                    var copyA = first
                    copyA.eventID = "presentation-copy-a"
                    copyA.title = "Synthetic copy A"
                    copyA.iCalUID = "presentation-true-copy"
                    copyA.startDate = Date().addingTimeInterval(180)
                    copyA.endDate = copyA.startDate.addingTimeInterval(1800)
                    var copyB = copyA
                    copyB.eventID = "presentation-copy-b"
                    copyB.calendarID = "secondary"
                    copyB.title = "Synthetic copy B"
                    var unrelated = copyA
                    unrelated.eventID = "presentation-unrelated-c"
                    unrelated.title = "Synthetic unrelated C"
                    unrelated.iCalUID = "presentation-unrelated"
                    unrelated.location = "https://example.com/meeting-shield-demo/unrelated-c"
                    unrelated.htmlLink = URL(string: "https://example.com/meeting-shield-demo/unrelated-c-event")
                    fixtureSnapshot = [copyA, copyB, unrelated]
                } else if command == .newCopy {
                    guard var copy = fixtureSnapshot.first(where: { $0.iCalUID == "presentation-true-copy" }) else {
                        throw CalendarProviderError.invalidResponse
                    }
                    copy.eventID = "presentation-copy-d"
                    copy.title = "Synthetic new copy D"
                    if !fixtureSnapshot.contains(where: { $0.eventID == copy.eventID }) {
                        fixtureSnapshot.append(copy)
                    }
                } else {
                    fixtureSnapshot.removeAll { $0.eventID == "presentation-copy-a" }
                }
                fixtureKeys.formUnion(fixtureSnapshot.map(\.occurrenceKey))
                await provider.replace(fixtureSnapshot)
                await controller.refresh(reason: "runtime-check")
            } else if command != .observe {
                var changed = second
                switch command {
                case .edit:
                    guard let updatedURL = URL(string: "https://example.com/meeting-shield-demo/updated-second") else {
                        throw CalendarProviderError.invalidResponse
                    }
                    changed.title = "Updated second meeting"
                    changed.startDate = anchor.addingTimeInterval(480)
                    changed.calendarDisplayName = "Updated calendar"
                    changed.conferenceLinks = [MeetingLink(
                        url: updatedURL, kind: .googleMeet, source: .conferenceMetadata
                    )]
                case .linkless:
                    changed.title = "Updated linkless meeting"
                    changed.htmlLink = URL(string: "https://example.com/meeting-shield-demo/updated-event")
                case .move:
                    changed.calendarID = "secondary"
                    changed.calendarDisplayName = "Moved calendar"
                case .endSoon:
                    changed.title = "Ending selected meeting"
                    changed.startDate = Date().addingTimeInterval(-10)
                    changed.endDate = Date().addingTimeInterval(3)
                case .retime:
                    changed.startDate = Date().addingTimeInterval(14)
                case .overdue, .overdueRemove:
                    changed.startDate = Date().addingTimeInterval(12)
                case .unchanged, .remove, .observe, .finish, .arrival, .menu,
                     .failLaunch, .allowLaunch, .alertAgainSecond, .restartState,
                     .copies, .newCopy, .removeFirstCopy, .presentationOn, .presentationOff, .timeoutBeforeRetry, .retry:
                    break
                }
                var snapshot = command == .remove ? [first] : [first, changed]
                if command == .arrival {
                    snapshot.append(.sample(
                        eventID: "presentation-arrival", title: "Synthetic arriving meeting",
                        startDate: Date().addingTimeInterval(14),
                        htmlLink: URL(string: "https://example.com/meeting-shield-demo/arrival-event")
                    ))
                }
                fixtureSnapshot = snapshot
                fixtureKeys.formUnion(snapshot.map(\.occurrenceKey))
                await provider.replace(snapshot)
                await controller.refresh(reason: "runtime-check")
                if command == .overdue || command == .overdueRemove {
                    guard let pending = controller.pendingUrgentSoundDate else { throw CalendarProviderError.invalidResponse }
                    try writeSnapshot(phase: "overdue-armed", recording: recording)
                    try FileManager.default.copyItem(
                        at: root.appending(path: "presentation-observed.json"),
                        to: root.appending(path: "overdue-armed.json")
                    )
                    try delayRunLoop(until: pending.addingTimeInterval(0.15))
                    if command == .overdueRemove {
                        settings.update { $0.selectedCalendarIDs = ["secondary"] }
                    }
                    controller.handleSettingsChanged()
                }
            }
            try writeSnapshot(phase: text, recording: recording)
            emit("checkpoint=\(text)")
        }
        throw CalendarProviderError.invalidResponse
    }

    private func writeSnapshot(phase: String, recording: RuntimeRecordingBrowserLauncher) throws {
        guard let controller, let domain, let stateStore else { throw CalendarProviderError.invalidResponse }
        let now = Date()
        let orderedWindows = NSApp.orderedWindows
        let windows = NSApp.windows.compactMap { window -> WindowSnapshot? in
            let kind: String
            if window is KeyableAlertWindow {
                kind = "alert"
            } else if window.contentView is NSHostingView<JoinFallbackView> {
                kind = "fallback"
            } else if window === menuWindow {
                kind = "menu"
            } else {
                return nil
            }
            return WindowSnapshot(
                kind: kind, number: window.windowNumber, level: window.level.rawValue,
                isVisible: window.isVisible, isKey: window.isKeyWindow,
                occlusionVisible: window.occlusionState.contains(.visible),
                orderedIndex: orderedWindows.firstIndex(where: { $0 === window })
            )
        }.sorted { $0.number < $1.number }
        let acknowledgements = Dictionary(uniqueKeysWithValues: fixtureKeys.compactMap { key in
            stateStore.state(for: key)?.acknowledgement.map { (key.description, $0) }
        })
        let snapshot = Snapshot(
            phase: phase, preferenceDomain: domain, observedAt: now,
            active: controller.activeReminders.map(\.event),
            events: controller.events,
            activeMemberIDs: Dictionary(uniqueKeysWithValues: controller.activeReminders.map {
                ($0.id, $0.members.map(\.id).sorted())
            }),
            isPresentationMode: controller.isPresentationMode,
            selectedID: FullScreenAlertWindowController.shared.selectedReminderID,
            windowNumbers: NSApp.windows.filter { $0 is KeyableAlertWindow && $0.isVisible }.map(\.windowNumber).sorted(),
            keyWindowNumber: NSApp.keyWindow?.windowNumber,
            recordedURLs: recording.requests,
            failedLaunchCount: recording.failureCount,
            launchFailureEnabled: recording.shouldFail,
            recordedSoundTimes: soundRecorder.times,
            pendingUrgentSoundDate: controller.pendingUrgentSoundDate,
            fallbackID: controller.fallback?.reminder.id,
            fallbackErrorMessage: controller.fallback?.errorMessage,
            fallbackIsShowing: JoinFallbackWindowController.shared.isShowing,
            windows: windows,
            canAlertAgainIDs: controller.events.filter { controller.canAlertAgain($0, now: now) }.map(\.id).sorted(),
            storedAcknowledgements: acknowledgements,
            statePersistencePending: stateStore.isPersistencePending,
            controllerGeneration: controllerGeneration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(
            to: FileManager.default.homeDirectoryForCurrentUser.appending(path: "presentation-observed.json"), options: .atomic
        )
    }

    private func cleanup() {
        closeMenu()
        controller?.clearFallback()
        FullScreenAlertWindowController.shared.hide()
        controller = nil
        stateStore = nil
        if let domain { UserDefaults.standard.removePersistentDomain(forName: domain) }
    }

    private func makeController(
        settings: AppSettingsStore, provider: PresentationCalendarProvider,
        recording: RuntimeRecordingBrowserLauncher, root: URL
    ) -> MeetingShieldController {
        let stateStore = ReminderStateStore(fileURL: root.appending(path: "presentation-state.json"))
        self.stateStore = stateStore
        controllerGeneration += 1
        return MeetingShieldController(
            settingsStore: settings, provider: provider, reminderStateStore: stateStore,
            cacheStore: EventCacheStore(fileURL: root.appending(path: "presentation-cache.json")),
            notificationService: NoopNotificationService(),
            launcher: MeetingLauncher(profileService: BrowserProfileService(homeDirectory: root), browserLauncher: recording),
            soundPlayer: soundRecorder, refreshMenuBar: {}
        )
    }

    private func showMenu(controller: MeetingShieldController) {
        closeMenu()
        let height = MenuContentView.preferredHeight(eventCount: controller.menuEvents.count)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: MenuContentView.preferredWidth, height: height),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Meeting Shield synthetic agenda"
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = NSHostingView(rootView: MenuContentView(
            controller: controller, popoverHeight: height,
            closeMenu: { [weak window] in window?.close() }
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        menuWindow = window
    }

    private func closeMenu() {
        menuWindow?.close()
        menuWindow = nil
    }

    private func readCommand(at url: URL) throws -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw CalendarProviderError.invalidResponse
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else { throw CalendarProviderError.invalidResponse }
        var bytes = [UInt8](repeating: 0, count: 65)
        let count = read(descriptor, &bytes, bytes.count)
        guard count >= 0, count <= 64,
              let text = String(bytes: bytes.prefix(count), encoding: .utf8) else { throw CalendarProviderError.invalidResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func delayRunLoop(until date: Date) throws {
        guard (0...3).contains(date.timeIntervalSinceNow) else { throw CalendarProviderError.invalidResponse }
        Thread.sleep(until: date)
    }

    private func emit(_ value: String) {
        FileHandle.standardOutput.write(Data("PRESENTATION_REPLAY \(value)\n".utf8))
    }
}

private final class PresentationSoundRecorder: AlertSoundPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTimes: [Date] = []
    var times: [Date] { lock.withLock { recordedTimes } }
    func playAlertSound() { lock.withLock { recordedTimes.append(Date()) } }
}

private actor PresentationCalendarProvider: CalendarProvider {
    let providerID = "mock"
    private var snapshot: [CalendarEventOccurrence]

    init(events: [CalendarEventOccurrence]) { snapshot = events }
    var authState: CalendarProviderAuthState { get async { .connected(accountEmail: "mock@example.com") } }
    func accounts() async -> [ConnectedCalendarAccount] { [ConnectedCalendarAccount(id: "mock-account", displayName: "Synthetic account")] }
    func calendars() async throws -> [UserCalendar] {
        ["primary", "secondary"].map { UserCalendar(id: $0, accountID: "mock-account", displayName: $0, isPrimary: $0 == "primary", isSelected: true) }
    }
    func events(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] { snapshot }
    func refresh(in window: CalendarFetchWindow) async throws -> [CalendarEventOccurrence] { snapshot }
    func refresh(in window: CalendarFetchWindow, calendars: [UserCalendar]) async throws -> [CalendarEventOccurrence] {
        let ids = Set(calendars.map(\.id))
        return snapshot.filter { ids.contains($0.calendarID) }
    }
    func replace(_ events: [CalendarEventOccurrence]) { snapshot = events }
    func reconnect() async throws {}
    func removeAccount(id: String) async throws {}
}
