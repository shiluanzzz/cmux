/// Scrolls a page restored from its engine's own history to the position saved at quit, once it
/// loads (`BrowserRestoredSession.scrollOnLoad`); for a tab of either engine.
public enum BrowserRestoreScroll {
    public static func onLoad(_ tab: any BrowserTab, to y: Double) {
        if let tab = tab as? WebKitTab {
            tab.restored.scrollOnLoad(to: y)
        } else if let tab = tab as? CEFTab {
            tab.restored.scrollOnLoad(to: y)
        }
    }
}
