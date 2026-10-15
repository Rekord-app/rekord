import SwiftUI
import RecorderCore

// MARK: - Design system
//
// One accent (the Rekord record red), a neutral grey scaffold, semantic colours only for status, and a small
// set of building blocks every surface shares. Liquid Glass belongs to the control layer (floating bars,
// pinned headers, pills); content stays calm.

enum StudioTheme {
    // Surfaces, from the window background up to hovered controls.
    static let background = Color(red: 0.055,green: 0.058,blue: 0.067)
    static let sidebar = Color(red: 0.072,green: 0.075,blue: 0.086)
    static let surface = Color(red: 0.102,green: 0.106,blue: 0.122)
    static let elevated = Color(red: 0.14,green: 0.145,blue: 0.165)
    static let hairline = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.13)
    static let fill = Color.white.opacity(0.06)
    static let fillHover = Color.white.opacity(0.1)
    static let fillActive = Color.white.opacity(0.14)
    // Accent: the record dot. Used for primary actions, selection marks and the playhead; never as a wash.
    static let accent = Color(red: 1,green: 0.31,blue: 0.28)
    static let accentDeep = Color(red: 0.84,green: 0.16,blue: 0.2)
    static let accentGradient = LinearGradient(colors: [Color(red: 1,green: 0.38,blue: 0.36),Color(red: 0.85,green: 0.16,blue: 0.21)],startPoint: .top,endPoint: .bottom)
    // Semantic, for status only.
    static let success = Color(red: 0.33,green: 0.8,blue: 0.5)
    static let warning = Color(red: 1,green: 0.73,blue: 0.32)
    static let info = Color(red: 0.47,green: 0.67,blue: 1)
    // Text. White 94 / 64 / 46 % keeps ≥ 4.5:1 for body and ≥ 3:1 for captions on every surface above.
    static let text = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.64)
    static let textTertiary = Color.white.opacity(0.46)
    // Radii and the 8-pt rhythm.
    static let radiusSmall: CGFloat = 8
    static let radius: CGFloat = 12
    static let radiusLarge: CGFloat = 16
    static let radiusPanel: CGFloat = 22
    static let gutter: CGFloat = 24
    /// Tint for system controls (checkboxes, sliders, toggles) inside dense panels: neutral, so only the
    /// primary actions carry the accent.
    static let controlTint = Color(white: 0.78)
    /// Timeline tracks: zoom = accent, camera layouts = info, retained footage = neutral.
    static let zoomTrack = LinearGradient(colors: [Color(red: 1,green: 0.42,blue: 0.38),Color(red: 0.82,green: 0.2,blue: 0.24)],startPoint: .top,endPoint: .bottom)
    static let clipEdge = Color.white
}

enum StudioFont {
    static let pageTitle = Font.system(size: 20,weight: .semibold)
    static let title = Font.system(size: 15,weight: .semibold)
    static let heading = Font.system(size: 13,weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13,weight: .medium)
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11,weight: .medium)
    static let eyebrow = Font.system(size: 10.5,weight: .semibold)
    static let control = Font.system(size: 12,weight: .medium)
    static let shortcut = Font.system(size: 11,weight: .medium,design: .rounded)
}

// MARK: - Surfaces

extension View {
    /// Content card on the window background.
    func studioCard(padding: CGFloat = 18,radius: CGFloat = StudioTheme.radiusLarge) -> some View {
        self.padding(padding).background(StudioTheme.surface,in: RoundedRectangle(cornerRadius: radius,style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius,style: .continuous).strokeBorder(StudioTheme.hairline))
    }
    /// Quiet inset block inside a card (code, drafts, lists).
    func studioInset(padding: CGFloat = 12,radius: CGFloat = StudioTheme.radius) -> some View {
        self.padding(padding).background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: radius,style: .continuous))
    }
    /// Small uppercase section label.
    func eyebrow() -> some View { font(StudioFont.eyebrow).tracking(0.8).foregroundStyle(StudioTheme.textTertiary).textCase(.uppercase) }
    /// Keyboard shortcut pill.
    func shortcutPill() -> some View {
        font(StudioFont.shortcut).foregroundStyle(StudioTheme.textTertiary).padding(.horizontal,6).padding(.vertical,3)
            .background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: 6,style: .continuous))
    }
}

/// Liquid Glass on macOS 26, a material panel before. Used for every floating control layer.
struct GlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    /// Optional tint keeps white text readable over bright content (floating controls over other apps).
    var tint: Color? = nil
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular,in: RoundedRectangle(cornerRadius: cornerRadius,style: .continuous))
        } else {
            content.background(tint ?? .clear,in: RoundedRectangle(cornerRadius: cornerRadius,style: .continuous))
                .background(.ultraThinMaterial,in: RoundedRectangle(cornerRadius: cornerRadius,style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius,style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        }
    }
}

