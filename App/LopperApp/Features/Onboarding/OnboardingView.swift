import SwiftUI
import UniformTypeIdentifiers
import Lopper

/// First launch, and "Run setup again" from Settings: welcome, choose where to look, first scan. All three steps
/// share one dark stage with the living graph behind it, so the flow reads as one piece.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    var startingAt: OnboardingModel.Step = .welcome
    /// A fixed moment of the animation, for snapshots.
    var sceneTime: Double?

    var body: some View {
        OnboardingHost(app: app, startingAt: startingAt, sceneTime: sceneTime)
    }
}

private enum Stage {
    static let ink = Color(red: 0.045, green: 0.055, blue: 0.09)
    static let mint = Color(red: 0.55, green: 0.95, blue: 0.80)
    static let hairline = Color.white.opacity(0.09)
}

private struct OnboardingHost: View {
    let app: AppModel
    let sceneTime: Double?
    @State private var flow: OnboardingModel
    @State private var isDropTargeted = false

    init(app: AppModel, startingAt step: OnboardingModel.Step, sceneTime: Double?) {
        self.app = app
        self.sceneTime = sceneTime
        _flow = State(initialValue: OnboardingModel(
            client: app.client, existingRoots: app.settings.roots, startingAt: step))
    }

    var body: some View {
        ZStack {
            Stage.ink
            // One scene for the whole flow: it keeps running as the steps change, only quieter behind a panel.
            LopperScene(compact: flow.step != .welcome, intensity: flow.step == .welcome ? 1 : 0.7, fixedTime: sceneTime)
            Scrim(step: flow.step)

            Group {
                switch flow.step {
                case .welcome:
                    WelcomeStep(flow: flow)
                case .choose:
                    ChooseStep(flow: flow, app: app)
                case .scan:
                    ScanStep(flow: flow, app: app)
                }
            }
            .id(flow.step)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity.combined(with: .offset(x: -24))))

            if flow.step != .welcome {
                StepMarker(step: flow.step)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 26)
            }
        }
        .animation(.smooth(duration: 0.4), value: flow.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        // The picture runs up under the title bar instead of stopping at a strip of window grey.
        .ignoresSafeArea()
        .background(TransparentTitleBar())
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard flow.step == .choose else { return false }
            nonisolated(unsafe) let dropped = providers
            Task { flow.add(await DropReader.folders(from: dropped)) }
            return true
        }
        .overlay { if isDropTargeted && flow.step == .choose { DropHint() } }
        .task { await flow.loadSuggestions() }
    }
}

/// Keeps the words readable over the picture: a left-to-right fade on the welcome, a soft vignette behind panels.
private struct Scrim: View {
    let step: OnboardingModel.Step

    var body: some View {
        Group {
            if step == .welcome {
                LinearGradient(
                    stops: [
                        .init(color: Stage.ink.opacity(0.96), location: 0),
                        .init(color: Stage.ink.opacity(0.88), location: 0.38),
                        .init(color: Stage.ink.opacity(0), location: 0.66),
                    ],
                    startPoint: .leading, endPoint: .trailing)
            } else {
                RadialGradient(
                    colors: [Stage.ink.opacity(0.78), Stage.ink.opacity(0.35)],
                    center: .center, startRadius: 60, endRadius: 720)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct StepMarker: View {
    let step: OnboardingModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach([OnboardingModel.Step.welcome, .choose, .scan], id: \.self) { item in
                Capsule()
                    .fill(item == step ? Stage.mint : Color.white.opacity(0.18))
                    .frame(width: item == step ? 26 : 8, height: 6)
            }
        }
        .animation(.smooth, value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step == .choose ? 2 : 3) of 3")
    }
}

private enum DropReader {
    /// The folders among dropped items. Files are ignored: the person is choosing where projects live.
    static func folders(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                urls.append(url)
            }
        }
        return urls
    }
}

private struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 22)
            .strokeBorder(Stage.mint, style: StrokeStyle(lineWidth: 2.5, dash: [10, 8]))
            .background(Stage.mint.opacity(0.08), in: RoundedRectangle(cornerRadius: 22))
            .overlay {
                Label("Drop folders to add them", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Stage.mint)
            }
            .padding(Theme.Spacing.xl)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: Shared pieces

private struct GlassPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
            .background(
                LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.015)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22).strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)))
            .shadow(color: .black.opacity(0.35), radius: 34, y: 14)
    }
}

