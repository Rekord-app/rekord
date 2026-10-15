import SwiftUI
import AppKit
import RecorderCore

struct ProcessDetailView: View {
    let process: InventoryProcess
    @ObservedObject var inventory: InventoryStore
    @ObservedObject var guides: GuideStore
    private var profile: ProcessProfile { inventory.profile(process.id) }
    private var linked: [URL] { ProcessProfiles.guides(for: profile,available: guides.guides) }
    private var readiness: ProcessReadiness { ProcessReadiness(process: process,profile: profile,blocks: inventory.observedBlocks,guideCount: linked.count) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 22) {
                VStack(alignment: .leading,spacing: 8) {
                    HStack { Text(profile.reviewed ? "GEPRÜFTER PROZESS" : "ENTDECKT · BITTE PRÜFEN").eyebrow(); Spacer(); StatusBadge(text: process.automatable,tone: process.automatable == "ja" ? .success : .neutral) }
                    Text(process.name).font(.system(size: 23,weight: .semibold))
                    Text(process.description).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
                    HStack(spacing: 14) {
                        Label("\(readiness.observedRuns) Durchläufe",systemImage: "repeat")
                        Label("Tage: \(readiness.observedDays)",systemImage: "calendar")
                        Label("Anleitungen: \(linked.count)",systemImage: "list.number")
                    }.font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
                HStack(alignment: .top,spacing: 12) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(StudioTheme.accent)
                    VStack(alignment: .leading,spacing: 5) { Text("Dein nächster sinnvoller Schritt").font(StudioFont.bodyStrong); Text(readiness.nextStep).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary) }
                }.studioInset()
                ProcessROICard(inventory: inventory,id: process.id,observedMinutes: process.timesPerWeek > 0 ? process.minutesPerWeek/process.timesPerWeek : nil,observedRuns: process.timesPerWeek > 0 ? process.timesPerWeek : nil,hourlyRate: guides.hourlyRate,source: "Beobachtete Tage: \(inventory.catalog.days.count). Wenige Tage sind noch keine belastbare Wochenmessung.")
                VStack(alignment: .leading,spacing: 12) {
                    HStack { Text("Ablauf & Belege").font(.headline); Spacer(); Button("Ablauf vormachen") { record() }.buttonStyle(.pill).disabled(!guides.canStart() || guides.phase != .idle) }
                    Text("Auslöser: \(process.trigger)").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary)
                    ForEach(Array(process.steps.enumerated()),id: \.offset) { i,step in
                        HStack(alignment: .top,spacing: 10) { Text("\(i+1)").font(StudioFont.captionStrong).foregroundStyle(StudioTheme.accent).frame(width: 18); Text(step).font(StudioFont.body) }
                    }
                    ForEach(linked,id: \.self) { url in
                        HStack {
                            Button { guides.selected = url; inventory.hubTab = 2 } label: { Label(guides.load(url)?.title ?? url.lastPathComponent,systemImage: "doc.text.image") }.buttonStyle(.pill)
                            Spacer(); Button("Verknüpfung lösen") { inventory.unlinkGuide(url,from: process.id) }.font(StudioFont.caption).buttonStyle(.plain)
                        }
                    }
                    Menu("Vorhandene Anleitung verknüpfen") {
                        ForEach(guides.guides.filter { !linked.contains($0) },id: \.self) { url in Button(guides.load(url)?.title ?? url.lastPathComponent) { inventory.linkGuide(url,to: process.id) } }
                    }.disabled(guides.guides.allSatisfy { linked.contains($0) })
                    Text("Nur ausdrücklich verknüpfte Anleitungen gehen in die Übergabe ein. Ein gleiches Programm allein ist kein Beleg für denselben Ablauf.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                    DisclosureGroup("Beobachtete Arbeitsblöcke") {
                        ForEach(inventory.observedBlocks.filter { process.occurrences.contains($0.id) }) { block in
                            HStack { VStack(alignment: .leading) { Text(block.title); Text(block.start.formatted(date: .abbreviated,time: .shortened)).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }; Spacer(); Text("\(processNumber(block.activeSeconds/60)) Min.") }
                                .font(StudioFont.body).padding(.vertical,5)
                        }
                    }
                }.studioCard()
                ProcessContextForm(inventory: inventory,id: process.id)
                VStack(alignment: .leading,spacing: 12) {
                    Text("Bereit für die Umsetzung?").font(.headline)
                    Text("\(AutomationBrief.methodLabel(process.method)) · API: \(process.apiStatus) · Aufwand: \(process.effort)").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary)
                    ForEach(Array(readiness.missing.enumerated()),id: \.offset) { _,text in Label(text,systemImage: "circle").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
                    Toggle("Ich habe die beobachteten Schritte und Zuordnungen geprüft",isOn: Binding(get: { profile.reviewed },set: { value in var p = profile; p.reviewed = value; inventory.saveProfile(p,id: process.id) })).font(StudioFont.body)
                    Button { Task { await inventory.handover(process) } } label: { Label("Übergabe-Paket für Claude Code",systemImage: "terminal") }.buttonStyle(AccentButtonStyle(height: 36)).disabled(inventory.processing)
                    Text("Enthält Beobachtungen, verknüpfte Anleitungstexte, deine Ergänzungen und ROI-Annahmen. Offene Punkte werden mitgegeben. Der Entwurf wird erst mit zehn Testfällen und deiner Stichprobe geprüft.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                    if !process.openQuestions.isEmpty { Text("Aus der Analyse offen: " + process.openQuestions.joined(separator: " · ")).font(StudioFont.caption).foregroundStyle(StudioTheme.warning) }
                    if !process.successCriteria.isEmpty { Text("Vorgeschlagene Prüfkriterien: " + process.successCriteria.joined(separator: " · ")).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
                }.studioCard()
                if inventory.teamMode { teamReview }
                Button("Kein wiederkehrender Prozess",role: .destructive) { inventory.reject(process); inventory.selectedProcessID = nil }.buttonStyle(.plain).font(StudioFont.caption).disabled(inventory.processing)
            }.padding(24).frame(maxWidth: 940,alignment: .leading).frame(maxWidth: .infinity,alignment: .leading)
        }
    }
    private func record() { guides.nextTitle = process.name; guides.nextProcessID = process.id; inventory.hubTab = 2; guides.start() }
    private var teamReview: some View {
        VStack(alignment: .leading,spacing: 10) {
            Text("Für mein Unternehmen freigeben").font(.headline)
            TextField("Name",text: Binding(get: { inventory.exportNames[process.id] ?? process.name },set: { inventory.exportNames[process.id] = $0; inventory.approved.remove(process.id) }))
            TextField("Beschreibung",text: Binding(get: { inventory.exportEdits[process.id] ?? process.description },set: { inventory.exportEdits[process.id] = $0; inventory.approved.remove(process.id) }),axis: .vertical)
            TextField("Schritte (eine Zeile pro Schritt)",text: Binding(get: { inventory.exportSteps[process.id] ?? process.steps.joined(separator: "\n") },set: { inventory.exportSteps[process.id] = $0; inventory.approved.remove(process.id) }),axis: .vertical)
            Toggle("Texte geprüft und diesen Prozess zum Export freigegeben",isOn: Binding(get: { inventory.approved.contains(process.id) },set: { if $0 { inventory.approved.insert(process.id) } else { inventory.approved.remove(process.id) } }))
            Text("Exportiert werden nur die freigegebenen Prozessdaten mit Arbeitswert. Dein Steckbrief, ROI-Szenarien und Rohdaten bleiben lokal.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
        }.studioCard()
    }
}

