import AppKit
import WebKit

/// Coordinates in-page find actions (⌘F, ⌘G, ⇧⌘G) for the active dictionary view.
@MainActor
public final class DictionaryFindCoordinator: ObservableObject {
    public static let shared = DictionaryFindCoordinator()

    private weak var activeContainer: DictionaryWebContainerView?

    public init() {}

    public func register(container: DictionaryWebContainerView) {
        self.activeContainer = container
    }

    public func unregister(container: DictionaryWebContainerView) {
        if self.activeContainer === container {
            self.activeContainer = nil
        }
    }

    public func performFind(_ action: NSTextFinder.Action) {
        if let keyWindow = NSApp.keyWindow,
           let container = findContainer(in: keyWindow.contentView) {
            container.performFind(action)
            return
        }
        activeContainer?.performFind(action)
    }

    private func findContainer(in view: NSView?) -> DictionaryWebContainerView? {
        guard let view else { return nil }
        if let match = view as? DictionaryWebContainerView {
            return match
        }
        for sub in view.subviews {
            if let match = findContainer(in: sub) {
                return match
            }
        }
        return nil
    }
}

/// A container view wrapping `WKWebView` that conforms to `NSTextFinderBarContainer`
/// to host Apple's native Safari/Xcode-style floating find bar.
public final class DictionaryWebContainerView: NSView, NSTextFinderBarContainer {
    public let webView: WKWebView
    public let textFinder = NSTextFinder()

    public var findBarView: NSView? {
        didSet {
            if oldValue !== findBarView {
                oldValue?.removeFromSuperview()
            }
        }
    }

    public var isFindBarVisible: Bool = false {
        didSet {
            guard isFindBarVisible != oldValue else { return }
            if isFindBarVisible {
                if let findBarView {
                    addSubview(findBarView)
                }
            } else {
                findBarView?.removeFromSuperview()
            }
            needsLayout = true
        }
    }

    public init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupTextFinderIfNeeded()
            DictionaryFindCoordinator.shared.register(container: self)
        } else {
            DictionaryFindCoordinator.shared.unregister(container: self)
        }
    }

    private var hasConfiguredTextFinder = false
    public func setupTextFinderIfNeeded() {
        guard !hasConfiguredTextFinder else { return }
        let client = webView.perform(Selector(("_ensureTextFinderClient")))?.takeUnretainedValue()
        textFinder.setValue(client, forKey: "client")
        textFinder.findBarContainer = self
        hasConfiguredTextFinder = true
    }

    public func findBarViewDidChangeHeight() {
        needsLayout = true
    }

    public func contentView() -> NSView? {
        self
    }

    public override func layout() {
        super.layout()
        if let findBarView, isFindBarVisible {
            let barHeight = findBarView.frame.height > 0 ? findBarView.frame.height : 32
            let barFrame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
            let webFrame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
            if findBarView.frame != barFrame {
                findBarView.frame = barFrame
            }
            if webView.frame != webFrame {
                webView.frame = webFrame
            }
        } else {
            if webView.frame != bounds {
                webView.frame = bounds
            }
        }
    }

    public func performFind(_ action: NSTextFinder.Action) {
        setupTextFinderIfNeeded()
        textFinder.performAction(action)
    }

    override public func performTextFinderAction(_ sender: Any?) {
        setupTextFinderIfNeeded()
        if let menuItem = sender as? NSMenuItem,
           let action = NSTextFinder.Action(rawValue: menuItem.tag) {
            performFind(action)
        } else {
            performFind(.showFindInterface)
        }
    }
}
