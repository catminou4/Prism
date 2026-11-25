import Foundation
import SwiftUI
import PrismCore
import PrismData
import PrismDesign

private let guideTimeFormat = Date.FormatStyle.dateTime.hour().minute().locale(Locale(identifier: "fr_FR"))

/// The wall clock of the guide, split in two granularities: `now` ticks every 30 s
/// and is read only by the now-line overlays and the header time capsule, while
/// `alignment` is rewritten solely when the half-hour bucket flips. Rows and the
/// timeline derive from `alignment`, so they re-evaluate at most every 30 minutes
/// (or on input changes) instead of on every tick.
@MainActor
@Observable
final class GuideClock {
    private(set) var now = Date.now
    private(set) var alignment = Date.now

    func tick() {
        let instant = Date.now
        now = instant
        if GuideTimeline.halfHourStart(for: instant) != GuideTimeline.halfHourStart(for: alignment) {
            alignment = instant
        }
    }
}

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
    @Environment(\.appearsActive) private var appearsActive
    @State private var clock = GuideClock()
    /// Live mirror of the guide's scroll phase: the rows read it without invalidating —
    /// only a currently-hovered button observes the flip, the rest never re-evaluate.
    @State private var scrollActivity = ScrollActivity()

    var body: some View {
        GeometryReader { geometry in
            let channelWidth = min(220, max(146, geometry.size.width * 0.23))
            let margin = PrismMetrics.contentMargin
            let timeWidth = max(1, geometry.size.width - 2 * margin - channelWidth)
            // Stable across ticks: derived from the half-hour alignment, not the clock.
            let timeline = GuideTimeline(selectedStart: start, now: clock.alignment, width: timeWidth)
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
                .prismScrollPhase { scrolling in scrollActivity.update(isScrolling: scrolling) }
                .environment(\.prismScrollActivity, scrollActivity)
            }
            .padding(.top, 8)
        }
        .task(id: isPageActive && appearsActive) {
            // Same occlusion/inactivity pausing as the former LiveClock wrapper.
            guard isPageActive, appearsActive else { return }
            while !Task.isCancelled {
                clock.tick()
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(3))
            }
        }
    }

    private func controls(_ timeline: GuideTimeline) -> some View {
        let controlSize = PrismMetrics.compactButtonSize
        return HStack(spacing: 10) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    GlassCircleButton(systemName: "chevron.left", size: controlSize, accessibilityLabel: "Programmes précédents") {
                        start = timeline.interval.start.addingTimeInterval(-timeline.interval.duration)
                    }
                    .help("Programmes précédents")
                    GlassCircleButton(systemName: "chevron.right", size: controlSize, accessibilityLabel: "Programmes suivants") {
                        start = timeline.interval.end
                    }
                    .help("Programmes suivants")
                }
            }
            DatePicker("Jour du programme", selection: Binding(
                get: { timeline.interval.start },
                set: { date in
                    let calendar = Calendar.current
                    start = calendar.isDate(date, inSameDayAs: .now) ? nil : calendar.startOfDay(for: date)
                }
            ), displayedComponents: .date)
            .labelsHidden()
            .datePickerStyle(.compact)
            .environment(\.locale, Locale(identifier: "fr_FR"))
            Spacer(minLength: 10)
            GlassCapsuleButton(title: "Maintenant", systemImage: "clock", trailingChevron: false, style: .regular) {
                start = nil
            }
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

    private func timelineHeader(_ timeline: GuideTimeline, channelWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("Chaînes")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: channelWidth, alignment: .leading)
            GuideTimelineScale(clock: clock, timeline: timeline)
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityAddTraits(.isHeader)
    }

    private func guideRow(_ channel: ChannelGroup, timeline: GuideTimeline, channelWidth: CGFloat) -> some View {
        let id = guide.resolveEPGID(for: channel)
        let programmes = id.map { guide.programs(forEPGID: $0, in: timeline.interval) } ?? []
        let archiveWindow = channel.variants.lazy.compactMap { $0.catchup?.days }.max() ?? 0
        // Resolved when the action fires, not at body evaluation: the row no longer
        // re-evaluates on clock ticks, so a captured time would go minutes stale.
        func airingProgramme() -> EPGProgram? {
            id.flatMap { guide.nowAndNext(forEPGID: $0, at: .now).now }
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
                        program: program, width: width,
                        archiveWindow: archiveWindow,
                        onPlay: { onPlay(channel, program) },
                        replay: { onReplay(channel, program, .now) }
                    )
                    .offset(x: x + 1.5, y: 3)
                }
                GuideNowLine(clock: clock, timeline: timeline, height: Self.rowHeight)
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

/// Tick labels and the current-time capsule of the timeline header. This is the only
/// part of the header reading the 30 s clock — a handful of text labels — so the rows
/// underneath stay untouched by the ticks.
private struct GuideTimelineScale: View {
    let clock: GuideClock
    let timeline: GuideTimeline

    var body: some View {
        let currentLabelX = timeline.nowPosition(at: clock.now).map { max(22, min($0, timeline.width - 22)) }
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
                Text(clock.now, format: guideTimeFormat)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: .capsule)
                    .fixedSize()
                    .position(x: currentLabelX, y: 15)
                    .accessibilityLabel("Heure actuelle \(clock.now.formatted(guideTimeFormat))")
            }
        }
        .frame(width: timeline.width, height: 30)
    }
}

/// One row's slice of the now-line. Tiny and self-contained: the 30 s clock moves
/// these overlays without re-evaluating the row's programmes or canvas.
private struct GuideNowLine: View {
    let clock: GuideClock
    let timeline: GuideTimeline
    let height: CGFloat