struct ProcessContextForm: View {
    @ObservedObject var inventory: InventoryStore
    let id: String
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            Text("Was die Beobachtung allein nicht weiß").font(.headline)
            Text("Deine Ergänzungen bleiben bei einer neuen KI-Auswertung erhalten und verbessern das Übergabe-Paket. Änderungen werden lokal gespeichert.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            field("Ziel",hint: "Was soll am Ende besser sein?",key: \.goal)
            field("Auslöser",hint: "Wann beginnt der Ablauf?",key: \.trigger)
            field("Eingaben",hint: "Welche Daten brauchst du, und woher kommen sie?",key: \.inputs)
            field("Ergebnis",hint: "Was wird erstellt, wo wird es abgelegt?",key: \.outputs)
            field("Sonderfälle",hint: "Was passiert bei fehlenden Daten oder einer Ausnahme?",key: \.exceptions)
            field("Erfolgskriterium",hint: "Woran erkennst du einen korrekten Testlauf?",key: \.success)
        }.studioCard()
    }
    private func field(_ title: String,hint: String,key: WritableKeyPath<ProcessProfile,String>) -> some View {
        VStack(alignment: .leading,spacing: 4) {
            Text(title).font(StudioFont.captionStrong).foregroundStyle(StudioTheme.textSecondary)
            TextField(hint,text: Binding(get: { inventory.profile(id)[keyPath: key] },set: { value in var p = inventory.profile(id); p[keyPath: key] = value; p.reviewed = false; inventory.saveProfile(p,id: id) }),axis: .vertical).textFieldStyle(.roundedBorder)
        }
    }
}