private struct StageButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost }

    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .foregroundStyle(foreground)
            .background {
                // The border is a slightly larger capsule behind the fill, not a stroke: strokes shimmer at the ends.
                Capsule()
                    .fill(kind == .secondary ? Color.white.opacity(0.22) : .clear)
                    .overlay { Capsule().fill(Stage.ink).padding(kind == .secondary ? 1 : 0).opacity(kind == .secondary ? 1 : 0) }
                    .overlay { Capsule().fill(background(pressed: configuration.isPressed)).padding(kind == .secondary ? 1 : 0) }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            .pointerCursor(isEnabled)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Stage.ink
        case .secondary, .ghost: .white.opacity(0.92)
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: Stage.mint.opacity(pressed ? 0.8 : (isHovering ? 1 : 0.92))
        case .secondary: Color.white.opacity(pressed ? 0.14 : (isHovering ? 0.12 : 0.06))
        case .ghost: Color.white.opacity(isHovering ? 0.08 : 0)
        }
    }
}

private extension ButtonStyle where Self == StageButtonStyle {
    static var stagePrimary: StageButtonStyle { StageButtonStyle(kind: .primary) }
    static var stageSecondary: StageButtonStyle { StageButtonStyle(kind: .secondary) }
    static var stageGhost: StageButtonStyle { StageButtonStyle(kind: .ghost) }
}

private struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(2.2)
            .foregroundStyle(Stage.mint.opacity(0.9))
    }
}

// MARK: Welcome

private struct WelcomeStep: View {
    let flow: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "scissors").foregroundStyle(Stage.mint)
                Text("Lopper").font(.headline)
            }
            Text("Keep your repositories light.")
                .font(.system(size: 42, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Lopper finds the branches, worktrees and build folders you no longer need, shows why each one is safe to remove, and lets you undo anything.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                TrustLine(symbol: "hand.raised", title: "You review everything", detail: "Nothing is removed until you confirm a list.")
                TrustLine(symbol: "arrow.uturn.backward.circle", title: "Undo for 30 days", detail: "Branches, worktrees and folders all come back.")
                TrustLine(symbol: "lock.shield", title: "Stays on your Mac", detail: "No account, no upload. Lopper only reads.")
            }
            .padding(.top, Theme.Spacing.xs)

            Button {
                flow.next()
            } label: {
                Text("Get started").frame(minWidth: 120)
            }
            .buttonStyle(.stagePrimary)
            .keyboardShortcut(.defaultAction)
            .padding(.top, Theme.Spacing.sm)
        }
        .frame(maxWidth: 470, alignment: .leading)
        .padding(.leading, 64)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrustLine: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Stage.mint)
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.white.opacity(0.62))
            }
        }
    }
}

// MARK: Choose

private struct ChooseStep: View {
    let flow: OnboardingModel
    let app: AppModel

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Eyebrow(text: "STEP 2 OF 3")
                Text("Where do your projects live?")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.4)
                Text("Pick the folders Lopper should look in. It only reads them, and you can change this any time.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
            }

            if app.toolStatusLoaded && app.toolStatus.gitVersion == nil {
                Banner(
                    symbol: "exclamationmark.triangle",
                    message: "Git is not installed. Install the Xcode command line tools (run xcode-select --install in Terminal), then reopen Lopper.")
                    .frame(maxWidth: 640)
            }

            GlassPanel {
                VStack(spacing: 0) {
                    if flow.candidates.isEmpty && flow.suggestionsLoaded {
                        EmptyHero(flow: flow)
                    } else if flow.candidates.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(0..<3, id: \.self) { index in
                                if index > 0 { Divider().overlay(Stage.hairline) }
                                SkeletonRow()
                            }
                        }
                    } else {
                        FolderList(flow: flow)
                        Divider().overlay(Stage.hairline)
                        ActionsBar(flow: flow)
                    }
                }
            }
            .frame(maxWidth: 640)

            HStack {
                Button("Back") { flow.back() }
                    .buttonStyle(.stageGhost)
                Spacer()
                Button {
                    flow.begin(app: app)
                } label: {
                    Text(flow.canContinue ? "Scan \(Plural.count(flow.selectedURLs.count, "folder"))" : "Choose a folder to continue")
                        .frame(minWidth: 150)
                }
                .buttonStyle(.stagePrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canContinue)
            }
            .frame(maxWidth: 640)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .padding(.bottom, 28)
        .task { await app.refreshToolStatus() }
    }
}