/// Pinned bar inside the window (list headers, editor chrome): glass over the content that scrolls beneath it.
struct GlassBar: ViewModifier {
    var cornerRadius: CGFloat = StudioTheme.radiusLarge
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular,in: RoundedRectangle(cornerRadius: cornerRadius,style: .continuous))
        } else {
            content.background(.bar,in: RoundedRectangle(cornerRadius: cornerRadius,style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius,style: .continuous).strokeBorder(StudioTheme.hairline))
        }
    }
}
extension View {
    func glassBar(cornerRadius: CGFloat = StudioTheme.radiusLarge) -> some View { modifier(GlassBar(cornerRadius: cornerRadius)) }
}

// MARK: - Buttons

/// The one primary action per screen: record-red capsule, white text.
struct AccentButtonStyle: ButtonStyle {
    var height: CGFloat = 40
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13,weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal,18).frame(height: height)
            .background(StudioTheme.accentGradient,in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16)))
            .shadow(color: StudioTheme.accent.opacity(configuration.isPressed ? 0.15 : 0.32),radius: 10,y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.16),value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
/// Neutral capsule for secondary actions.
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 32
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(StudioFont.control).foregroundStyle(prominent ? StudioTheme.text : StudioTheme.textSecondary)
            .padding(.horizontal,12).frame(height: height)
            .background(configuration.isPressed ? StudioTheme.fillActive : (prominent ? StudioTheme.fillHover : StudioTheme.fill),in: Capsule())
            .overlay(Capsule().strokeBorder(StudioTheme.hairline))
            .contentShape(Capsule())
    }
}
/// Square icon button for toolbars.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13,weight: .medium)).foregroundStyle(StudioTheme.textSecondary)
            .frame(width: size,height: size)
            .background(configuration.isPressed ? StudioTheme.fillActive : (filled ? StudioTheme.fill : .clear),in: RoundedRectangle(cornerRadius: StudioTheme.radiusSmall,style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: StudioTheme.radiusSmall,style: .continuous))
    }
}
extension ButtonStyle where Self == AccentButtonStyle { static var accent: AccentButtonStyle { AccentButtonStyle() } }
extension ButtonStyle where Self == PillButtonStyle { static var pill: PillButtonStyle { PillButtonStyle() } }
extension ButtonStyle where Self == IconButtonStyle { static var icon: IconButtonStyle { IconButtonStyle() } }

/// Record dot used inside the primary buttons (white disc with a ring, like the app icon's lens).
struct RecordDot: View {
    var size: CGFloat = 11
    var body: some View {
        Circle().fill(.white).frame(width: size,height: size).padding(3).overlay(Circle().strokeBorder(.white.opacity(0.55),lineWidth: 1.5))
    }
}

// MARK: - Badges, search, list rows, empty state

/// Small status badge. `tone` decides the colour; text stays readable (tinted fill, solid text).
struct StatusBadge: View {
    enum Tone { case neutral, accent, success, warning, info }
    let text: String
    var tone: Tone = .neutral
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9,weight: .bold)) }
            Text(text).font(.system(size: 10.5,weight: .semibold,design: .rounded))
        }
        .foregroundStyle(color)
        .padding(.horizontal,7).padding(.vertical,3)
        .background(color.opacity(tone == .neutral ? 0.12 : 0.16),in: Capsule())
    }
    private var color: Color {
        switch tone {
        case .neutral: StudioTheme.textSecondary
        case .accent: StudioTheme.accent
        case .success: StudioTheme.success
        case .warning: StudioTheme.warning
        case .info: StudioTheme.info
        }
    }
}

/// Inline search field in the pinned list headers.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11,weight: .semibold)).foregroundStyle(StudioTheme.textTertiary)
            TextField(placeholder,text: $text).textFieldStyle(.plain).font(StudioFont.body).focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(StudioTheme.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Suche löschen")
            }
        }
        .padding(.horizontal,10).frame(height: 30)
        .background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: StudioTheme.radiusSmall,style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: StudioTheme.radiusSmall,style: .continuous).strokeBorder(focused ? StudioTheme.accent.opacity(0.6) : StudioTheme.hairline))
        .animation(.snappy(duration: 0.15),value: focused)
        .accessibilityLabel(placeholder)
    }
}