    var body: some View {
        if let x = timeline.nowPosition(at: clock.now) {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 1.5, height: height)
                .offset(x: x)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct GuideChannelButton: View {
    let channel: ChannelGroup
    let play: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismScrollActivity) private var scrollActivity

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
        // Live read through the activity object: correct without any re-evaluation.
        .onHover { if scrollActivity?.isScrolling != true { hovered = $0 } }
        // Short-circuited behind `hovered`: unhovered buttons never subscribe to the
        // scroll phase, so a scroll start/stop no longer re-evaluates every row — only
        // the one hovered button invalidates, drops its hover, then unsubscribes.
        .onChange(of: hovered && (scrollActivity?.isScrolling ?? false)) { _, shouldReset in
            if shouldReset { hovered = false }
        }
        .animation(reduceMotion ? nil : PrismMotion.quickFade, value: hovered)
        .help(channel.name)
        .accessibilityLabel(channel.number.map { "Chaîne \($0), \(channel.name)" } ?? channel.name)
        .accessibilityHint("Regarder en direct")
    }
}

private struct GuideProgrammeButton: View {
    let program: EPGProgram
    let width: CGFloat
    let archiveWindow: Int
    let onPlay: () -> Void
    let replay: () -> (() -> Void)?
    @State private var showingDetails = false
    @State private var hovered = false
    /// Flip exactly at programme boundaries via the boundary-sleeping task below —
    /// the guide's 30 s clock never reaches these buttons anymore.
    @State private var isLive: Bool
    @State private var mightReplay: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismScrollActivity) private var scrollActivity

    init(program: EPGProgram, width: CGFloat, archiveWindow: Int, onPlay: @escaping () -> Void, replay: @escaping () -> (() -> Void)?) {
        self.program = program
        self.width = width
        self.archiveWindow = archiveWindow
        self.onPlay = onPlay
        self.replay = replay
        let now = Date.now
        _isLive = State(initialValue: program.isAiring(at: now))
        _mightReplay = State(initialValue: Self.replayable(program, at: now, archiveWindow: archiveWindow))
    }

    private static func replayable(_ program: EPGProgram, at now: Date, archiveWindow: Int) -> Bool {
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
        // Live read through the activity object: correct without any re-evaluation.
        .onHover { if scrollActivity?.isScrolling != true { hovered = $0 } }
        // Short-circuited behind `hovered`: unhovered buttons never subscribe to the
        // scroll phase, so a scroll start/stop no longer re-evaluates every programme —
        // only the one hovered button invalidates, drops its hover, then unsubscribes.
        .onChange(of: hovered && (scrollActivity?.isScrolling ?? false)) { _, shouldReset in
            if shouldReset { hovered = false }
        }
        .animation(reduceMotion ? nil : PrismMotion.quickFade, value: hovered)
        .help("\(program.title) · \(times)")
        .accessibilityLabel("\(program.title), \(times)\(isLive ? ", en direct" : "")")
        .accessibilityHint("Afficher le programme")
        .popover(isPresented: $showingDetails, arrowEdge: .bottom) { details(times: times) }
        .task {
            // Sleep until the next instant that can flip either state — programme
            // start, programme end, replay-window expiry — instead of re-evaluating
            // on every clock tick. Between boundaries the button is truly static.
            while !Task.isCancelled {
                let now = Date.now
                let live = program.isAiring(at: now)
                let replayable = Self.replayable(program, at: now, archiveWindow: archiveWindow)
                if live != isLive { isLive = live }
                if replayable != mightReplay { mightReplay = replayable }
                var boundaries: [TimeInterval] = []
                if program.start > now { boundaries.append(program.start.timeIntervalSince(now)) }
                if program.end > now { boundaries.append(program.end.timeIntervalSince(now)) }
                if archiveWindow > 0 {
                    let expiry = program.start.addingTimeInterval(Double(archiveWindow) * 86_400)
                    if expiry > now { boundaries.append(expiry.timeIntervalSince(now)) }
                }
                guard let next = boundaries.min() else { return }
                try? await Task.sleep(for: .seconds(next + 0.25))
            }
        }
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
/// Carries no clock of its own: the interval derives from the half-hour alignment fed
/// to `init`, and the clock-dependent positions are computed per query in `nowPosition(at:)`.
private nonisolated struct GuideTimeline: Sendable {
    static let slotDuration: TimeInterval = 1_800
    let interval: DateInterval
    let width: CGFloat
    let slotCount: Int

    init(selectedStart: Date?, now: Date, width: CGFloat) {
        self.width = width
        slotCount = min(8, max(4, Int(width / 102)))
        let halfHour = Self.halfHourStart(for: now)
        interval = DateInterval(
            start: selectedStart ?? halfHour.addingTimeInterval(-Self.slotDuration),
            duration: Double(slotCount) * Self.slotDuration
        )
    }

    /// The start of the half-hour bucket containing `date` — the granularity at which
    /// the rolling interval actually changes, whatever the tick rate is.
    static func halfHourStart(for date: Date) -> Date {
        let calendar = Calendar.current
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        return hour.addingTimeInterval(date.timeIntervalSince(hour) >= slotDuration ? slotDuration : 0)
    }

    var slotWidth: CGFloat { width / CGFloat(slotCount) }

    func nowPosition(at now: Date) -> CGFloat? { interval.start <= now && now < interval.end ? x(for: now) : nil }

    func tick(at index: Int) -> Date { interval.start.addingTimeInterval(Double(index) * Self.slotDuration) }
    func x(for date: Date) -> CGFloat { width * date.timeIntervalSince(interval.start) / interval.duration }
}
