import SwiftUI
import RecorderCore

struct OfferSetupView: View {
    @EnvironmentObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var template: OfferTemplate
    @State private var error = ""
    var onSave: () -> Void
    init(template: OfferTemplate = .load(),onSave: @escaping () -> Void = {}) {
        _template = State(initialValue: template); self.onSave = onSave
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 18) {
            HStack {
                VStack(alignment: .leading,spacing: 4) {
                    Text("Video-Angebote einrichten").font(StudioFont.pageTitle)
                    Text("Einmal festlegen. Bei jedem neuen Angebot schon vorbereitet.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.buttonStyle(.pill).keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top,spacing: 24) {
                VStack(alignment: .leading,spacing: 16) {
                    VStack(alignment: .leading,spacing: 6) {
                        Text("Standard-Buchungslink").font(StudioFont.heading)
                        TextField("https://dein-buchungssystem.de/termin",text: $template.bookingURL).textFieldStyle(.roundedBorder).accessibilityLabel("Standard-Buchungslink")
                        Text("Der Button unter dem Video öffnet diesen Link.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                    }
                    Divider()
                    Text("Deine Landingpage").eyebrow()
                    OfferLandingFields(page: $template.landingPage)
                    VStack(alignment: .leading,spacing: 6) {
                        Text("Standardnachricht (optional)").font(StudioFont.captionStrong)
                        TextField("Eine kurze persönliche Einleitung",text: $template.message,axis: .vertical).lineLimit(3...4).textFieldStyle(.roundedBorder)
                    }
                }.frame(maxWidth: .infinity)
                OfferTemplatePreview(template: template).frame(width: 300)
            }
            Label("Öffnungen, Wiedergabe und Button-Klicks werden automatisch gemessen.",systemImage: "chart.bar.fill").font(StudioFont.captionStrong).foregroundStyle(StudioTheme.textSecondary)
            Text("Die Seite informiert Besucher über die Statistik und bietet eine Ausschaltoption. Bestehende Angebote behalten ihre Vorlage.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
            if !error.isEmpty { Text(error).font(StudioFont.caption).foregroundStyle(StudioTheme.accent).fixedSize(horizontal: false,vertical: true) }
            HStack {
                Text("Für Öffnungsmeldungen kann macOS einmalig um Erlaubnis bitten.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                Spacer()
                Button("Vorlage speichern") {
                    do { try template.save(); onSave(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(AccentButtonStyle(height: 36)).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 850).background(StudioTheme.background)
    }
}
struct OfferLandingFields: View {
    @Binding var page: OfferLandingPage
    var body: some View {
        VStack(alignment: .leading,spacing: 10) {
            TextField("Absender oder Firma (optional)",text: $page.sender).textFieldStyle(.roundedBorder)
            TextField("Text des Buchungsbuttons",text: $page.buttonTitle).textFieldStyle(.roundedBorder)
            Picker("Farbe",selection: $page.accent) {
                Text("Rekord-Rot").tag("red"); Text("Blau").tag("blue"); Text("Violett").tag("violet"); Text("Grün").tag("green")
            }.pickerStyle(.segmented)
        }
    }
}
private struct OfferTemplatePreview: View {
    let template: OfferTemplate
    private var accent: Color {
        switch template.landingPage.accent { case "blue": return Color(red: 37/255,green: 99/255,blue: 235/255); case "violet": return Color(red: 124/255,green: 58/255,blue: 237/255); case "green": return Color(red: 21/255,green: 128/255,blue: 61/255); default: return StudioTheme.accent }
    }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            Text("VORSCHAU DER VORLAGE").eyebrow()
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 9,height: 9)
                Text(template.landingPage.sender.isEmpty ? "Rekord" : template.landingPage.sender).font(StudioFont.heading).lineLimit(2)
            }
            Text("Dein persönliches Video").font(StudioFont.title)
            Text(template.message.isEmpty ? "Hier steht später deine Nachricht zum Video." : template.message).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(4)
            RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.35)).frame(height: 130)
                .overlay(Image(systemName: "play.circle.fill").font(.system(size: 42)).foregroundStyle(.white.opacity(0.8)))
            Text((template.landingPage.buttonTitle.isEmpty ? "Termin buchen" : template.landingPage.buttonTitle)+" ↗").font(StudioFont.captionStrong).foregroundStyle(.white).lineLimit(2)
                .frame(maxWidth: .infinity).padding(12).background(accent).clipShape(Capsule())
        }.studioCard(padding: 18)
    }
}
