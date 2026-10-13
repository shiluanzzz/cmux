import CmuxNextBrowser
import CmuxNextDaemon
import Foundation
import WebKit

/// Restored WebKit pages that start from their saved history (cx-p0im9). The page is made
/// blank; once this Mac's daemon answers with the tab's saved history (`BrowserTabService`),
/// the page restores WebKit's own state, which brings back its real back list and each page's
/// state, or else loads its address. Either way the shown page loads once. A read slower than
/// `budget` loads the address, so a page never waits on the daemon for long.
final class BrowserHistoryStarts {
    static let budget: Duration = .seconds(1)

    private struct Waiting {
        weak var page: WebKitTab?
        let url: URL
        let timer: Task<Void, Never>
    }

    private var waiting: [String: Waiting] = [:]
    /// How each held page started, by tab id (`debug.browser.page_status` `history_start`).
    var outcomes: [String: String] = [:]
    /// Tabs whose new page restored its engine's own history, until `takeEngineRestored`.
    private var engineRestored: Set<String> = []

    /// The blank page for restored tab `tab` at `url`, waiting for its saved history; nil when
    /// the tab opens as before: a page the user opened now, a remote machine's tab, a
    /// proxied or machine page, an incognito tab, or a page that is neither a web page nor a
    /// local file.
    static func page(_ tab: TabModel, url: URL?, cache: TabContentCache) -> BrowserEntry? {
        let service = cache.browserTabs, key = tab.id, daemon = service.daemon(for: tab)
        let skip: String? = if let url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? ""), MachineBrowserRecord(url: url) == nil {
            cache.pageRequests.proxiedTabs.isProxied(key) || !tab.isFrontendOwned || service.isIncognitoTab(key) ? "skip-page-kind"
                : service.writers[key] != nil ? "skip-tracked" : service.wasOpenedHere(tab) ? "skip-opened-here"
                : !daemon.isLocal ? "skip-remote" : !daemon.supports(DaemonCapabilities.shared.frontendBrowserHistory) ? "skip-no-capability" : nil
        } else { "skip-address" }
        if let skip { service.historyStarts.outcomes[key] = skip }
        guard skip == nil, let url else { return nil }
        let page = cache.webKit.makeWebKitTab(id: BrowserTabID(rawValue: key), profile: cache.browserProfile?(key) ?? .default)
        service.historyStarts.hold(page, url: url, tabID: key)
        return cache.install(page, for: key)
    }

    /// `configuration` for restored Chromium tab `tab`, with the navigation state saved with its
    /// history when it was saved at the page's address (cx-il4fv): Chromium restores its back list
    /// and page state, and loads the address itself when it cannot. Tabs that open as before, as
    /// in `page`, and pages with a local file in their history (Chromium's file access is not
    /// bounded to a folder) keep `configuration`.
    static func chromium(_ tab: TabModel, _ configuration: BrowserTabConfiguration, cache: TabContentCache) async -> BrowserTabConfiguration {
        let service = cache.browserTabs, key = tab.id, daemon = service.daemon(for: tab)
        guard configuration.restoreState == nil, configuration.machineStore == nil, let url = configuration.initialURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), MachineBrowserRecord(url: url) == nil,
              tab.isFrontendOwned, !service.isIncognitoTab(key), !service.wasOpenedHere(tab), daemon.isLocal,
              daemon.supports(DaemonCapabilities.shared.frontendBrowserHistory) else { return configuration }
        let saved = await service.fetchHistory(daemon, tab.surface)
        guard let state = BrowserHistoryWriter.restoreState(saved, at: url, engine: .cef),
              !(saved?.entries ?? []).contains(where: { URL(string: $0.url)?.isFileURL ?? true }) else {
            service.historyStarts.outcomes[key] = saved?.engineState == nil ? "address-no-state" : "address-file-access"
            return configuration
        }
        var restored = configuration
        restored.restoreState = state
        service.historyStarts.outcomes[key] = "engine"
        service.historyStarts.engineRestored.insert(key)
        return restored
    }

    /// True once after tab `tabID`'s new page restored its engine's own history; a Chromium page
    /// then also scrolls to the position saved at quit once it loads (WebKit's did at its start).
    func takeEngineRestored(_ tabID: String, page: any BrowserTab, saved: FrontendBrowserHistory?) -> Bool {
        guard engineRestored.remove(tabID) != nil else { return false }
        if page.engineKind == .cef, let saved, saved.entries.indices.contains(saved.index), let y = saved.entries[saved.index].scrollY {
            BrowserRestoreScroll.onLoad(page, to: y)
        }
        return true
    }

    func hold(_ page: WebKitTab, url: URL, tabID: String) {
        waiting[tabID]?.timer.cancel()
        let timer = Task { [weak self] in
            // wakeup-allow: one-shot fallback for a slow history read, cancelled when it answers
            do { try await Task.sleep(for: Self.budget) } catch { return }
            self?.start(tabID, saved: nil)
        }
        waiting[tabID] = Waiting(page: page, url: url, timer: timer)
    }

    /// Starts the page of `tabID` if it still waits: through `saved`'s engine state when it was
    /// saved at the page's address, else at the address. True when the engine state restored it.
    @discardableResult
    func start(_ tabID: String, saved: FrontendBrowserHistory?) -> Bool {
        guard let entry = waiting.removeValue(forKey: tabID) else { return false }
        entry.timer.cancel()
        guard let page = entry.page else { return false }
        // A navigation that started while the page waited (a deferred page's start, an agent's
        // load) wins: the page keeps it.
        guard page.webView.url == nil, page.state.url == nil else {
            outcomes[tabID] = "navigated"
            return false
        }
        let files = BrowserHistoryWriter.keepsFileAccess(saved?.entries.compactMap { URL(string: $0.url) } ?? [], shown: entry.url)
        if let state = BrowserHistoryWriter.restoreState(saved, at: entry.url, engine: .webkit), files {
            // A local page first loads with read access to its folder, which its restored entries
            // (all in that folder) then share; restored without it, WebKit would read them with
            // access to every file. The restore replaces this load.
            if entry.url.isFileURL { page.load(entry.url) }
            if page.restore(state), page.webView.backForwardList.currentItem?.url.absoluteString == entry.url.absoluteString {
                // WebKit keeps the scroll position it last recorded for the page, which can be
                // older than the one measured at quit.
                if let saved, let y = saved.entries[saved.index].scrollY { page.scrollOnLoad(to: y) }
                outcomes[tabID] = "engine"
                engineRestored.insert(tabID)
                return true
            }
            outcomes[tabID] = "address-state-refused"
            if !entry.url.isFileURL { page.load(entry.url) }
            return false
        }
        outcomes[tabID] = saved == nil ? "address" : saved?.engineState == nil ? "address-no-state" : "address-file-access"
        page.load(entry.url)
        return false
    }
}
