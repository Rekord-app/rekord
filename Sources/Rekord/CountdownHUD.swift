import AppKit
import SwiftUI

/// Large 3-2-1 in the middle of the screen before recording. Belongs to this app, so it is excluded from capture.
@MainActor final class CountdownHUDController {
    private var panel: NSPanel?
    private let model = CountdownModel()
    func show(_ count: Int) {
        model.count = count
        if panel == nil {
            let size = CGSize(width: 220,height: 220)
            let next = NSPanel(contentRect: CGRect(origin: .zero,size: size),styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
            next.isOpaque = false; next.backgroundColor = .clear; next.hasShadow = false
            next.level = .statusBar; next.ignoresMouseEvents = true; next.sharingType = .none
            next.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            next.contentView = NSHostingView(rootView: CountdownView(model: model))
            let screen = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.frame ?? CGRect(x: 0,y: 0,width: 1440,height: 900)
            next.setFrameOrigin(CGPoint(x: screen.midX-size.width/2,y: screen.midY-size.height/2))
            panel = next
        }
        panel?.orderFrontRegardless()
    }
    func hide() { panel?.orderOut(nil); panel = nil }
}

@MainActor final class CountdownModel: ObservableObject { @Published var count = 3 }

private struct CountdownView: View {
    @ObservedObject var model: CountdownModel
    var body: some View {
        ZStack {
            // Ring that empties with the count, like a shutter timer.
            Circle().strokeBorder(Color.white.opacity(0.12),lineWidth: 4)
            Circle().trim(from: 0,to: CGFloat(model.count)/3).stroke(StudioTheme.accent,style: StrokeStyle(lineWidth: 4,lineCap: .round)).rotationEffect(.degrees(-90))
                .padding(2).animation(.easeInOut(duration: 0.9),value: model.count)
            Text("\(model.count)")
                .font(.system(size: 92,weight: .semibold,design: .rounded)).monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: 180,height: 180)
        .modifier(GlassPanel(cornerRadius: 90,tint: .black.opacity(0.35)))
        .shadow(color: .black.opacity(0.3),radius: 20,y: 8)
        .animation(.snappy(duration: 0.3),value: model.count)
        .frame(width: 220,height: 220)
        .accessibilityLabel("Aufnahme startet in \(model.count)")
    }
}
