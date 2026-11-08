import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

final class DashboardLayoutTests: XCTestCase {
    @MainActor
    func testDisclosureHeaderRespondsToBlankSpaceAndKeepsContentInteractive() async throws {
        _ = NSApplication.shared
        let state = DisclosureProbeState()
        let controller = NSHostingController(rootView: DisclosureClickProbe(state: state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 120),
            styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutSubtreeIfNeeded()

        // The middle and trailing space, arrow and title must each toggle once.
        for x: CGFloat in [160, 315, 5, 30, 160] {
            let wasExpanded = state.isExpanded
            try click(at: NSPoint(x: x, y: 108), in: window)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(state.isExpanded, !wasExpanded)
        }
        XCTAssertTrue(state.isExpanded)
        try click(at: NSPoint(x: 30, y: 84), in: window)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.contentClicks, 1)
        XCTAssertTrue(state.isExpanded, "Clicking expanded content must not toggle its header")
    }

    @MainActor
    private func click(at point: NSPoint, in window: NSWindow) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
        // Native button tracking can wait for mouse-up before sendEvent returns.
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            window.sendEvent(pending)
        }
    }

    func testPanelFitsCommonScreenHeights() {
        for visibleHeight: CGFloat in [600, 768, 900, 1080, 1440] {
            let size = DashboardPanelLayout.size(visibleHeight: visibleHeight)
            XCTAssertEqual(size.width, 348)
            XCTAssertGreaterThanOrEqual(size.height, 400)
            XCTAssertLessThanOrEqual(size.height, visibleHeight - 80)
            XCTAssertLessThanOrEqual(size.height, 680)
        }
        for invalid: CGFloat? in [nil, 0, -.infinity, .nan] {
            XCTAssertEqual(DashboardPanelLayout.size(visibleHeight: invalid).height, 680)
        }
    }

    @MainActor
    func testRealPopoverShowsBodyOnFirstOpenAndReopen() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "usageWindowsExpanded")
        defaults.set(true, forKey: "usageWindowsExpanded")
        defer {
            if let saved { defaults.set(saved, forKey: "usageWindowsExpanded") }
            else { defaults.removeObject(forKey: "usageWindowsExpanded") }
        }

        let screen = try XCTUnwrap(NSScreen.main, "A WindowServer is required for the macOS layout check")
        let anchor = NSWindow(
            contentRect: NSRect(x: screen.visibleFrame.minX + 100, y: screen.visibleFrame.maxY - 30, width: 80, height: 20),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        anchor.isReleasedWhenClosed = false
        anchor.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        anchor.orderFrontRegardless()
        defer { anchor.close() }

        // Cover cold startup with no quota, populated quota/chart and a smaller
        // viewport, before and after closing and reopening the real popover.
        for preview in [false, true] {
            let store = UsageStore(previewMode: preview)
            let size = DashboardPanelLayout.size(visibleHeight: min(600, screen.visibleFrame.height))
            let controller = DashboardPanelLayout.controller(store: store, size: size)
            let popover = NSPopover()
            popover.animates = false
            popover.behavior = .applicationDefined
            popover.contentViewController = controller
            popover.contentSize = size
            defer { popover.close() }
            for _ in 0..<2 {
                let view = try XCTUnwrap(anchor.contentView)
                popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                try await Task.sleep(for: .milliseconds(250))
                controller.view.layoutSubtreeIfNeeded()
                XCTAssertTrue(popover.isShown)
                XCTAssertEqual(popover.contentSize.height, size.height, accuracy: 2)
                XCTAssertGreaterThan(controller.view.bounds.height, 300)
                let scroll = try XCTUnwrap(findScrollView(in: controller.view))
                XCTAssertGreaterThan(scroll.contentSize.height, 200, "The body must not collapse to a header-only popover")
                XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).frame.height, 180)
                popover.close()
            }
        }
    }

    @MainActor
    func testExpandedDocumentScrollsWithoutShrinkingViewport() async throws {
        _ = NSApplication.shared
        let size = NSSize(width: 348, height: 480)
        let panel = DashboardPanel(height: size.height) {
            Text("QuotaBar").padding(16)
        } content: {
            // Daily details and settings can be much taller than the screen.
            VStack {
                ForEach(0..<40) { index in
                    Text("Daily record \(index)").frame(height: 30)
                }
                Text("Account totals").frame(height: 80)
            }
        } footer: {
            FooterProbe().frame(height: 44)
        }
        let controller = NSHostingController(rootView: panel)
        controller.view.setFrameSize(size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(findScrollView(in: controller.view))
        let document = try XCTUnwrap(scroll.documentView)
        let footer = try XCTUnwrap(findFooter(in: controller.view))
        let footerFrame = controller.view.convert(footer.bounds, from: footer)
        XCTAssertTrue(footer.isDescendant(of: document), "Settings must belong to the same scroll document")
        XCTAssertFalse(scroll.documentVisibleRect.intersects(document.convert(footer.bounds, from: footer)), "Overflowing content must push settings below the visible area")
        XCTAssertGreaterThan(scroll.contentSize.height, 300)
        XCTAssertGreaterThan(document.frame.height, 1_000)
        XCTAssertLessThan(scroll.contentSize.height, size.height)
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 0, "Account totals must be reachable by scrolling")
        XCTAssertEqual(controller.view.bounds.height, size.height, accuracy: 2)
        let scrolledFooterFrame = controller.view.convert(footer.bounds, from: footer)
        XCTAssertNotEqual(scrolledFooterFrame, footerFrame, "Settings must move when the document scrolls")
        XCTAssertTrue(scroll.documentVisibleRect.intersects(document.convert(footer.bounds, from: footer)), "Scrolling to the end must reveal settings")
        assertFooterAtBottom(scrolledFooterFrame, in: controller.view)
    }

    @MainActor
    func testShortContentKeepsSettingsAtBottom() async throws {
        _ = NSApplication.shared
        let panel = DashboardPanel(height: 480) {
            Text("QuotaBar").frame(height: 50)
        } content: {
            Text("Collapsed usage windows and history").frame(height: 80)
        } footer: {
            FooterProbe().frame(height: 44)
        }
        let controller = NSHostingController(rootView: panel)
        controller.view.setFrameSize(NSSize(width: 348, height: 480))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutSubtreeIfNeeded()
        let footer = try XCTUnwrap(findFooter(in: controller.view))
        assertFooterAtBottom(controller.view.convert(footer.bounds, from: footer), in: controller.view)
    }

    @MainActor
    func testPopoverResizesFromExpansionStateWithoutHeightFeedback() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["usageWindowsExpanded", "accountUsageHistoryExpanded", "settingsExpanded"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: keys[0])
        defaults.set(true, forKey: keys[1])
        defaults.set(false, forKey: keys[2])
        let screen = try XCTUnwrap(NSScreen.main)
        let anchor = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 100,
            y: screen.visibleFrame.maxY - 30, width: 80, height: 20), styleMask: .borderless, backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false
        anchor.orderFrontRegardless()
        defer { anchor.close() }
        let size = DashboardPanelLayout.size(visibleHeight: min(600, screen.visibleFrame.height))
        let controller = DashboardPanelLayout.controller(store: UsageStore(previewMode: true), size: size)
        let popover = NSPopover()
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = size
        let view = try XCTUnwrap(anchor.contentView)
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        defer { popover.close() }
        try await Task.sleep(for: .milliseconds(250))
        defaults.set(false, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(popover.contentSize.height, DashboardPanelLayout.compactHeight, accuracy: 2)
        XCTAssertGreaterThan(try XCTUnwrap(findScrollView(in: controller.view)).contentSize.height, 70)
        defaults.set(true, forKey: keys[2])
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(popover.contentSize.height, size.height, accuracy: 2)
        XCTAssertGreaterThan(try XCTUnwrap(findScrollView(in: controller.view)).contentSize.height, 100)
    }

    @MainActor
    func testExpandedSettingsUseTheMainScrollDocument() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let keys = ["usageWindowsExpanded", "accountUsageHistoryExpanded", "settingsExpanded"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(false, forKey: keys[0])
        defaults.set(false, forKey: keys[1])
        defaults.set(true, forKey: keys[2])
        let controller = DashboardPanelLayout.controller(store: UsageStore(previewMode: true),
            size: NSSize(width: 348, height: 400))
        let window = NSWindow(contentViewController: controller)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        controller.view.layoutSubtreeIfNeeded()
        let scrolls = allScrollViews(in: controller.view)
        XCTAssertEqual(scrolls.count, 1, "Expanded settings must not introduce their own scrolling region")
        let scroll = try XCTUnwrap(scrolls.first)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
        document.scroll(NSPoint(x: 0, y: document.frame.height))
        XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 0)
        XCTAssertEqual(controller.view.bounds.height, 400, accuracy: 2)
    }

    @MainActor
    private func assertFooterAtBottom(_ frame: NSRect, in view: NSView) {
        let inset = view.isFlipped ? view.bounds.maxY - frame.maxY : frame.minY - view.bounds.minY
        XCTAssertEqual(inset, 6, accuracy: 2)
    }

    @MainActor
    private func findFooter(in view: NSView) -> NSView? {
        if view.identifier?.rawValue == "flowing-settings" { return view }
        for child in view.subviews {
            if let footer = findFooter(in: child) { return footer }
        }
        return nil
    }

    @MainActor
    private func allScrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { allScrollViews(in: $0) }
    }

    @MainActor
    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScrollView(in: child) { return scroll }
        }
        return nil
    }
}

@MainActor
private final class DisclosureProbeState: ObservableObject {
    @Published var isExpanded = false
    @Published var contentClicks = 0
}

@MainActor
private struct DisclosureClickProbe: View {
    @ObservedObject var state: DisclosureProbeState

    var body: some View {
        DisclosureGroup(isExpanded: $state.isExpanded) {
            Button {
                state.contentClicks += 1
            } label: {
                Text("Content action").frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
            }
            .buttonStyle(.plain)
        } label: {
            HStack {
                Text("Title")
                Spacer()
                Text("Detail")
            }
        }
        .disclosureGroupStyle(FullRowDisclosureStyle())
        .frame(width: 320, height: 120, alignment: .topLeading)
    }
}

private struct FooterProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("flowing-settings")
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
