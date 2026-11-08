import AVFoundation
import UniformTypeIdentifiers
import SwiftUI
import MapKit
import CoreLocation

/// Совместимость Liquid Glass и новых API (iOS 26) для работы на iOS 18.0+.
/// На iOS 18 эмулирует стеклянные капсулы и кнопки через нативный `.ultraThinMaterial` с легким бликом рамки.
public struct GlassCompatStyle: Sendable {
    public var tintColor: Color?
    public var isInteractive: Bool = false

    public static let regular = GlassCompatStyle()

    public func interactive(_ enabled: Bool = true) -> GlassCompatStyle {
        var copy = self
        copy.isInteractive = enabled
        return copy
    }

    public func tint(_ color: Color?) -> GlassCompatStyle {
        var copy = self
        copy.tintColor = color
        return copy
    }
}

public struct GlassEffectContainer<Content: View>: View {
    public var spacing: CGFloat?
    public let content: Content

    public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        content
    }
}

public extension View {
    @ViewBuilder
    func glassEffect<S: Shape>(_ style: GlassCompatStyle = .regular, in shape: S) -> some View {
        self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint = style.tintColor {
                        shape.fill(tint)
                    }
                    shape.stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                }
            }
            .clipShape(shape)
    }

    @ViewBuilder
    func glassEffect(_ style: GlassCompatStyle = .regular) -> some View {
        self.glassEffect(style, in: .capsule)
    }

    func glassEffectID(_ id: some Hashable, in namespace: Namespace.ID) -> some View {
        self
    }
}

public struct GlassCompatButtonStyle: ButtonStyle {
    public let prominent: Bool
    public init(prominent: Bool = false) {
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, prominent ? 18 : 14)
            .padding(.vertical, prominent ? 10 : 8)
            .foregroundStyle(.white)
            .background {
                if prominent {
                    Capsule().fill(Color.blue.opacity(configuration.isPressed ? 0.75 : 0.92))
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                }
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

public extension ButtonStyle where Self == GlassCompatButtonStyle {
    static var glass: GlassCompatButtonStyle { GlassCompatButtonStyle(prominent: false) }
    static var glassProminent: GlassCompatButtonStyle { GlassCompatButtonStyle(prominent: true) }
}

// Совместимость MapKit для iOS 18 (в iOS 26 появились MKMapItem.location и MKMapItem.address)
public extension MKMapItem {
    var location: CLLocation {
        placemark.location ?? CLLocation(latitude: placemark.coordinate.latitude, longitude: placemark.coordinate.longitude)
    }

    struct AddressCompat {
        public let shortAddress: String?
    }

    var address: AddressCompat? {
        let parts = [placemark.thoroughfare, placemark.locality, placemark.country].compactMap { $0 }
        return parts.isEmpty ? nil : AddressCompat(shortAddress: parts.joined(separator: ", "))
    }
}

// Совместимость AVAssetExportSession для iOS 17.0+ (метод export(to:as:) появился в iOS 18)
public extension AVAssetExportSession {
    func compatExport(to url: URL, as fileType: AVFileType) async throws {
        if #available(iOS 18.0, *) {
            try await self.export(to: url, as: fileType)
            return
        }
        self.outputURL = url
        self.outputFileType = fileType
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.exportAsynchronously {
                cont.resume()
            }
        }
        if let err = self.error {
            throw err
        }
    }
}