/// Shown when none of the usual folders exist: searching the Mac is the obvious next move, so it is the headline.
private struct EmptyHero: View {
    let flow: OnboardingModel

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                PulseRings(running: flow.isScanningSystem)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Stage.mint)
            }
            .frame(width: 120, height: 120)

            switch flow.systemScan {
            case .running(let folders, let repos):
                VStack(spacing: 4) {
                    Text("Looking through your Mac…").font(.system(size: 18, weight: .semibold))
                    Text("\(Plural.count(repos, "repository", "repositories")) found · \(folders) folders checked")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.62))
                        .monospacedDigit()
                }
                Button("Stop") { flow.stopSystemScan() }.buttonStyle(.stageSecondary)
            case .finished(0), .stopped:
                VStack(spacing: 4) {
                    Text("No repositories found").font(.system(size: 18, weight: .semibold))
                    Text("Nothing turned up in the places Lopper looked. Choose a folder yourself.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                }
                HStack(spacing: 10) {
                    Button("Search again") { flow.startSystemScan() }.buttonStyle(.stageSecondary)
                    Button("Choose a folder…") { FolderPicker.choose { flow.add($0) } }.buttonStyle(.stagePrimary)
                }
            default:
                VStack(spacing: 4) {
                    Text("Nothing in the usual places").font(.system(size: 18, weight: .semibold))
                    Text("Let Lopper look through your Mac for git repositories, or point it at a folder.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    Button { flow.startSystemScan() } label: {
                        Label("Search this Mac", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.stagePrimary)
                    Button("Choose a folder…") { FolderPicker.choose { flow.add($0) } }
                        .buttonStyle(.stageSecondary)
                }
                Text("macOS may ask for access to Documents, Desktop or Downloads. Allow it, or skip those. Lopper only reads.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 24)
    }
}

/// Rings that spread out from the middle, like a sonar. They speed up while a search is running.
private struct PulseRings: View {
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let speed = running ? 0.55 : 0.22
                for ring in 0..<3 {
                    let phase = (time * speed + Double(ring) / 3).truncatingRemainder(dividingBy: 1)
                    let radius = 18 + phase * (size.width / 2 - 18)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    context.stroke(
                        Path(ellipseIn: rect), with: .color(Stage.mint.opacity((1 - phase) * (running ? 0.55 : 0.32))),
                        lineWidth: 1.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FolderList: View {
    let flow: OnboardingModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(flow.candidates.enumerated()), id: \.element.id) { index, candidate in
                    if index > 0 { Divider().overlay(Stage.hairline) }
                    CandidateRow(candidate: candidate) { flow.toggle(candidate.id) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(height: min(268, CGFloat(flow.candidates.count) * 56))
        .animation(.snappy, value: flow.candidates.count)
    }
}

private struct CandidateRow: View {
    let candidate: OnboardingModel.Candidate
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.28), lineWidth: 1.5)
                        .opacity(candidate.isSelected ? 0 : 1)
                    Circle().fill(Stage.mint).opacity(candidate.isSelected ? 1 : 0)
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(Stage.ink)
                        .opacity(candidate.isSelected ? 1 : 0)
                }
                .frame(width: 20, height: 20)
                .animation(.snappy(duration: 0.18), value: candidate.isSelected)

                VStack(alignment: .leading, spacing: 2) {
                    Text(abbreviated(candidate.url))
                        .font(.system(size: 13.5, weight: .medium, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    if !candidate.sampleNames.isEmpty {
                        Text(candidate.sampleNames.joined(separator: " · "))
                            .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if candidate.source == .found {
                    Text("FOUND")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced)).tracking(1.2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .foregroundStyle(Stage.mint)
                        .background(Stage.mint.opacity(0.14), in: Capsule())
                }
                if let count = candidate.repoCount {
                    Text(count == 0 ? "empty" : "\(count)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(count == 0 ? .white.opacity(0.35) : .white.opacity(0.85))
                    Text(count == 1 ? "repo" : "repos")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.4))
                        .opacity(count == 0 ? 0 : 1)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(Color.white.opacity(isHovering ? 0.05 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .accessibilityLabel("\(abbreviated(candidate.url))")
        .accessibilityAddTraits(candidate.isSelected ? .isSelected : [])
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

private struct SkeletonRow: View {
    @State private var dim = false

    var body: some View {
        HStack(spacing: 14) {
            Circle().fill(Color.white.opacity(0.12)).frame(width: 20, height: 20)
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)).frame(width: 190, height: 12)
            Spacer()
            RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)).frame(width: 50, height: 10)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .opacity(dim ? 0.45 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true } }
        .accessibilityHidden(true)
    }
}

/// Under a list: look through the Mac, or choose a folder. While a search runs it shows what it has found.
private struct ActionsBar: View {
    let flow: OnboardingModel

    var body: some View {
        HStack(spacing: 10) {
            switch flow.systemScan {
            case .running(let folders, let repos):
                ProgressView().controlSize(.small).tint(Stage.mint)
                Text("\(Plural.count(repos, "repository", "repositories")) · \(folders) folders checked")
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
                Button("Stop") { flow.stopSystemScan() }.buttonStyle(.stageGhost)
            case .finished(let found):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Stage.mint)
                Text(found == 0 ? "Nothing new found" : "Added \(Plural.count(found, "folder"))")
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                Button("Search again") { flow.startSystemScan() }.buttonStyle(.stageGhost)
            case .idle, .stopped:
                Button { flow.startSystemScan() } label: {
                    Label("Search this Mac", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.stageSecondary)
                .help("macOS may ask for access to Documents, Desktop or Downloads. Lopper only reads.")
            }
            Spacer()
            Button { FolderPicker.choose { flow.add($0) } } label: {
                Label("Choose folder…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.stageSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: First scan

private struct ScanStep: View {
    let flow: OnboardingModel
    let app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if app.isScanning || app.phase == .idle {
                    scanning
                } else if app.snapshots.isEmpty {
                    empty
                } else {
                    payoff
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .padding(.leading, 64)
            Spacer(minLength: 0)
        }
        .animation(.smooth, value: app.isScanning)
    }

    // MARK: Reading

    private var scanning: some View {
        let read = app.results.count
        var total = 0
        if case .scanning(_, let count) = app.phase { total = count }
        let names = app.results.suffix(6).map { $0.repoRoot.lastPathComponent }

        return VStack(alignment: .leading, spacing: 18) {
            Eyebrow(text: "STEP 3 OF 3")
            Text("Reading your repositories")
                .font(.system(size: 34, weight: .bold)).tracking(-0.5)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(read)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(value: Double(read)))
                    .monospacedDigit()
                if total > 0 {
                    Text("of \(total)")
                        .font(.system(size: 22, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .animation(.snappy, value: read)

            ProgressLine(fraction: total > 0 ? Double(read) / Double(total) : nil)
                .frame(height: 5)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(names.enumerated()), id: \.element) { index, name in
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Stage.mint)
                        Text(name).font(.system(size: 13, design: .monospaced))
                    }
                    .opacity(0.3 + 0.7 * Double(index + 1) / Double(max(names.count, 1)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(height: 6 * 22, alignment: .bottom)
            .animation(.snappy, value: names)
            .clipped()

            Text("Lopper only reads. Nothing is changed.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow(text: "STEP 3 OF 3")
            Text("No repositories in those folders")
                .font(.system(size: 32, weight: .bold)).tracking(-0.4)
            Text("Try a folder higher up, or add another one.")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.62))
            Button("Choose different folders") { flow.back() }
                .buttonStyle(.stagePrimary)
                .padding(.top, 6)
        }
    }

    // MARK: Ready

    private var payoff: some View {
        let totals = app.totals
        return VStack(alignment: .leading, spacing: 20) {
            Eyebrow(text: totals.reclaimableBytes > 0 ? "READY TO RECLAIM" : "READY TO CLEAN")
            Text(app.heroValue)
                .font(.system(size: 92, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .monospacedDigit()
                .foregroundStyle(LinearGradient(colors: [.white, Stage.mint], startPoint: .top, endPoint: .bottom))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("\(Plural.count(totals.repositories, "repository", "repositories")) read. "
                + "\(Plural.count(totals.safe, "branch or worktree", "branches and worktrees")) are safe to remove.")
                .font(.system(size: 16)).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                CountChip(value: totals.safe, label: "safe", tint: Color(red: 0.42, green: 0.95, blue: 0.62))
                CountChip(value: totals.review, label: "need a look", tint: Color(red: 1.0, green: 0.72, blue: 0.35))
                CountChip(value: totals.protected, label: "protected", tint: .white.opacity(0.55))
            }

            Label("Nothing has been changed. You review every removal first.", systemImage: "hand.raised")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.55))

            HStack(spacing: 10) {
                Button {
                    app.completeOnboarding()
                } label: {
                    Text("Open Lopper").frame(minWidth: 120)
                }
                .buttonStyle(.stagePrimary)
                .keyboardShortcut(.defaultAction)
                Button("Change folders") { flow.back() }.buttonStyle(.stageGhost)
            }
            .padding(.top, 4)
        }
    }
}

private struct CountChip: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text("\(value)").font(.system(size: 14, weight: .bold, design: .monospaced)).monospacedDigit()
            Text(label).font(.system(size: 13)).foregroundStyle(.white.opacity(0.62))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background {
            Capsule().fill(Stage.hairline)
                .overlay { Capsule().fill(Stage.ink).padding(1) }
                .overlay { Capsule().fill(Color.white.opacity(0.06)).padding(1) }
        }
    }
}

/// A thin glowing line. With no total yet it shimmers instead of filling.
private struct ProgressLine: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                if let fraction {
                    Capsule()
                        .fill(LinearGradient(colors: [Stage.mint.opacity(0.6), Stage.mint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, proxy.size.width * fraction))
                        .shadow(color: Stage.mint.opacity(0.6), radius: 8)
                        .animation(.snappy, value: fraction)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                        Capsule()
                            .fill(Stage.mint)
                            .frame(width: proxy.size.width * 0.28)
                            .offset(x: (proxy.size.width * 1.28) * phase - proxy.size.width * 0.28)
                            .shadow(color: Stage.mint.opacity(0.6), radius: 8)
                    }
                }
            }
            .clipShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scan progress")
    }
}