/// Neutral segmented control (the system one takes the window tint, which would make every segment red).
struct Segmented<Value: Hashable>: View {
    let options: [(Value,String)]
    @Binding var selection: Value
    @Namespace private var namespace
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options,id: \.0) { value,title in
                let selected = value == selection
                Button { withAnimation(.snappy(duration: 0.18)) { selection = value } } label: {
                    Text(title).font(.system(size: 11.5,weight: selected ? .semibold : .medium)).lineLimit(1)
                        .foregroundStyle(selected ? StudioTheme.text : StudioTheme.textSecondary)
                        .frame(maxWidth: .infinity).frame(height: 24)
                        .background {
                            if selected { RoundedRectangle(cornerRadius: 6,style: .continuous).fill(StudioTheme.fillActive).matchedGeometryEffect(id: "segment",in: namespace) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(2).background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: 8,style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8,style: .continuous).strokeBorder(StudioTheme.hairline))
    }
}

/// Toggle chip for list filters („Interesse ≥ 4“).
struct FilterChip: View {
    let title: String
    var icon: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10,weight: .semibold)) }
                Text(title)
            }
            .font(StudioFont.captionStrong).foregroundStyle(isOn ? StudioTheme.text : StudioTheme.textSecondary)
            .padding(.horizontal,10).frame(height: 26)
            .background(isOn ? StudioTheme.fillActive : StudioTheme.fill,in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? StudioTheme.hairlineStrong : StudioTheme.hairline))
            .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(isOn ? [.isSelected] : []).animation(.snappy(duration: 0.15),value: isOn)
    }
}

/// Row container for selectable lists (meetings, guides, sidebar recordings).
struct ListRowBackground: ViewModifier {
    let selected: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(selected ? StudioTheme.fillActive : (hovering ? StudioTheme.fill : .clear),in: RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous).strokeBorder(selected ? StudioTheme.hairlineStrong : .clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12),value: hovering)
    }
}
extension View { func listRow(selected: Bool) -> some View { modifier(ListRowBackground(selected: selected)) } }

/// Section header inside grouped lists („Heute“, „Diese Woche“).
struct GroupHeader: View {
    let title: String
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title).eyebrow()
            if let count { Text("\(count)").font(StudioFont.eyebrow).foregroundStyle(StudioTheme.textTertiary.opacity(0.7)).monospacedDigit() }
            Spacer()
        }.padding(.horizontal,6).padding(.top,10).padding(.bottom,4)
    }
}

/// Empty state with an icon, one sentence and an optional action.
struct EmptyState<Action: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30,weight: .light)).foregroundStyle(StudioTheme.textTertiary)
                .frame(width: 68,height: 68).background(StudioTheme.fill,in: Circle())
            Text(title).font(StudioFont.title).foregroundStyle(StudioTheme.text)
            Text(text).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            action().padding(.top,4)
        }.frame(maxWidth: .infinity,maxHeight: .infinity).padding(StudioTheme.gutter)
    }
}
extension EmptyState where Action == EmptyView {
    init(icon: String,title: String,text: String) { self.init(icon: icon,title: title,text: text,action: { EmptyView() }) }
}

/// Key fact tile for the detail headers (interest, next step, budget).
struct FactTile: View {
    let label: String
    let value: String
    var tone: StatusBadge.Tone = .neutral
    var icon: String? = nil
    var body: some View {
        VStack(alignment: .leading,spacing: 6) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10,weight: .semibold)).foregroundStyle(color) }
                Text(label).eyebrow()
            }
            Text(value).font(StudioFont.bodyStrong).foregroundStyle(value.hasPrefix("nicht ") ? StudioTheme.textTertiary : StudioTheme.text)
                .lineLimit(3).fixedSize(horizontal: false,vertical: true).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity,alignment: .leading).padding(12)
        .background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous))
    }
    private var color: Color {
        switch tone {
        case .neutral: StudioTheme.textSecondary
        case .accent: StudioTheme.accent
        case .success: StudioTheme.success
        case .warning: StudioTheme.warning
        case .info: StudioTheme.info
        }
    }
}

// MARK: - Dates

/// Human date groups and labels for lists (German, relative to today).
enum RelativeDay {
    enum Group: Int, CaseIterable, Comparable {
        case today, yesterday, week, month, earlier
        var title: String {
            switch self { case .today: "Heute"; case .yesterday: "Gestern"; case .week: "Diese Woche"; case .month: "Dieser Monat"; case .earlier: "Früher" }
        }
        static func < (a: Group,b: Group) -> Bool { a.rawValue < b.rawValue }
    }
    static func group(_ date: Date,now: Date = Date()) -> Group {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if let week = calendar.dateInterval(of: .weekOfYear,for: now), week.contains(date) { return .week }
        if let month = calendar.dateInterval(of: .month,for: now), month.contains(date) { return .month }
        return .earlier
    }
    /// „Heute, 10:30“ · „Gestern, 14:00“ · „Di., 13. Okt., 09:00“ · „25. Sept. 2025“ (other year).
    static func label(_ date: Date,now: Date = Date()) -> String {
        let calendar = Calendar.current
        let time = DateFormatter(); time.locale = Locale(identifier: "de_DE"); time.dateFormat = "HH:mm"
        if calendar.isDateInToday(date) { return "Heute, \(time.string(from: date))" }
        if calendar.isDateInYesterday(date) { return "Gestern, \(time.string(from: date))" }
        let day = DateFormatter(); day.locale = Locale(identifier: "de_DE")
        day.dateFormat = calendar.isDate(date,equalTo: now,toGranularity: .year) ? "EE, d. MMM, HH:mm" : "d. MMM yyyy"
        return day.string(from: date)
    }
    static func long(_ date: Date) -> String {
        let day = DateFormatter(); day.locale = Locale(identifier: "de_DE"); day.dateFormat = "EEEE, d. MMMM yyyy 'um' HH:mm"
        return day.string(from: date)
    }
}

