import Foundation
import CoreGraphics
import ImageIO

public struct RGB: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(_ red: Double,_ green: Double,_ blue: Double) { self.red = red; self.green = green; self.blue = blue }
    public var cgColor: CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,components: [red,green,blue,1])! }
    public var valid: Bool { [red,green,blue].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}
public enum BackdropKind: String, Codable, Sendable { case gradient, solid, image }
public struct BackdropSettings: Codable, Equatable, Sendable {
    public var kind: BackdropKind
    public var start = RGB(0.30,0.25,0.65)
    public var end = RGB(0.91,0.60,0.75)
    public var angle = 45.0
    public var imageFile: String?
    public var blur = 0.0
    public init(kind: BackdropKind) { self.kind = kind }
    public var valid: Bool {
        start.valid && end.valid && angle.isFinite && (0...360).contains(angle) && blur.isFinite && (0...0.05).contains(blur) &&
        (kind != .image || (imageFile?.range(of: #"^background-[A-Za-z0-9-]+\.png$"#,options: .regularExpression) != nil))
    }
}
public enum Background: String, Codable, CaseIterable, Sendable {
    // Studio wallpapers (lit, grained) first, then the classic two/three-colour gradients.
    case nightStudio, stage, deepSea, ember, velvet, northernLights, blueHour, dusk, coral, paper, mist, pastel
    case midnight, lavender, sand, ocean, aurora, peach, cobalt, rose, graphite, mint, sunrise, plum
    public var title: String {
        switch self {
        case .nightStudio: return "Nachtstudio"
        case .stage: return "Bühne"
        case .deepSea: return "Tiefsee"
        case .ember: return "Glut"
        case .velvet: return "Samt"
        case .northernLights: return "Nordlicht"
        case .blueHour: return "Blaue Stunde"
        case .dusk: return "Abendrot"
        case .coral: return "Koralle"
        case .paper: return "Papier"
        case .mist: return "Nebel"
        case .pastel: return "Pastell"
        case .midnight: return "Mitternacht"
        case .lavender: return "Lavendel"
        case .sand: return "Sand"
        case .ocean: return "Ozean"
        case .aurora: return "Polarlicht"
        case .peach: return "Pfirsich"
        case .cobalt: return "Kobalt"
        case .rose: return "Rosé"
        case .graphite: return "Graphit"
        case .mint: return "Minze"
        case .sunrise: return "Morgenrot"
        case .plum: return "Pflaume"
        }
    }
    public var palette: [RGB] {
        if let art { return art.palette }
        switch self {
        case .midnight: return [RGB(0.08,0.10,0.18),RGB(0.22,0.27,0.40)]
        case .lavender: return [RGB(0.78,0.78,0.97),RGB(0.97,0.77,0.85)]
        case .sand: return [RGB(0.96,0.90,0.80),RGB(0.84,0.71,0.59)]
        case .ocean: return [RGB(0.12,0.37,0.49),RGB(0.55,0.84,0.82)]
        case .aurora: return [RGB(0.10,0.19,0.31),RGB(0.37,0.25,0.68),RGB(0.18,0.71,0.59)]
        case .peach: return [RGB(1,0.85,0.71),RGB(0.97,0.55,0.49),RGB(0.82,0.43,0.60)]
        case .cobalt: return [RGB(0.08,0.13,0.52),RGB(0.23,0.37,0.93),RGB(0.54,0.76,1)]
        case .rose: return [RGB(0.40,0.17,0.32),RGB(0.84,0.42,0.57),RGB(1,0.80,0.72)]
        case .graphite: return [RGB(0.10,0.11,0.13),RGB(0.27,0.29,0.32)]
        case .mint: return [RGB(0.72,0.92,0.85),RGB(0.40,0.73,0.68),RGB(0.22,0.47,0.52)]
        case .sunrise: return [RGB(0.41,0.26,0.65),RGB(0.96,0.51,0.40),RGB(1,0.80,0.46)]
        case .plum: return [RGB(0.16,0.10,0.24),RGB(0.47,0.27,0.63),RGB(0.79,0.57,0.76)]
        default: return []
        }
    }
    public var isStudio: Bool { art != nil }
    /// Studio wallpapers. Dark ones keep bright UIs readable and look calm on YouTube; light ones suit light UIs.
    public var art: BackgroundArt? {
        typealias G = BackgroundArt.Glow
        switch self {
        case .nightStudio:
            return BackgroundArt(base: RGB(0.06,0.07,0.13),glows: [G(0.0,0.0,0.55,RGB(0.22,0.36,0.85),0.9),G(1.0,1.0,0.55,RGB(0.50,0.26,0.78),0.85),G(1.0,0.05,0.35,RGB(0.20,0.24,0.55),0.6)],
                                 ribbons: [.init(from: 0.9,to: 0.12,bend: 0.12,thickness: 0.18,color: RGB(0.45,0.58,1.0),fade: RGB(0.68,0.42,0.98),strength: 0.2)],vignette: 0.08,grain: 0.06)
        case .stage:
            return BackgroundArt(base: RGB(0.11,0.11,0.12),glows: [G(0.5,-0.2,0.7,RGB(0.62,0.63,0.66),0.9),G(0.0,1.0,0.4,RGB(0.24,0.24,0.26),0.6),G(1.0,1.0,0.4,RGB(0.24,0.24,0.26),0.6)],vignette: 0.12,grain: 0.06)
        case .deepSea:
            return BackgroundArt(base: RGB(0.03,0.10,0.13),glows: [G(0.0,1.0,0.55,RGB(0.05,0.55,0.56),0.85),G(1.0,0.0,0.55,RGB(0.10,0.30,0.65),0.85),G(0.5,0.5,0.4,RGB(0.06,0.32,0.40),0.4)],vignette: 0.08,grain: 0.06)
        case .ember:
            return BackgroundArt(base: RGB(0.10,0.05,0.05),glows: [G(0.85,1.05,0.6,RGB(1.0,0.48,0.24),0.9),G(0.0,0.0,0.5,RGB(0.48,0.13,0.24),0.75),G(0.1,1.0,0.35,RGB(0.62,0.20,0.14),0.55)],vignette: 0.08,grain: 0.06)
        case .velvet:
            return BackgroundArt(base: RGB(0.11,0.05,0.14),glows: [G(1.0,0.0,0.55,RGB(0.78,0.22,0.60),0.85),G(0.0,1.0,0.55,RGB(0.28,0.20,0.72),0.85)],
                                 ribbons: [.init(from: 0.1,to: 0.9,bend: -0.1,thickness: 0.16,color: RGB(1.0,0.50,0.80),fade: RGB(0.50,0.40,1.0),strength: 0.18)],vignette: 0.08,grain: 0.06)
        case .northernLights:
            return BackgroundArt(base: RGB(0.04,0.08,0.12),glows: [G(0.1,0.15,0.45,RGB(0.10,0.60,0.52),0.6),G(0.95,0.2,0.45,RGB(0.42,0.26,0.80),0.65),G(0.5,1.1,0.55,RGB(0.06,0.18,0.30),0.7)],
                                 ribbons: [.init(from: 0.75,to: 0.08,bend: 0.16,thickness: 0.22,color: RGB(0.30,1.0,0.74),fade: RGB(0.40,0.60,1.0),strength: 0.38),
                                           .init(from: 0.95,to: 0.4,bend: 0.1,thickness: 0.14,color: RGB(0.60,0.45,1.0),fade: RGB(0.25,0.90,0.85),strength: 0.28)],vignette: 0.1,grain: 0.06)
        case .blueHour:
            return BackgroundArt(base: RGB(0.10,0.14,0.48),glows: [G(0.0,0.0,0.55,RGB(0.28,0.52,1.0),0.95),G(1.0,1.0,0.55,RGB(0.60,0.30,0.98),0.9),G(1.0,0.0,0.38,RGB(0.40,0.80,1.0),0.6)],
                                 ribbons: [.init(from: 0.95,to: 0.2,bend: 0.14,thickness: 0.2,color: RGB(0.75,0.88,1.0),fade: RGB(0.80,0.60,1.0),strength: 0.22)],vignette: 0.05,grain: 0.05)
        case .dusk:
            return BackgroundArt(base: RGB(0.38,0.15,0.40),glows: [G(0.0,1.0,0.58,RGB(1.0,0.58,0.32),0.95),G(1.0,0.7,0.5,RGB(0.98,0.38,0.58),0.85),G(0.9,-0.05,0.48,RGB(0.38,0.24,0.78),0.85)],vignette: 0.05,grain: 0.05)
        case .coral:
            return BackgroundArt(base: RGB(0.95,0.48,0.42),glows: [G(0.0,0.0,0.55,RGB(1.0,0.78,0.58),0.9),G(1.0,1.0,0.58,RGB(0.86,0.26,0.40),0.85),G(1.0,0.0,0.32,RGB(1.0,0.64,0.56),0.55)],vignette: 0.04,grain: 0.05)
        case .paper:
            return BackgroundArt(base: RGB(0.93,0.915,0.89),glows: [G(0.0,0.0,0.55,RGB(1.0,0.84,0.70),0.8),G(1.0,1.0,0.6,RGB(0.78,0.86,1.0),0.85)],
                                 ribbons: [.init(from: 0.85,to: 0.25,bend: 0.1,thickness: 0.18,color: RGB(1.0,0.99,0.97),fade: RGB(0.98,0.92,0.88),strength: 0.45)],vignette: 0,grain: 0.04)
        case .mist:
            return BackgroundArt(base: RGB(0.84,0.87,0.92),glows: [G(0.1,0.05,0.55,RGB(1,1,1),0.9),G(1.0,1.0,0.58,RGB(0.62,0.71,0.88),0.85)],vignette: 0,grain: 0.04)
        case .pastel:
            return BackgroundArt(base: RGB(0.93,0.90,0.98),glows: [G(0.0,0.05,0.5,RGB(0.74,0.70,1.0),0.95),G(1.0,0.0,0.45,RGB(1.0,0.78,0.74),0.9),G(0.6,1.05,0.55,RGB(0.68,0.95,0.86),0.9)],vignette: 0,grain: 0.04)
        default: return nil
        }
    }
}
public enum BackgroundAsset {
    public static func load(project: Project,directory: URL) throws -> CGImage? {
        guard let backdrop = project.style.backdrop,backdrop.kind == .image else { return nil }
        guard backdrop.valid,let name = backdrop.imageFile,
              let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(name) as CFURL,nil),
              let image = CGImageSourceCreateImageAtIndex(source,0,nil) else { throw ProjectError.missingBackground }
        return image
    }
}
