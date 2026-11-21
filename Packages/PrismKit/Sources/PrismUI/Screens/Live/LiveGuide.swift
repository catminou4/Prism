import Foundation
import SwiftUI
import PrismCore
import PrismData
import PrismDesign

private let guideTimeFormat = Date.FormatStyle.dateTime.hour().minute().locale(Locale(identifier: "fr_FR"))

struct LiveGuide<ChannelMenu: View>: View {
    let channels: [ChannelGroup]
    let guide: EPGGuide
    @Binding var start: Date?
    let isRefreshing: Bool
    let onRefresh: () -> Void
    let onPlay: (ChannelGroup, EPGProgram?) -> Void
    let onReplay: (ChannelGroup, EPGProgram, Date) -> (() -> Void)?
    @ViewBuilder let channelMenu: (ChannelGroup, EPGProgram?) -> ChannelMenu

    @Environment(\.isPageActive) private var isPageActive

    var body: some View {
        GeometryReader { geometry in
            let channelWidth = min(220, max(146, geometry.size.width * 0.23))
            let margin = PrismMetrics.contentMargin
            let timeWidth = max(1, geometry.size.width - 2 * margin - channelWidth)
            LiveClock(active: isPageActive) { now in
                let timeline = GuideTimeline(selectedStart: start, now: now, width: timeWidth)
                VStack(alignment: .leading, spacing: 10) {
                    controls(timeline)
                        .padding(.horizontal, margin)
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section {
                                ForEach(channels) { channel in
                                    guideRow(channel, timeline: timeline, channelWidth: channelWidth)
                                }
                            } header: {
                                timelineHeader(timeline, channelWidth: channelWidth)
                            }
                        }
                        .padding(.horizontal, margin)
                        .padding(.bottom, 36)
                    }
                    .accessibilityLabel("Grille des programmes TV")
                    .scrollEdgeEffectStyle(.soft, for: .top)
                }
                .padding(.top, 8)
            }
        }
    }

    private func controls(_ timeline: GuideTimeline) -> some View {
        let controlSize = PrismMetrics.compactButtonSize
        return HStack(spacing: 10) {
            HStack(spacing: 0) {
                guideButton("Programmes précédents", symbol: "chevron.left") {
                    start = timeline.interval.start.addingTimeInterval(-timeline.interval.duration)
                }
                Divider().frame(height: 14)
                guideButton("Programmes suivants", symbol: "chevron.right") {
                    start = timeline.interval.end
                }
            }
            .prismGlass(.regular, in: .capsule)
            DatePicker("Jour du programme", selection: Binding(
                get: { timeline.interval.start },
                set: { start = Calendar.current.startOfDay(for: $0) }
            ), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .environment(\.locale, Locale(identifier: "fr_FR"))
            Spacer(minLength: 10)
            Button {
                start = nil
            } label: {
                Label("Maintenant", systemImage: "clock")
                    .font(PrismFont.capsuleButton)
                    .foregroundStyle(start == nil ? Color.secondary : Color.primary)
                    .padding(.horizontal, 12)
                    .frame(height: controlSize)
                    .prismGlass(.regular, in: .capsule, interactive: start != nil)
                    .contentShape(.capsule)
            }
            .buttonStyle(.pressable)
            .disabled(start == nil)
            if isRefreshing {
                ProgressView().controlSize(.small)
                    .frame(width: controlSize, height: controlSize)
                    .prismGlass(.regular, in: .circle)
                    .accessibilityLabel("Actualisation du guide")
            } else {
                GlassCircleButton(systemName: "arrow.clockwise", size: controlSize, accessibilityLabel: "Actualiser le guide", action: onRefresh)
                    .help("Actualiser le guide")
            }
        }
        .frame(minHeight: controlSize)
    }

    private func guideButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: PrismMetrics.compactButtonSize, height: PrismMetrics.compactButtonSize)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .help(title)
        .accessibilityLabel(title)
    }

    private func timelineHeader(_ timeline: GuideTimeline, channelWidth: CGFloat) -> some View {
        let currentLabelX = timeline.nowPosition.map { max(22, min($0, timeline.width - 22)) }
        return HStack(spacing: 0) {
            Text("Chaînes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: channelWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    ForEach(0..<timeline.slotCount, id: \.self) { index in
                        let tickLabelX = CGFloat(index) * timeline.slotWidth + 22
                        let overlapsCurrent = currentLabelX.map { abs($0 - tickLabelX) < 34 } ?? false
                        Text(timeline.tick(at: index), format: guideTimeFormat)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.leading, 6)
                            .frame(width: timeline.slotWidth, alignment: .leading)
                            .opacity(overlapsCurrent ? 0 : 1)
                            .accessibilityHidden(overlapsCurrent)
                    }
                }
                if let currentLabelX {
                    Text(timeline.now, format: guideTimeFormat)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: .capsule)
                        .fixedSize()
                        .position(x: currentLabelX, y: 15)
                        .accessibilityLabel("Heure actuelle \(timeline.now.formatted(guideTimeFormat))")
                }
            }
            .frame(width: timeline.width, height: 30)
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityAddTraits(.isHeader)
    }

    private func guideRow(_ channel: ChannelGroup, timeline: GuideTimeline, channelWidth: CGFloat) -> some View {
        let id = guide.resolveEPGID(for: channel)
        let programmes = id.map { guide.programs(forEPGID: $0, in: timeline.interval) } ?? []
        let archiveWindow = channel.variants.lazy.compactMap { $0.catchup?.days }.max() ?? 0
        func airingProgramme() -> EPGProgram? {
            id.flatMap { guide.nowAndNext(forEPGID: $0, at: Date.now).now }
        }
        return HStack(spacing: 0) {
            GuideChannelButton(channel: channel) { onPlay(channel, airingProgramme()) }
                .frame(width: channelWidth)
                .contextMenu { channelMenu(channel, airingProgramme()) }
            ZStack(alignment: .topLeading) {
                timelineBackground(timeline)
                ForEach(programmes) { program in
                    let x = timeline.x(for: max(program.start, timeline.interval.start))
                    let end = timeline.x(for: min(program.end, timeline.interval.end))
                    let width = max(1, end - x - 3)
                    GuideProgrammeButton(
                        program: program, now: timeline.now, width: width,
                        archiveWindow: archiveWindow,
                        onPlay: { onPlay(channel, program) },
                        replay: { onReplay(channel, program, timeline.now) }
                    )
                    .offset(x: x + 1.5, y: 3)
                }
                if let now = timeline.nowPosition {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 1.5, height: Self.rowHeight)
                        .offset(x: now)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: timeline.width, height: Self.rowHeight)
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(programmes.isEmpty ? "Aucun programme sur cette plage horaire" : "Programmes")
        }
        .frame(height: Self.rowHeight)
        .overlay(alignment: .bottom) { Divider().opacity(0.45) }
    }

    private func timelineBackground(_ timeline: GuideTimeline) -> some View {
        Canvas { context, size in
            var markers = Path()
            for index in 0..<timeline.slotCount {
                let x = CGFloat(index) * timeline.slotWidth
                markers.move(to: CGPoint(x: x, y: 0))
                markers.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(markers, with: .color(.secondary.opacity(0.16)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private static var rowHeight: CGFloat { 58 }
}

private struct GuideChannelButton: View {
    let channel: ChannelGroup
    let play: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: play) {
            HStack(spacing: 8) {
                Text(channel.number.map(String.init) ?? "")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
                    .accessibilityHidden(true)
                RemoteImage(
                    url: channel.logoURL, size: CGSize(width: 31, height: 31), contentMode: .fit,
                    placeholderSeed: channel.name, placeholderTitle: channel.name, placeholderStyle: .channelLogo
                )
                .background(Color(white: channel.logoURL == nil ? 0.16 : 0.36), in: .rect(cornerRadius: PrismMetrics.smallArtworkRadius))
                .clipShape(.rect(cornerRadius: PrismMetrics.smallArtworkRadius))
                .accessibilityHidden(true)
                Text(channel.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 1)
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(hovered ? 1 : 0)
            }
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : PrismMotion.quickFade, value: hovered)
        .help(channel.name)
        .accessibilityLabel(channel.number.map { "Chaîne \($0), \(channel.name)" } ?? channel.name)
        .accessibilityHint("Regarder en direct")
    }
}

private struct GuideProgrammeButton: View {
    let program: EPGProgram
    let now: Date
    let width: CGFloat
    let archiveWindow: Int
    let onPlay: () -> Void
    let replay: () -> (() -> Void)?
    @State private var showingDetails = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLive: Bool { program.isAiring(at: now) }
    private var mightReplay: Bool {
        program.end <= now && now.timeIntervalSince(program.start) <= Double(archiveWindow) * 86_400
    }
    private var times: String {
        "\(program.start.formatted(guideTimeFormat)) – \(program.end.formatted(guideTimeFormat))"
    }

    var body: some View {
        let times = times
        Button {
            showingDetails = true
        } label: {
            if width >= 32 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(program.title)
                        .font(.system(size: 12, weight: isLive ? .semibold : .medium))
                        .lineLimit(1)
                    if width >= 75 {
                        HStack(spacing: 3) {
                            if mightReplay { Image(systemName: "arrow.counterclockwise").accessibilityHidden(true) }
                            Text(times).monospacedDigit().lineLimit(1)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: width, height: 51, alignment: .leading)
                .clipped()
                .background { surface }
            } else {
                surface.frame(width: width, height: 51)
            }
        }
        .buttonStyle(.plain)
        .contentShape(.rect(cornerRadius: PrismMetrics.listRowRadius))
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : PrismMotion.quickFade, value: hovered)
        .help("\(program.title) · \(times)")
        .accessibilityLabel("\(program.title), \(times)\(isLive ? ", en direct" : "")")
        .accessibilityHint("Afficher le programme")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) { details(times: times) }
    }

    private var surface: some View {
        RoundedRectangle(cornerRadius: PrismMetrics.listRowRadius)
            .fill(Color.primary.opacity(hovered ? 0.14 : isLive ? 0.10 : 0.055))
            .overlay {
                if isLive {
                    RoundedRectangle(cornerRadius: PrismMetrics.listRowRadius)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
    }

    private func details(times: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if isLive { LiveBadge(pulsing: false, compact: true) }
                Text(times).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(program.title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let subtitle = program.subtitle, subtitle != program.title {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if let summary = program.summary, !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(7)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLive {
                PrimaryCapsuleButton("Regarder en direct", systemImage: "play.fill", style: .accent) {
                    showingDetails = false
                    onPlay()
                }
            } else if mightReplay, let action = replay() {
                PrimaryCapsuleButton("Revoir le programme", systemImage: "arrow.counterclockwise", style: .accent) {
                    showingDetails = false
                    action()
                }
            }
        }
        .padding(18)
        .frame(width: 310, alignment: .leading)
    }
}

/// Fits the visible day-part to the window and leaves the channel column fixed while paging time.
private nonisolated struct GuideTimeline: Sendable {
    static let slotDuration: TimeInterval = 1_800
    let interval: DateInterval
    let now: Date
    let width: CGFloat
    let slotCount: Int

    init(selectedStart: Date?, now: Date, width: CGFloat) {
        self.now = now
        self.width = width
        slotCount = min(8, max(4, Int(width / 102)))
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let halfHour = hour.addingTimeInterval(now.timeIntervalSince(hour) >= Self.slotDuration ? Self.slotDuration : 0)
        interval = DateInterval(
            start: selectedStart ?? halfHour.addingTimeInterval(-Self.slotDuration),
            duration: Double(slotCount) * Self.slotDuration
        )
    }

    var slotWidth: CGFloat { width / CGFloat(slotCount) }
    var nowPosition: CGFloat? { interval.start <= now && now < interval.end ? x(for: now) : nil }

    func tick(at index: Int) -> Date { interval.start.addingTimeInterval(Double(index) * Self.slotDuration) }
    func x(for date: Date) -> CGFloat { width * date.timeIntervalSince(interval.start) / interval.duration }
}
