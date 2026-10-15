import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import RecorderCore

/// Plays a meeting: both tracks mixed on their shared timeline (microphone and system audio at their offsets).
@MainActor final class MeetingPlayer: ObservableObject {
    let player = AVPlayer()
    @Published var time = 0.0
    @Published var playing = false
    @Published var rate: Float = 1
    @Published var ready = false
    let duration: Double
    private var observer: Any?

    init(url: URL,meeting: Meeting) {
        duration = max(1,meeting.duration)
        Task { await load(url: url,meeting: meeting) }
    }
    private func load(url: URL,meeting: Meeting) async {
        let composition = AVMutableComposition()
        let tracks = [(MeetingFile.microphone,meeting.microphoneOffset),(MeetingFile.system,meeting.systemOffset)]
        for (name,offset) in tracks {
            let file = url.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let asset = AVURLAsset(url: file)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,let length = try? await asset.load(.duration),
                  let target = composition.addMutableTrack(withMediaType: .audio,preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try? target.insertTimeRange(CMTimeRange(start: .zero,duration: length),of: source,at: CMTime(seconds: max(0,offset),preferredTimescale: 600))
        }
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        player.actionAtItemEnd = .pause
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1,timescale: 10),queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds.isFinite ? time.seconds : 0
                self.playing = self.player.rate > 0
            }
        }
        ready = !composition.tracks.isEmpty
    }
    func toggle() { if playing { player.pause(); playing = false } else { play() } }
    func play() { if time >= duration-0.2 { seek(0,autoplay: false) }; player.playImmediately(atRate: rate); playing = true }
    /// Jumps to a moment and plays from there (timestamps in summary and transcript call this).
    func seek(_ seconds: Double,autoplay: Bool = true) {
        let target = min(max(0,seconds),duration)
        time = target
        player.seek(to: CMTime(seconds: target,preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero)
        if autoplay { play() }
    }
    func skip(_ delta: Double) { seek(time+delta,autoplay: playing) }
    func setRate(_ value: Float) { rate = value; if playing { player.rate = value } }
    func stop() { player.pause(); if let observer { player.removeTimeObserver(observer) }; observer = nil }
}

/// Talk time per speaker from the transcript sentences.
struct TalkTime {
    let me: Double, other: Double
    init(_ transcript: Transcript?) {
        let sentences = transcript?.sentences ?? []
        me = sentences.filter { $0.speaker == .me }.reduce(0) { $0+max(0,$1.end-$1.start) }
        other = sentences.filter { $0.speaker == .other }.reduce(0) { $0+max(0,$1.end-$1.start) }
    }
    var mePercent: Int { me+other > 0 ? Int((me/(me+other)*100).rounded()) : 0 }
    var otherPercent: Int { me+other > 0 ? 100-mePercent : 0 }
}

