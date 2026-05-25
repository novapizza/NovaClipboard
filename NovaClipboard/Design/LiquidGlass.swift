import SwiftUI

// MARK: - Liquid Glass primitives
//
// On macOS 26 (Tahoe) we use the real `.glassEffect(...)` API and
// `GlassEffectContainer` so adjacent glass shapes refract/morph as a single
// optical layer. On macOS 14/15 we fall back to `.ultraThinMaterial` inside
// a matching shape so the layout, padding, and corner radii stay identical.

enum LiquidGlassVariant {
    case regular
    case prominent
    case clear
    case tinted(Color)
}

enum LiquidGlassShape {
    case capsule
    case roundedRect(cornerRadius: CGFloat)
    case circle

    fileprivate func swiftUIShape() -> AnyShape {
        switch self {
        case .capsule:
            return AnyShape(Capsule(style: .continuous))
        case .roundedRect(let r):
            return AnyShape(RoundedRectangle(cornerRadius: r, style: .continuous))
        case .circle:
            return AnyShape(Circle())
        }
    }
}

extension View {
    /// Applies a Liquid Glass background on macOS 26+, falling back to
    /// `.ultraThinMaterial` for older systems. Always clipped to `shape`.
    @ViewBuilder
    func liquidGlass(
        _ variant: LiquidGlassVariant = .regular,
        in shape: LiquidGlassShape = .capsule,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.modifier(NativeGlassModifier(variant: variant, shape: shape, interactive: interactive))
        } else {
            self.modifier(FallbackGlassModifier(variant: variant, shape: shape))
        }
    }

    /// Wraps content so multiple glass shapes inside merge into a single
    /// optical layer (with the characteristic Liquid Glass morph). No-op on
    /// older macOS.
    @ViewBuilder
    func liquidGlassContainer(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

@available(macOS 26.0, *)
private struct NativeGlassModifier: ViewModifier {
    let variant: LiquidGlassVariant
    let shape: LiquidGlassShape
    let interactive: Bool

    func body(content: Content) -> some View {
        let glass: Glass = {
            switch variant {
            case .regular: return .regular
            case .prominent: return .regular.tint(.primary.opacity(0.04))
            case .clear: return .clear
            case .tinted(let c): return .regular.tint(c)
            }
        }()
        let interactiveGlass = interactive ? glass.interactive() : glass
        return content.glassEffect(interactiveGlass, in: shape.swiftUIShape())
    }
}

private struct FallbackGlassModifier: ViewModifier {
    let variant: LiquidGlassVariant
    let shape: LiquidGlassShape

    func body(content: Content) -> some View {
        let shapeView = shape.swiftUIShape()
        content
            .background {
                ZStack {
                    shapeView.fill(.ultraThinMaterial)
                    shapeView.fill(tintOverlay)
                    shapeView
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.white.opacity(0.05)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            }
            .clipShape(shapeView)
    }

    private var tintOverlay: Color {
        switch variant {
        case .regular: return .clear
        case .prominent: return Color.primary.opacity(0.06)
        case .clear: return .clear
        case .tinted(let c): return c.opacity(0.18)
        }
    }
}

// MARK: - Button styles

/// A capsule glass button — used for utility actions in the panel header.
struct LiquidGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background {
                if #available(macOS 26.0, *) {
                    Capsule(style: .continuous)
                        .fill(.clear)
                        .glassEffect(
                            glass(for: configuration),
                            in: Capsule(style: .continuous)
                        )
                } else {
                    fallbackBackground(pressed: configuration.isPressed)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isPressed)
    }

    @available(macOS 26.0, *)
    private func glass(for configuration: Configuration) -> Glass {
        var base: Glass = prominent ? .regular.tint(tint ?? .accentColor) : .regular
        if let tint, !prominent { base = .regular.tint(tint.opacity(0.5)) }
        return configuration.isPressed ? base.interactive() : base.interactive()
    }

    @ViewBuilder
    private func fallbackBackground(pressed: Bool) -> some View {
        let cap = Capsule(style: .continuous)
        ZStack {
            cap.fill(.ultraThinMaterial)
            cap.fill((tint ?? (prominent ? Color.accentColor : .clear)).opacity(prominent ? 0.9 : 0.18))
            cap.stroke(Color.white.opacity(pressed ? 0.15 : 0.3), lineWidth: 0.5)
        }
    }
}

extension ButtonStyle where Self == LiquidGlassButtonStyle {
    static var liquidGlass: LiquidGlassButtonStyle { LiquidGlassButtonStyle() }
    static func liquidGlass(tint: Color? = nil, prominent: Bool = false) -> LiquidGlassButtonStyle {
        LiquidGlassButtonStyle(tint: tint, prominent: prominent)
    }
}