// MARK: - Recorder chips (floating toolbar)

/// On/off chip with a device menu (system default or a specific device) and an optional level meter.
struct DeviceChip: View {
    let title: String
    let icon: String
    let offIcon: String
    @Binding var isOn: Bool
    let devices: [CaptureDeviceOption]
    @Binding var selection: String
    let defaultName: String
    let level: Double?
    let changed: () -> Void
    @EnvironmentObject var store: EditorStore
    var body: some View {
        HStack(spacing: 0) {
            Button { isOn.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: isOn ? icon : offIcon).frame(width: 16)
                    Text(isOn ? deviceName : "\(title) aus").lineLimit(1).frame(maxWidth: 120,alignment: .leading)
                    if isOn, let level { LevelBars(level: level).frame(width: 18,height: 12) }
                }.padding(.leading,12).padding(.trailing,6).padding(.vertical,7).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(isOn ? "an" : "aus")
            Menu {
                Picker(title,selection: Binding(get: { selection },set: { selection = $0; isOn = true; changed() })) {
                    Text("Systemstandard · \(defaultName)").tag("")
                    ForEach(devices) { Text($0.name).tag($0.id) }
                }.pickerStyle(.inline)
                Divider()
                Button(isOn ? "\(title) ausschalten" : "\(title) einschalten") { isOn.toggle() }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 9,weight: .semibold)).foregroundStyle(.secondary).padding(.leading,4).padding(.trailing,10).padding(.vertical,9).contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("\(title) auswählen")
        }
        .fixedSize()
        .chipSurface(active: isOn)
        .font(.system(size: 12,weight: .medium))
        .disabled(store.busy)
        .animation(.snappy(duration: 0.18),value: isOn)
    }
    private var deviceName: String {
        let name = selection.isEmpty ? defaultName : (devices.first { $0.id == selection }?.name ?? defaultName)
        return name.replacingOccurrences(of: "-Kamera",with: "").replacingOccurrences(of: "-Mikrofon",with: "")
    }
}

struct SimpleChip: View {
    let title: String
    let icon: String
    let offIcon: String
    @Binding var isOn: Bool
    @EnvironmentObject var store: EditorStore
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 7) { Image(systemName: isOn ? icon : offIcon).frame(width: 16); Text(title) }.chipStyle(active: isOn)
        }.buttonStyle(.plain).disabled(store.busy).help(isOn ? "Ton von Apps und Videos wird aufgenommen" : "Kein Systemton")
            .accessibilityLabel(title).accessibilityValue(isOn ? "an" : "aus")
            .animation(.snappy(duration: 0.18),value: isOn)
    }
}

/// Small live microphone meter for the chip.
struct LevelBars: View {
    let level: Double
    var body: some View {
        HStack(alignment: .bottom,spacing: 2) {
            ForEach(0..<4) { i in
                Capsule().fill(Double(i)/4 < level ? StudioTheme.success : Color.white.opacity(0.18))
                    .frame(width: 3,height: [5,8,11,14][i]*0.85)
            }
        }.animation(.linear(duration: 0.08),value: level)
    }
}

/// The camera's shape in the video (circle, continuous rounded, square) as a SwiftUI shape.
struct CameraShapeOutline: Shape {
    let shape: CameraShape
    func path(in rect: CGRect) -> Path { Path(shape.path(in: rect)) }
}

extension View {
    /// Chip on the dark glass toolbar: active = white fill with white text, inactive = faint outline.
    func chipSurface(active: Bool) -> some View {
        foregroundStyle(active ? Color.white : Color.white.opacity(0.62))
            .background(active ? Color.white.opacity(0.16) : Color.white.opacity(0.05),in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Color.white.opacity(0.22) : Color.white.opacity(0.08)))
    }
    func chipStyle(active: Bool) -> some View {
        font(.system(size: 12,weight: .medium)).padding(.horizontal,12).padding(.vertical,7)
            .chipSurface(active: active)
            .contentShape(Capsule())
    }
}