/// Player card: play/skip/speed, time, and a two-lane speaker timeline you can click or drag to seek.
struct MeetingPlayerCard: View {
    @ObservedObject var player: MeetingPlayer
    let meeting: Meeting
    let transcript: Transcript?
    var body: some View {
        let talk = TalkTime(transcript)
        VStack(alignment: .leading,spacing: 12) {
            HStack(spacing: 10) {
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").font(.system(size: 15,weight: .bold)).foregroundStyle(.white)
                        .frame(width: 40,height: 40).background(StudioTheme.accentGradient,in: Circle())
                        .shadow(color: StudioTheme.accent.opacity(0.4),radius: 8,y: 2)
                }.buttonStyle(.plain).disabled(!player.ready).keyboardShortcut(.space,modifiers: []).accessibilityLabel(player.playing ? "Pause" : "Abspielen")
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }.buttonStyle(IconButtonStyle(size: 30,filled: false)).disabled(!player.ready).help("15 Sekunden zurück")
                Button { player.skip(15) } label: { Image(systemName: "goforward.15") }.buttonStyle(IconButtonStyle(size: 30,filled: false)).disabled(!player.ready).help("15 Sekunden vor")
                Text("\(timestamp(player.time)) / \(timestamp(meeting.duration))").font(.system(size: 12,weight: .medium,design: .monospaced)).foregroundStyle(StudioTheme.textSecondary)
                Spacer()
                Menu {
                    ForEach([Float(1),1.25,1.5,1.75,2],id: \.self) { value in Button(value == player.rate ? "✓ \(speed(value))" : speed(value)) { player.setRate(value) } }
                } label: { Text(speed(player.rate)).font(StudioFont.captionStrong).foregroundStyle(StudioTheme.textSecondary).padding(.horizontal,10).frame(height: 26).background(StudioTheme.fill,in: Capsule()) }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Geschwindigkeit")
            }
            SpeakerTimeline(player: player,transcript: transcript,duration: max(1,meeting.duration))
            HStack(spacing: 14) {
                legend(meeting.label(.me),talk.mePercent,StudioTheme.accent)
                if meeting.hasSystemAudio { legend(meeting.label(.other),talk.otherPercent,StudioTheme.info) }
                Spacer()
                if talk.me+talk.other > 0 { TalkBar(me: talk.me,other: talk.other).frame(width: 120,height: 6).help("Redeanteil") }
            }
        }.studioCard(padding: 16)
    }
    private func legend(_ name: String,_ percent: Int,_ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7,height: 7)
            Text(name).font(StudioFont.captionStrong).foregroundStyle(StudioTheme.text)
            Text("\(percent) %").font(StudioFont.caption.monospacedDigit()).foregroundStyle(StudioTheme.textSecondary)
        }
    }
    private func speed(_ value: Float) -> String { value == 1 ? "1×" : String(format: "%g×",value) }
}

struct TalkBar: View {
    let me: Double, other: Double
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                Capsule().fill(StudioTheme.accent).frame(width: max(2,geometry.size.width*me/max(1,me+other)-1))
                Capsule().fill(StudioTheme.info)
            }
        }
    }
}

/// Who spoke when: own voice on the upper lane, the other side below; playhead and scrubbing.
struct SpeakerTimeline: View {
    @ObservedObject var player: MeetingPlayer
    let transcript: Transcript?
    let duration: Double
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6,style: .continuous).fill(StudioTheme.fill)
                ForEach(Array((transcript?.sentences ?? []).enumerated()),id: \.offset) { _,sentence in
                    let x = width*sentence.start/duration, w = max(2,width*(sentence.end-sentence.start)/duration)
                    RoundedRectangle(cornerRadius: 2).fill(sentence.speaker == .me ? StudioTheme.accent : StudioTheme.info)
                        .opacity(sentence.end < player.time ? 0.95 : 0.55)
                        .frame(width: w,height: 9).offset(x: x,y: sentence.speaker == .me ? 7 : 22)
                }
                Rectangle().fill(.white).frame(width: 2,height: 38).offset(x: max(0,min(width-2,width*player.time/duration)),y: 0)
                    .shadow(color: .black.opacity(0.5),radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in player.seek(Double(value.location.x/width)*duration) }
                .onChanged { value in player.time = min(max(0,Double(value.location.x/width)*duration),duration) })
        }
        .frame(height: 38)
        .accessibilityElement().accessibilityLabel("Sprecher-Zeitleiste").accessibilityValue(timestamp(player.time))
    }
}

/// Clickable „12:34“ that jumps the player there.
struct TimestampChip: View {
    let value: String
    let player: MeetingPlayer?
    var body: some View {
        Button { if let seconds = seconds(fromTimestamp: value) { player?.seek(seconds) } } label: {
            HStack(spacing: 3) {
                Image(systemName: "play.fill").font(.system(size: 7,weight: .bold))
                Text(value).font(.system(size: 10.5,weight: .semibold,design: .monospaced))
            }
            .foregroundStyle(StudioTheme.info).padding(.horizontal,7).frame(height: 20)
            .background(StudioTheme.info.opacity(0.14),in: Capsule()).contentShape(Capsule())
        }.buttonStyle(.plain).disabled(player == nil || seconds(fromTimestamp: value) == nil).help("Ab \(value) anhören")
    }
}

