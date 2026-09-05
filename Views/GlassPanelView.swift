import SwiftUI
import AppKit

// MARK: - 和風 palette

private enum Washi {
    /// 利休 — wabi-sabi dark green-gold accent (replaces the old 朱 vermilion)
    static let rikyu = Color(red: 0.45, green: 0.47, blue: 0.26)
    /// 藍鼠 — muted indigo-grey
    static let ai = Color(red: 0.31, green: 0.39, blue: 0.45)
    /// 苔 — muted moss green for the in-sync state
    static let matcha = Color(red: 0.44, green: 0.51, blue: 0.39)

    static let paperTop = Color(red: 0.969, green: 0.953, blue: 0.918)
    static let paperBottom = Color(red: 0.933, green: 0.910, blue: 0.867)
    static let sumiTop = Color(red: 0.118, green: 0.114, blue: 0.106)
    static let sumiBottom = Color(red: 0.078, green: 0.075, blue: 0.071)
}

// MARK: - Wave mark (app logo)

/// One sine cycle — the brand mark's wave. Keep in sync with
/// `branding/render_icon.swift`.
private func waveSine(_ t: Double, phase: Double = 0) -> Double {
    sin(t * 2 * .pi + phase)
}

/// The two band centres where the handle nodes sit (the crest and the trough).
private let waveBandT: [Double] = [0.25, 0.75]

private func wavePoint(_ t: Double, phase: Double = 0, in rect: CGRect) -> CGPoint {
    let x0 = rect.width * 0.14
    let x1 = rect.width * 0.86
    let midY = rect.height * 0.5
    let amp = rect.height * 0.27
    let x = x0 + (x1 - x0) * CGFloat(t)
    let y = midY - amp * CGFloat(waveSine(t, phase: phase))   // SwiftUI y is flipped: a crest lifts up
    return CGPoint(x: x, y: y)
}