struct ProcessROICard: View {
    @ObservedObject var inventory: InventoryStore
    let id: String
    let observedMinutes: Double?, observedRuns: Double?, hourlyRate: Double, source: String
    @State private var expanded = false
    init(inventory: InventoryStore,id: String,observedMinutes: Double?,observedRuns: Double?,hourlyRate: Double,source: String,initialExpanded: Bool = false) {
        self.inventory = inventory; self.id = id; self.observedMinutes = observedMinutes; self.observedRuns = observedRuns; self.hourlyRate = hourlyRate; self.source = source
        _expanded = State(initialValue: initialExpanded)
    }
    private var inputs: ProcessROIInputs { inventory.profile(id).roi }
    private var result: ProcessROI? { ProcessROI(inputs: inputs,observedMinutes: observedMinutes,observedRuns: observedRuns,hourlyRate: hourlyRate) }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack { Text("Was könnte dir dieser Ablauf bringen?").font(.headline); Spacer(); Text("SZENARIO").eyebrow() }
            Text(source).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
            if let r = result {
                HStack(alignment: .top,spacing: 20) {
                    figure("\(processNumber(r.savedHoursPerMonth)) h","freie Zeit / Monat")
                    figure("\(processNumber(r.monthlyNetValue ?? r.capacityValuePerMonth,0)) €",r.monthlyNetValue == nil ? "Kapazitätswert vor Kosten" : "Kapazitätswert nach Kosten")
                    figure(r.paybackMonths.map { "\(processNumber($0)) Mon." } ?? "–","bis Einrichtung gedeckt")
                }
                GeometryReader { box in
                    ZStack(alignment: .leading) {
                        Capsule().fill(StudioTheme.fillActive)
                        Capsule().fill(StudioTheme.success.opacity(0.8)).frame(width: box.size.width * min(1,max(0,r.workloadHoursPerMonth > 0 ? r.savedHoursPerMonth/r.workloadHoursPerMonth : 0)))
                    }
                }.frame(height: 6)
                Text("\(processNumber(r.workloadHoursPerMonth)) h bisher · \(processNumber(r.remainingMinutesPerRun)) Min. Restarbeit je Durchlauf inkl. Prüfung").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                if r.savedHoursPerMonth <= 0 { Text("In diesem Szenario entsteht keine Zeitersparnis. Prüfe Restarbeit und Prüfaufwand.").font(StudioFont.caption).foregroundStyle(StudioTheme.warning) }
            } else { Text("Ergänze Dauer und Häufigkeit, damit du ein sinnvolles Szenario rechnen kannst.").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary) }
            HStack {
                Text("Automatisierter Zeitanteil").font(StudioFont.caption)
                Slider(value: Binding(get: { inputs.savingFraction },set: { set(\.savingFraction,$0) }),in: 0...1,step: 0.05).tint(StudioTheme.controlTint)
                Text("\(Int(inputs.savingFraction*100)) %").monospacedDigit().frame(width: 45)
            }
            Text("Annahme: standardmäßig 50 %. Menschliche Prüfung wird zusätzlich abgezogen. Stelle den Anteil passend zum konkreten Ablauf ein.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
            DisclosureGroup("Dauer, Häufigkeit und Kosten anpassen",isExpanded: $expanded) {
                Grid(alignment: .leading,horizontalSpacing: 14,verticalSpacing: 12) {
                    GridRow {
                        number("Minuten je Durchlauf",key: \.minutesPerRun,placeholder: observedMinutes.map { processNumber($0) } ?? "Noch offen")
                        number("Durchläufe je Woche",key: \.runsPerWeek,placeholder: observedRuns.map { processNumber($0) } ?? "Noch offen")
                    }
                    GridRow {
                        VStack(alignment: .leading,spacing: 4) { Text("Prüfung je Durchlauf (Min.)").font(StudioFont.caption); TextField("Minuten",value: Binding(get: { inputs.reviewMinutesPerRun },set: { set(\.reviewMinutesPerRun,$0) }),format: .number).textFieldStyle(.roundedBorder) }
                        VStack(alignment: .leading,spacing: 4) { Text("Wert deiner Arbeitsstunde").font(StudioFont.caption); Text("\(processNumber(hourlyRate,0)) € · in Einstellungen ändern").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
                    }
                    GridRow {
                        number("Einrichtung einmalig (€)",key: \.setupCost,placeholder: "Noch offen")
                        number("Betrieb monatlich (€)",key: \.monthlyCost,placeholder: "Noch offen")
                    }
                }.padding(.top,12)
                Text("Leere Dauer/Häufigkeit übernimmt die Beobachtung. Kosten bleiben unbekannt, bis du sie einträgst; 0 € ist eine ausdrückliche Annahme. Einrichtung umfasst auch deine eigene Umsetzungszeit.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary).padding(.top,8)
                if let r = result {
                    Text("Rechnung: (\(processNumber(r.minutesPerRun)) Min. × \(Int(inputs.savingFraction*100)) % − \(processNumber(inputs.reviewMinutesPerRun)) Min.) × \(processNumber(r.runsPerWeek)) × 52 ÷ 12 ÷ 60 × \(processNumber(hourlyRate,0)) €/h. Davon monatliche Kosten abziehen.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).textSelection(.enabled)
                    if let annual = r.firstYearROI { Text("Modellierter ROI im ersten Jahr: \(processNumber(annual,0)) % = (12 × monatlicher Nettowert − Einrichtung) ÷ Einrichtung.").font(StudioFont.caption) }
                    if r.monthlyNetValue.map({ $0 <= 0 }) == true { Text("Mit diesen Annahmen amortisiert sich die Einrichtung nicht.").font(StudioFont.caption).foregroundStyle(StudioTheme.warning) }
                }
            }.font(StudioFont.body)
            Text("Das ist der Wert frei werdender Kapazität, keine garantierte Ersparnis oder zusätzlicher Umsatz.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
        }.studioCard(padding: 20)
    }
    private func figure(_ value: String,_ label: String) -> some View {
        VStack(alignment: .leading,spacing: 5) { Text(value).font(.system(size: 25,weight: .semibold,design: .rounded)).monospacedDigit(); Text(label).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }.frame(maxWidth: .infinity,alignment: .leading)
    }
    private func set(_ key: WritableKeyPath<ProcessROIInputs,Double>,_ value: Double) { var p = inventory.profile(id); p.roi[keyPath: key] = value; inventory.saveProfile(p,id: id) }
    private func number(_ title: String,key: WritableKeyPath<ProcessROIInputs,Double?>,placeholder: String) -> some View {
        VStack(alignment: .leading,spacing: 4) {
            Text(title).font(StudioFont.caption)
            TextField(placeholder,value: Binding(get: { inputs[keyPath: key] },set: { value in var p = inventory.profile(id); p.roi[keyPath: key] = value; inventory.saveProfile(p,id: id) }),format: .number).textFieldStyle(.roundedBorder)
        }
    }
}

struct GuideProcessPlanning: View {
    let guide: Guide, url: URL
    @ObservedObject var inventory: InventoryStore
    @ObservedObject var guides: GuideStore
    private var linkedProcess: InventoryProcess? { inventory.catalog.processes.first { inventory.profile($0.id).guidePaths.contains(url.path) } }
    private var id: String { linkedProcess?.id ?? ProcessProfiles.guideKey(guide) }
    var body: some View {
        VStack(alignment: .leading,spacing: 16) {
            HStack {
                if let process = linkedProcess {
                    Button { inventory.selectedProcessID = process.id; inventory.hubTab = 1 } label: { Label("Prozess öffnen: \(process.name)",systemImage: "link") }.buttonStyle(.pill)
                } else {
                    Menu("Mit erkanntem Prozess verbinden") {
                        ForEach(inventory.catalog.processes) { p in Button(p.name) { inventory.linkGuide(url,to: p.id) } }
                    }.disabled(inventory.catalog.processes.isEmpty)
                    Text("Du kannst diesen Ablauf auch direkt bewerten.").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
            }
            ProcessROICard(inventory: inventory,id: id,observedMinutes: linkedProcess.flatMap { $0.timesPerWeek > 0 ? $0.minutesPerWeek/$0.timesPerWeek : nil } ?? guide.duration/60,observedRuns: linkedProcess?.timesPerWeek ?? guide.frequencyPerWeek,hourlyRate: guides.hourlyRate,source: linkedProcess == nil ? "Basis: Dauer dieser Aufnahme, einschließlich Erklärzeit. Trage die normale Arbeitsdauer und Häufigkeit ein." : "Gemeinsame Rechnung mit dem verknüpften Prozess; keine doppelte Zeitersparnis.")
            if linkedProcess == nil { ProcessContextForm(inventory: inventory,id: id) }
        }
    }
}