/// One recorded call: header, player, then Übersicht / Transkript / Fragen.
struct MeetingDetailView: View {
    let url: URL
    @ObservedObject var meetings: MeetingStore
    @State private var tab = 0
    @State private var meeting: Meeting?
    @State private var summary: MeetingSummary?
    @State private var transcript: Transcript?
    @State private var questions: [MeetingQuestion] = []
    @State private var player: MeetingPlayer?
    @State private var copied: String?
    @State private var search = ""
    @State private var question = ""
    @State private var done: Set<Int> = []
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading,spacing: 18) {
                    if let meeting,let error = meeting.error {
                        Label(error,systemImage: "exclamationmark.triangle").font(StudioFont.body).foregroundStyle(StudioTheme.warning).textSelection(.enabled)
                            .padding(12).background(StudioTheme.warning.opacity(0.1),in: RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous))
                    }
                    if let meeting,let player,transcript != nil || meeting.status == .done { MeetingPlayerCard(player: player,meeting: meeting,transcript: transcript) }
                    Segmented(options: [(0,"Übersicht"),(1,"Transkript"),(2,"Fragen")],selection: $tab).frame(width: 330)
                    switch tab {
                    case 0: overview
                    case 1: transcriptView(proxy)
                    default: questionsView
                    }
                }.padding(StudioTheme.gutter).padding(.top,4).frame(maxWidth: 900,alignment: .leading).frame(maxWidth: .infinity,alignment: .leading)
            }
        }
        .safeAreaInset(edge: .top,spacing: 0) { header.padding(.horizontal,StudioTheme.gutter).padding(.top,14).padding(.bottom,6) }
        .task(id: meetings.revision) { load() }
        .onDisappear { player?.stop() }
    }
    private func load() {
        let loaded = try? Meeting.load(from: url)
        meeting = loaded; summary = try? MeetingSummary.load(from: url); transcript = try? Transcript.load(from: url)
        questions = MeetingQuestion.load(from: url)
        if player == nil, let loaded { player = MeetingPlayer(url: url,meeting: loaded) }
        done = Set(UserDefaults.standard.array(forKey: doneKey) as? [Int] ?? [])
    }
    private var doneKey: String { "meetingDone.\(meeting?.id ?? url.lastPathComponent)" }
    private var title: String { summary?.title ?? meeting?.displayTitle ?? "Meeting" }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading,spacing: 8) {
            HStack(alignment: .top,spacing: 12) {
                Text(title).font(StudioFont.pageTitle).foregroundStyle(StudioTheme.text).lineLimit(2).fixedSize(horizontal: false,vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if let summary,summary.isSales,!summary.followUpDraft.isEmpty {
                        copyButton("Follow-up",icon: "envelope") { summary.followUpDraft }
                    }
                    if let transcript,let meeting,!transcript.sentences.isEmpty { copyButton("Transkript",icon: "text.quote") { plainTranscript(transcript,meeting) } }
                    if let summary,let meeting { copyButton("Notiz",icon: "doc.plaintext") { summary.markdown(for: meeting) } }
                    Menu {
                        Button("Zusammenfassung neu erstellen") { meetings.retry(url) }
                        Button("Neu transkribieren und zusammenfassen") { meetings.retry(url,retranscribe: true) }
                        if let transcript,let meeting { Button("Transkript kopieren") { copy(plainTranscript(transcript,meeting),"Transkript") } }
                        Divider()
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Löschen …",role: .destructive) { meetings.delete(url) }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 13,weight: .semibold)).frame(width: 30,height: 30) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .background(StudioTheme.fill,in: Circle()).disabled(meetings.phase != .idle).accessibilityLabel("Weitere Aktionen")
                }.fixedSize()
            }
            HStack(spacing: 8) {
                if let summary { chip(summary.callTypeLabel,icon: icon(summary)) }
                if let summary,summary.isSales { InterestBadge(value: summary.interest) }
                if let meeting { Text(subtitle(meeting)).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(1) }
                if let meeting,meeting.status != .done,meeting.status != .failed {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text(meetings.progress.isEmpty ? "Wird verarbeitet …" : meetings.progress) }.font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary)
                }
            }
        }
        .padding(.horizontal,16).padding(.vertical,12).glassBar()
    }
    private func subtitle(_ meeting: Meeting) -> String {
        var parts = [RelativeDay.long(meeting.startedAt),minutes(meeting.duration)]
        if let app = meeting.app { parts.append(app) }
        if !meeting.hasSystemAudio { parts.append("nur eigene Stimme") }
        return parts.joined(separator: " · ")
    }
    private func icon(_ summary: MeetingSummary) -> String {
        switch summary.callType { case "customer": "person.2"; case "internal": "building.2"; case "private": "cup.and.saucer"; case "other": "bubble.left.and.bubble.right"; default: "briefcase" }
    }
    private func chip(_ text: String,icon: String) -> some View {
        HStack(spacing: 4) { Image(systemName: icon).font(.system(size: 9,weight: .semibold)); Text(text) }
            .font(StudioFont.captionStrong).foregroundStyle(StudioTheme.textSecondary).padding(.horizontal,8).frame(height: 22)
            .background(StudioTheme.fill,in: Capsule()).overlay(Capsule().strokeBorder(StudioTheme.hairline))
    }
    private func copyButton(_ label: String,icon: String,_ text: @escaping () -> String) -> some View {
        Button { copy(text(),label) } label: {
            Label(copied == label ? "Kopiert" : label,systemImage: copied == label ? "checkmark" : icon).lineLimit(1).fixedSize()
        }.buttonStyle(.pill).help("\(label) in die Zwischenablage kopieren")
    }

    // MARK: Übersicht

    @ViewBuilder private var overview: some View {
        if let summary,let meeting {
            Text(summary.purpose ?? summary.shortSummary).font(.system(size: 16,weight: .medium)).foregroundStyle(StudioTheme.text).lineSpacing(4)
                .textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
            if summary.purpose != nil, !summary.shortSummary.isEmpty {
                Text(summary.shortSummary).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
            }
            if summary.isSales { salesTiles(summary,meeting) }
            if let takeaways = summary.keyTakeaways,!takeaways.isEmpty {
                card("Kernaussagen",icon: "sparkles") {
                    ForEach(Array(takeaways.enumerated()),id: \.offset) { _,item in
                        HStack(alignment: .firstTextBaseline,spacing: 10) {
                            Circle().fill(StudioTheme.accent).frame(width: 5,height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom]-1 }
                            Text(item.text).font(StudioFont.body).foregroundStyle(StudioTheme.text).lineSpacing(2).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
                            Spacer(minLength: 6)
                            TimestampChip(value: item.timestamp,player: player)
                        }
                    }
                }
            }
            if let topics = summary.topics,!topics.isEmpty {
                card("Themen",icon: "list.bullet.rectangle") {
                    ForEach(Array(topics.enumerated()),id: \.offset) { index,topic in
                        VStack(alignment: .leading,spacing: 6) {
                            HStack(spacing: 8) {
                                TimestampChip(value: topic.timestamp,player: player)
                                Text(topic.title).font(StudioFont.bodyStrong).foregroundStyle(StudioTheme.text)
                            }
                            ForEach(Array(topic.points.enumerated()),id: \.offset) { _,point in
                                Text("– \(point)").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary).padding(.leading,4)
                                    .textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
                            }
                        }
                        if index < topics.count-1 { Divider().overlay(StudioTheme.hairline) }
                    }
                }
            }
            if !summary.actionItems.isEmpty || (!summary.nextStep.action.isEmpty && summary.isSales) {
                card("Nächste Schritte",icon: "checklist") {
                    if summary.isSales,!summary.nextStep.action.isEmpty {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 11,weight: .bold)).foregroundStyle(StudioTheme.accent)
                            Text([summary.nextStep.action,summary.nextStep.date,owner(summary.nextStep.owner,meeting)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(StudioFont.bodyStrong).foregroundStyle(StudioTheme.text).textSelection(.enabled)
                        }
                    }
                    ForEach(Array(summary.actionItems.enumerated()),id: \.offset) { index,item in
                        Button { toggleDone(index) } label: {
                            HStack(alignment: .top,spacing: 10) {
                                Image(systemName: done.contains(index) ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
                                    .foregroundStyle(done.contains(index) ? StudioTheme.success : StudioTheme.textTertiary)
                                Text(item.title).font(StudioFont.body).foregroundStyle(done.contains(index) ? StudioTheme.textTertiary : StudioTheme.text)
                                    .strikethrough(done.contains(index)).multilineTextAlignment(.leading)
                                Spacer(minLength: 6)
                                Text([owner(item.owner,meeting),item.dueDate].filter { !$0.isEmpty }.joined(separator: " · ")).font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            if summary.isSales { salesDetails(summary,meeting) }
            Text("Erstellt von \(meeting.summarizedWith ?? MeetingSummarizer.model) aus dem Transkript\(meeting.processingSeconds.map { ", fertig \(Int($0)) s nach dem Auflegen" } ?? ""). Zahlen und Namen vor dem Versand prüfen.")
                .font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
        } else if let meeting,meeting.status == .failed {
            EmptyState(icon: "exclamationmark.triangle",title: "Keine Zusammenfassung",text: "Die Verarbeitung ist fehlgeschlagen. Du kannst sie erneut starten.") {
                Button("Zusammenfassung neu erstellen") { meetings.retry(url) }.buttonStyle(.pill).disabled(meetings.phase != .idle)
            }
        } else if let meeting,meeting.status == .done,transcript != nil {
            Text("Ohne Claude-Schlüssel gibt es nur das Transkript. Schlüssel unter Einstellungen eintragen, dann ⋯ → Zusammenfassung neu erstellen.").font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary)
        } else {
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(meetings.progress.isEmpty ? "Wird verarbeitet …" : meetings.progress).font(StudioFont.body).foregroundStyle(StudioTheme.textSecondary) }
        }
    }
    @ViewBuilder private func salesTiles(_ summary: MeetingSummary,_ meeting: Meeting) -> some View {
        let tiles = [("Budget-Signal",summary.budgetSignal,"eurosign.circle"),("Entscheider",summary.decisionMaker,"person.crop.circle"),("Größter Schmerz",summary.mainPain,"bolt.heart")]
            .filter { !MeetingSummary.isBlank($0.1) }
        HStack(alignment: .top,spacing: 10) {
            VStack(alignment: .leading,spacing: 6) {
                HStack(spacing: 5) { Image(systemName: "flame").font(.system(size: 10,weight: .semibold)).foregroundStyle(summary.interest >= 4 ? StudioTheme.success : StudioTheme.textSecondary); Text("Interesse").eyebrow() }
                InterestBadge(value: summary.interest,large: true)
                if !summary.interestReason.isEmpty { Text(summary.interestReason).font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary).lineLimit(4).fixedSize(horizontal: false,vertical: true) }
            }.frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .topLeading).padding(12).background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous))
            ForEach(tiles,id: \.0) { tile in FactTile(label: tile.0,value: tile.1,icon: tile.2) }
        }.fixedSize(horizontal: false,vertical: true)
    }
    @ViewBuilder private func salesDetails(_ summary: MeetingSummary,_ meeting: Meeting) -> some View {
        let fields = [("Firma",summary.company),("Gesprächspartner",summary.contact),("Ausgangslage",summary.situation),("Aktueller Prozess",summary.currentProcess)]
            .filter { !MeetingSummary.isBlank($0.1) }
        if !fields.isEmpty {
            card("Gespräch",icon: "bubble.left.and.bubble.right") {
                ForEach(fields,id: \.0) { label,value in
                    HStack(alignment: .top,spacing: 12) {
                        Text(label).font(StudioFont.captionStrong).foregroundStyle(StudioTheme.textSecondary).frame(width: 130,alignment: .leading)
                        Text(value).font(StudioFont.body).foregroundStyle(StudioTheme.text).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
                    }
                }
            }
        }
        if !summary.objections.isEmpty {
            card("Einwände",icon: "quote.opening") {
                ForEach(Array(summary.objections.enumerated()),id: \.offset) { _,objection in
                    HStack(alignment: .top,spacing: 10) {
                        RoundedRectangle(cornerRadius: 2).fill(StudioTheme.accent).frame(width: 3)
                        Text("„\(objection.quote)“").font(.system(size: 13)).italic().foregroundStyle(StudioTheme.text).textSelection(.enabled)
                        Spacer(minLength: 4)
                        TimestampChip(value: objection.timestamp,player: player)
                    }.fixedSize(horizontal: false,vertical: true)
                }
            }
        }
        if !summary.followUpDraft.isEmpty {
            card("Follow-up-Entwurf",icon: "envelope") {
                Text(summary.followUpDraft).font(StudioFont.body).foregroundStyle(StudioTheme.text).lineSpacing(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity,alignment: .leading).studioInset(padding: 14)
                HStack { Spacer(); copyButton("Follow-up",icon: "doc.on.doc") { summary.followUpDraft } }
            }
        }
    }

    // MARK: Transkript

    @ViewBuilder private func transcriptView(_ proxy: ScrollViewProxy) -> some View {
        if let transcript,let meeting {
            let turns = transcript.turns
            let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
            let current = player.map { p in turns.lastIndex { $0.start <= p.time+0.3 } } ?? nil
            HStack(spacing: 10) {
                SearchField(placeholder: "Im Transkript suchen",text: $search).frame(maxWidth: 320)
                if !needle.isEmpty { Text("\(turns.filter { $0.text.lowercased().contains(needle) }.count) Treffer").font(StudioFont.caption).foregroundStyle(StudioTheme.textSecondary) }
                Spacer()
                if let echo = transcript.echoRemoved,echo > 0 { Text("\(echo) Echo-Sätze entfernt").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary) }
                Button { copy(plainTranscript(transcript,meeting),"Transkript") } label: {
                    Label(copied == "Transkript" ? "Kopiert" : "Transkript kopieren",systemImage: copied == "Transkript" ? "checkmark" : "doc.on.doc").lineLimit(1).fixedSize()
                }.buttonStyle(PillButtonStyle(prominent: true)).keyboardShortcut("c",modifiers: [.command,.shift])
                    .help("Ganzes Transkript mit Sprechern und Zeitmarken kopieren (⌘⇧C)")
            }
            VStack(alignment: .leading,spacing: 4) {
                ForEach(Array(turns.enumerated()),id: \.offset) { index,turn in
                    if needle.isEmpty || turn.text.lowercased().contains(needle) {
                        let active = index == current && (player?.playing ?? false)
                        HStack(alignment: .top,spacing: 12) {
                            VStack(alignment: .leading,spacing: 4) {
                                Text(meeting.label(turn.speaker)).font(.system(size: 11,weight: .semibold)).foregroundStyle(turn.speaker == .me ? StudioTheme.accent : StudioTheme.info).lineLimit(1)
                                TimestampChip(value: timestamp(turn.start),player: player)
                            }.frame(width: 96,alignment: .leading)
                            Text(highlighted(turn.text,needle)).font(StudioFont.body).foregroundStyle(StudioTheme.text).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(active ? StudioTheme.fillActive : .clear,in: RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous))
                        .id("turn-\(index)")
                    }
                }
            }
            .onChange(of: current) { _,index in
                guard let index,player?.playing == true,needle.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("turn-\(index)",anchor: .center) }
            }
            if transcript.sentences.isEmpty { Text("Keine Sprache erkannt.").font(StudioFont.body).foregroundStyle(StudioTheme.textTertiary) }
            Text("Maschinell erstellt (\(transcript.engine)). Namen und Zahlen vor Verwendung prüfen.").font(StudioFont.caption).foregroundStyle(StudioTheme.textTertiary)
        } else { Text("Noch kein Transkript.").font(StudioFont.body).foregroundStyle(StudioTheme.textTertiary) }
    }
    /// „Nikita [00:12]: …“ per turn, ready to paste into a mail, a doc or a chat with an AI.
    private func plainTranscript(_ transcript: Transcript,_ meeting: Meeting) -> String {
        transcript.turns.map { "\(meeting.label($0.speaker)) [\(timestamp($0.start))]: \($0.text)" }.joined(separator: "\n\n")
    }
    private func highlighted(_ text: String,_ needle: String) -> AttributedString {
        var result = AttributedString(text)
        guard !needle.isEmpty else { return result }
        var search = result.startIndex..<result.endIndex
        while let range = result[search].range(of: needle,options: .caseInsensitive) {
            result[range].backgroundColor = StudioTheme.warning.opacity(0.35); search = range.upperBound..<result.endIndex
        }
        return result
    }

    // MARK: Fragen

    @ViewBuilder private var questionsView: some View {
        let asking = meetings.asking == url
        VStack(alignment: .leading,spacing: 12) {
            HStack(spacing: 8) {
                TextField("Frag den Call, z. B. „Was habe ich zugesagt?“",text: $question).textFieldStyle(.plain).font(StudioFont.body)
                    .onSubmit { send() }.disabled(asking)
                Button { send() } label: {
                    if asking { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.up").font(.system(size: 12,weight: .bold)) }
                }.buttonStyle(IconButtonStyle(size: 28,filled: true)).disabled(asking || question.trimmingCharacters(in: .whitespaces).isEmpty || transcript == nil)
            }
            .padding(.horizontal,12).frame(height: 44)
            .background(StudioTheme.fill,in: RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: StudioTheme.radius,style: .continuous).strokeBorder(StudioTheme.hairline))
            HStack(spacing: 6) {
                ForEach(suggestions,id: \.self) { text in
                    Button { question = text; send() } label: { Text(text).font(StudioFont.captionStrong).padding(.horizontal,10).frame(height: 26).background(StudioTheme.fill,in: Capsule()) }
                        .buttonStyle(.plain).foregroundStyle(StudioTheme.textSecondary).disabled(asking || transcript == nil)
                }
            }
            if !meetings.hasAPIKey { Text("Fragen brauchen den Claude-Schlüssel (Einstellungen).").font(StudioFont.caption).foregroundStyle(StudioTheme.warning) }
        }
        ForEach(questions.reversed()) { item in
            VStack(alignment: .leading,spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle").foregroundStyle(StudioTheme.textTertiary)
                    Text(item.question).font(StudioFont.bodyStrong).foregroundStyle(StudioTheme.text)
                    Spacer()
                    Button { copy(item.answer,"Antwort-\(item.id)") } label: { Image(systemName: copied == "Antwort-\(item.id)" ? "checkmark" : "doc.on.doc").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(StudioTheme.textTertiary).help("Antwort kopieren")
                }
                Text((try? AttributedString(markdown: item.answer,options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(item.answer))
                    .font(StudioFont.body).foregroundStyle(StudioTheme.text).lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false,vertical: true)
            }.studioCard(padding: 16)
        }
    }
    private var suggestions: [String] {
        summary?.isSales == false ? ["Was wurde vereinbart?","Fass das in 3 Punkten zusammen"] : ["Welche Einwände kamen?","Was habe ich zugesagt?","Schreib eine Follow-up-Mail"]
    }
    private func send() {
        let text = question
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        question = ""
        Task { await meetings.ask(url,question: text) }
    }

    // MARK: Helpers

    private func card<Content: View>(_ title: String,icon: String,@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading,spacing: 12) {
            HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 10,weight: .semibold)).foregroundStyle(StudioTheme.textTertiary); Text(title).eyebrow() }
            content()
        }.frame(maxWidth: .infinity,alignment: .leading).studioCard(padding: 16)
    }
    private func toggleDone(_ index: Int) {
        if done.contains(index) { done.remove(index) } else { done.insert(index) }
        UserDefaults.standard.set(Array(done),forKey: doneKey)
    }
    private func owner(_ value: String,_ meeting: Meeting) -> String {
        switch value { case "me": meeting.ownName; case "other": meeting.otherName; case "both": "beide"; default: "" }
    }
    private func copy(_ text: String,_ what: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType: .string)
        withAnimation(.snappy(duration: 0.2)) { copied = what }
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); withAnimation { if copied == what { copied = nil } } }
    }
}
