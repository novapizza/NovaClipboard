import AppKit
import ApplicationServices

enum PanelAnchor {
    case caret(CGRect)
    case focusedElement(CGRect)
    case mouse(CGPoint)
    case fixed(CGPoint)
}

enum PanelPositionPreference: String, Codable {
    case atCaret
    case atMouse
    case fixed
}

final class PanelAnchorResolver {
    private static let axMessagingTimeout: Float = 0.030

    /// Apps where AX caret/element queries are known to be unreliable or absent.
    /// Preloaded at init; additional broken bundles get appended during the session.
    private static let defaultBrokenBundleIDs: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal",
        "com.mitchellh.ghostty",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.webstorm",
        "com.jetbrains.goland",
        "com.jetbrains.rubymine",
        "com.jetbrains.clion",
        "com.jetbrains.rider",
        "com.jetbrains.AppCode"
    ]

    private static let jetbrainsPrefix = "com.jetbrains."

    private let systemWide: AXUIElement
    private var brokenBundleIDs: Set<String>

    var fixedOrigin: CGPoint = .zero

    init() {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, PanelAnchorResolver.axMessagingTimeout)
        self.systemWide = element
        self.brokenBundleIDs = PanelAnchorResolver.defaultBrokenBundleIDs
    }

    func resolve(preference: PanelPositionPreference = .atCaret) -> PanelAnchor {
        switch preference {
        case .atMouse:
            return .mouse(NSEvent.mouseLocation)
        case .fixed:
            return .fixed(fixedOrigin)
        case .atCaret:
            return resolveAtCaret()
        }
    }

    private func resolveAtCaret() -> PanelAnchor {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundleID, isBroken(bundleID) {
            return .mouse(NSEvent.mouseLocation)
        }

        guard let focused = focusedElement() else {
            if let bundleID { brokenBundleIDs.insert(bundleID) }
            return .mouse(NSEvent.mouseLocation)
        }

        if let caret = caretBounds(of: focused) {
            return .caret(caret)
        }

        if let bounds = elementBounds(of: focused) {
            return .focusedElement(bounds)
        }

        if let bundleID { brokenBundleIDs.insert(bundleID) }
        return .mouse(NSEvent.mouseLocation)
    }

    private func isBroken(_ bundleID: String) -> Bool {
        if brokenBundleIDs.contains(bundleID) { return true }
        if bundleID.hasPrefix(PanelAnchorResolver.jetbrainsPrefix) { return true }
        return false
    }

    private func focusedElement() -> AXUIElement? {
        var focused: AnyObject?
        let err = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard err == .success, let value = focused,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, PanelAnchorResolver.axMessagingTimeout)
        return element
    }

    private func caretBounds(of element: AXUIElement) -> CGRect? {
        var rangeValue: AnyObject?
        let rangeErr = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        guard rangeErr == .success, let rv = rangeValue,
              CFGetTypeID(rv) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }

        var boundsValue: AnyObject?
        let boundsErr = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rv,
            &boundsValue
        )
        guard boundsErr == .success, let bv = boundsValue,
              CFGetTypeID(bv) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(bv as! AXValue, .cgRect, &rect),
              rect.width >= 0, rect.height >= 0 else {
            return nil
        }
        return rect
    }

    private func elementBounds(of element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeErr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard posErr == .success, sizeErr == .success,
              let pv = positionValue, let sv = sizeValue,
              CFGetTypeID(pv) == AXValueGetTypeID(),
              CFGetTypeID(sv) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sv as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }
}

extension PanelAnchor {
    func panelOrigin(panelSize: CGSize, screen: NSScreen?) -> CGPoint {
        let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let offset: CGFloat = 4

        let rectOrPoint: CGRect = {
            switch self {
            case .caret(let r):
                return convertAXRectToScreen(r)
            case .focusedElement(let r):
                return convertAXRectToScreen(r)
            case .mouse(let p):
                return CGRect(origin: p, size: .zero)
            case .fixed(let p):
                return CGRect(origin: p, size: .zero)
            }
        }()

        var x = rectOrPoint.minX
        var y = rectOrPoint.minY - panelSize.height - offset

        if y < screenFrame.minY {
            y = rectOrPoint.maxY + offset
        }
        if x + panelSize.width > screenFrame.maxX {
            x = screenFrame.maxX - panelSize.width - 8
        }
        if x < screenFrame.minX {
            x = screenFrame.minX + 8
        }

        return CGPoint(x: x, y: y)
    }

    private func convertAXRectToScreen(_ rect: CGRect) -> CGRect {
        guard let mainScreen = NSScreen.screens.first else { return rect }
        let flippedY = mainScreen.frame.maxY - rect.maxY
        return CGRect(x: rect.minX, y: flippedY, width: rect.width, height: rect.height)
    }
}