/// The brand mark: a sine wave with draggable band nodes, drawn twice — a
/// 利休-green wave staggered behind the paper one (a phase-shifted afterimage:
/// the output trailing the source sample rate). Same geometry as
/// `branding/render_icon.swift`, so the logo matches the app icon.
private struct WaveResponseShape: Shape {
    var phase: Double = 0
    func path(in rect: CGRect) -> Path {
        let steps = 80
        var path = Path()
        for i in 0...steps {
            let point = wavePoint(Double(i) / Double(steps), phase: phase, in: rect)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private struct WaveMark: View {
    var size: CGFloat = 22

    var body: some View {
        let line = size * 0.12
        let corner = size * 0.28
        let nodeR = size * 0.12
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(
                    LinearGradient(colors: [Washi.sumiTop, Washi.sumiBottom],
                                   startPoint: .top, endPoint: .bottom)
                )
            WaveResponseShape(phase: 0.62)
                .stroke(Washi.rikyu, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
                .offset(x: size * 0.035, y: size * 0.05)
            WaveResponseShape()
                .stroke(Washi.paperTop, style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            ForEach(waveBandT.indices, id: \.self) { i in
                Circle()
                    .fill(Washi.sumiTop)
                    .overlay(Circle().strokeBorder(Washi.paperTop, lineWidth: size * 0.05))
                    .frame(width: nodeR * 2, height: nodeR * 2)
                    .position(wavePoint(waveBandT[i], in: rect))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
        .accessibilityLabel("Choritsu")
    }
}

// MARK: - Panel

struct GlassPanelView: View {
    @ObservedObject var model: SampleRateModel
    @ObservedObject var eq: EQModel
    @ObservedObject var updates: UpdateChecker
    @Environment(\.colorScheme) private var colorScheme
    @State private var showEQ = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainPanel
            if showEQ {
                Divider()
                EQView(eq: eq)
            }
        }
        .fontDesign(.rounded)
        .background(panelBackground)
    }

    private var mainPanel: some View {
        VStack(spacing: 14) {
            header
            nowPlayingSection
            transportSection
            sampleRateCard
            outputCard
            statusFooter
        }
        .padding(16)
        .frame(width: 352)
    }

    private var panelBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Washi.sumiTop, Washi.sumiBottom]
                : [Washi.paperTop, Washi.paperBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: Header

    private var eqButton: some View {
        Button {
            showEQ.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "slider.horizontal.3")
                Text("PEQ")
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(
                Capsule().fill(eq.isEnabled ? Washi.rikyu
                                            : Color.secondary.opacity(showEQ ? 0.22 : 0.12))
            )
            .foregroundStyle(eq.isEnabled ? Color.white : Color.primary)
            .overlay(
                Capsule().stroke(Washi.rikyu.opacity(showEQ && !eq.isEnabled ? 0.6 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Headphone EQ")
    }

    @ViewBuilder
    private var updateMenuItems: some View {
        switch updates.state {
        case let .available(version, _):
            Button("Update available — \(version)") { updates.openReleasePage() }
        case .checking:
            Text("Checking for updates…")
        case .upToDate:
            Text("Choritsu is up to date")
        case let .failed(message):
            Text("Update check failed: \(message)")
        case .idle:
            EmptyView()
        }

        Button("Check for Updates…") { updates.check(userInitiated: true) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            WaveMark(size: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("CHŌRITSU")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(3)
                Text("調律 · 音源と同じ律で")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            eqButton

            Menu {
                Toggle("Auto switch", isOn: $model.autoSwitchEnabled)
                Toggle("Log parser", isOn: $model.logParserEnabled)
                Divider()
                Button("Refresh now") { model.refreshNow() }
                Button("Restart log parser") { model.restartLogParser() }
                Button("Dump recent logs") { model.dumpRecentLogs() }
                Button("Dump now playing") { model.dumpNowPlaying() }
                Divider()
                updateMenuItems
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: Now playing

    private var nowPlayingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("再生中", "NOW PLAYING")

            HStack(spacing: 14) {
                artworkView

                VStack(alignment: .leading, spacing: 3) {
                    Text(model.currentTrackTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    if !model.artistName.isEmpty {
                        Text(model.artistName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !model.albumName.isEmpty {
                        Text(model.albumName)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            progressView
        }
    }

    private var artworkView: some View {
        Group {
            if let artwork = model.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }

    private var progressView: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Washi.rikyu.opacity(0.9), Washi.rikyu.opacity(0.55)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * playbackProgress))
                }
            }
            .frame(height: 3)

            HStack {
                Text(timeString(model.elapsedSeconds))
                Spacer()
                Text(timeString(model.durationSeconds))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var playbackProgress: Double {
        guard let elapsed = model.elapsedSeconds,
              let duration = model.durationSeconds,
              duration > 0 else {
            return 0
        }
        return min(max(elapsed / duration, 0), 1)
    }

    // MARK: Transport

    private var transportSection: some View {
        HStack(spacing: 18) {
            Button {
                model.previousTrack()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                model.togglePlayPause()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular.tint(Washi.rikyu), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                model.nextTrack()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Sample rate card

    private var rateInSync: Bool {
        model.trackSampleRateDisplay.contains("kHz")
            && model.trackSampleRateDisplay == model.outputSampleRateDisplay
    }

    private var sampleRateCard: some View {
        VStack(spacing: 12) {
            HStack {
                sectionLabel("音律", "SAMPLE RATE")
                Spacer()
                Toggle(isOn: $model.autoSwitchEnabled) {
                    Text("自動")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Washi.rikyu)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("音源 SOURCE")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.5)
                        .foregroundStyle(.tertiary)
                    Text(model.trackSampleRateDisplay)
                        .font(.system(size: 24, weight: .semibold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(model.sampleRateSourceDisplay)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(rateInSync ? Washi.matcha : Washi.rikyu)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("出力 OUTPUT")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.5)
                        .foregroundStyle(.tertiary)
                    outputRatePicker
                    syncBadge
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var outputRatePicker: some View {
        Menu {
            ForEach(model.availableSampleRates, id: \.self) { rate in
                Button {
                    model.selectSampleRate(rate)
                } label: {
                    if let current = model.outputSampleRate, abs(current - rate) < 1.0 {
                        Label(model.formatSampleRate(rate), systemImage: "checkmark")
                    } else {
                        Text(model.formatSampleRate(rate))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.outputSampleRateDisplay)
                    .font(.system(size: 24, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.availableSampleRates.isEmpty)
    }

    private var syncBadge: some View {
        Group {
            if rateInSync {
                badge("同期 IN SYNC", color: Washi.matcha)
            } else if model.trackSampleRateDisplay.contains("kHz") {
                badge("未同期 PENDING", color: Washi.rikyu)
            } else {
                badge("待機 STANDBY", color: .secondary)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5))
    }

    // MARK: Output device & volume

    private var outputCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(model.outputDevices) { device in
                        Button {
                            model.selectOutputDevice(device.id)
                        } label: {
                            if device.id == model.currentOutputDeviceID {
                                Label(device.name, systemImage: "checkmark")
                            } else {
                                Text(device.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.outputDeviceIcon)
                            .font(.system(size: 15))
                            .foregroundStyle(Washi.ai)
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.outputDeviceName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Text("出力デバイス OUTPUT DEVICE")
                                .font(.system(size: 8, weight: .medium))
                                .tracking(1.5)
                                .foregroundStyle(.tertiary)
                        }

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Spacer()

                Text(model.outputSampleRateDisplay)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                GlassVolumeSlider(
                    value: Binding(
                        get: { model.outputVolume },
                        set: { model.setVolume($0) }
                    ),
                    isEnabled: model.volumeAvailable,
                    onEditingChanged: { editing in
                        if editing {
                            model.beginVolumeAdjustment()
                        } else {
                            model.endVolumeAdjustment()
                        }
                    }
                )

                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text(model.volumeAvailable ? "\(Int((model.outputVolume * 100).rounded()))%" : "固定")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    // MARK: Footer

    @ViewBuilder
    private var statusFooter: some View {
        if !model.statusMessage.isEmpty || !model.logStatusMessage.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if !model.statusMessage.isEmpty {
                    Text(model.statusMessage)
                }
                if !model.logStatusMessage.isEmpty {
                    Text(model.logStatusMessage)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Helpers

    private func sectionLabel(_ kanji: String, _ latin: String) -> some View {
        HStack(spacing: 7) {
            Text(kanji)
                .font(.system(size: 10, weight: .medium))
            Rectangle()
                .fill(.tertiary)
                .frame(width: 1, height: 8)
            Text(latin)
                .font(.system(size: 10, weight: .medium))
                .tracking(2.2)
        }
        .foregroundStyle(.secondary)
    }

    private func timeString(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else {
            return "–:––"
        }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Glass volume slider

private struct GlassVolumeSlider: View {
    @Binding var value: Double
    var isEnabled: Bool
    var onEditingChanged: (Bool) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Washi.rikyu.opacity(0.85), Washi.rikyu.opacity(0.6)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geo.size.width * value))
            }
            .clipShape(Capsule())
            .glassEffect(.regular, in: .capsule)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        value = min(max(gesture.location.x / geo.size.width, 0), 1)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 20)
        .opacity(isEnabled ? 1 : 0.35)
        .allowsHitTesting(isEnabled)
    }
}
