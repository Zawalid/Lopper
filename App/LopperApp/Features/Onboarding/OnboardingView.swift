import SwiftUI
import UniformTypeIdentifiers
import Lopper

/// First launch, and "Run setup again" from Settings: welcome, choose where to look, first scan.
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    var startingAt: OnboardingModel.Step = .welcome

    var body: some View {
        OnboardingHost(app: app, startingAt: startingAt)
    }
}

private struct OnboardingHost: View {
    let app: AppModel
    @State private var flow: OnboardingModel
    @State private var isDropTargeted = false

    init(app: AppModel, startingAt step: OnboardingModel.Step) {
        self.app = app
        _flow = State(initialValue: OnboardingModel(
            client: app.client, existingRoots: app.settings.roots, startingAt: step))
    }

    var body: some View {
        ZStack {
            Backdrop()
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
                insertion: .opacity.combined(with: .offset(x: 28)), removal: .opacity.combined(with: .offset(x: -28))))
        }
        .animation(.smooth(duration: 0.35), value: flow.step)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// A soft wash of colour behind the flow, so it does not read as an ordinary window.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.pageBackground
            RadialGradient(
                colors: [Color.accentColor.opacity(0.14), .clear], center: .topTrailing, startRadius: 20, endRadius: 520)
            RadialGradient(
                colors: [Color.green.opacity(0.08), .clear], center: .bottomLeading, startRadius: 20, endRadius: 460)
        }
        .ignoresSafeArea()
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
        RoundedRectangle(cornerRadius: 20)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
            .overlay {
                Label("Drop folders to add them", systemImage: "square.and.arrow.down")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(Theme.Spacing.lg)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: Welcome

private struct WelcomeStep: View {
    let flow: OnboardingModel

    var body: some View {
        HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "scissors").foregroundStyle(.tint)
                    Text("Lopper").font(.headline)
                }
                Text("Keep your repositories light.")
                    .font(.system(size: 38, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Lopper finds the branches, worktrees and build folders you no longer need, shows why each one is safe to remove, and lets you undo anything.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
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
                    Text("Get started").frame(minWidth: 140)
                }
                .buttonStyle(.lopperPrimary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, Theme.Spacing.sm)
            }
            .frame(maxWidth: 470, alignment: .leading)

            WelcomeArt()
                .frame(width: 340, height: 400)
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 36)
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: Choose

private struct ChooseStep: View {
    let flow: OnboardingModel
    let app: AppModel

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            VStack(spacing: Theme.Spacing.xs) {
                Text("Where do your projects live?").font(.system(size: 28, weight: .bold))
                Text("Pick the folders Lopper should look in. It only reads them, and you can change this any time.")
                    .font(.title3).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if app.toolStatusLoaded && app.toolStatus.gitVersion == nil {
                Banner(
                    symbol: "exclamationmark.triangle",
                    message: "Git is not installed. Install the Xcode command line tools (run xcode-select --install in Terminal), then reopen Lopper.")
                    .frame(maxWidth: 640)
            }

            FolderList(flow: flow)
                .frame(maxWidth: 640)

            HStack(spacing: Theme.Spacing.md) {
                SystemScanCard(flow: flow)
                ActionCard(
                    symbol: "folder.badge.plus", title: "Choose folders…",
                    detail: "Or drop folders anywhere in this window.",
                    action: { FolderPicker.choose { flow.add($0) } })
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 640)

            HStack {
                Button("Back") { flow.back() }
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.large)
                Spacer()
                Button {
                    flow.begin(app: app)
                } label: {
                    Text(flow.canContinue
                        ? "Scan \(Plural.count(flow.selectedURLs.count, "folder"))"
                        : "Choose at least one folder")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.lopperPrimary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!flow.canContinue)
            }
            .frame(maxWidth: 640)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 28)
        .task { await app.refreshToolStatus() }
    }
}

private struct FolderList: View {
    let flow: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            if !flow.suggestionsLoaded && flow.candidates.isEmpty {
                ForEach(0..<3, id: \.self) { index in
                    if index > 0 { Divider() }
                    SkeletonRow()
                }
            } else if flow.candidates.isEmpty {
                VStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "folder.badge.questionmark").font(.title).foregroundStyle(.secondary)
                    Text("No usual project folders found").font(.headline)
                    Text("Find repositories on this Mac, or choose a folder yourself.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(Theme.Spacing.xl)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(flow.candidates.enumerated()), id: \.element.id) { index, candidate in
                            if index > 0 { Divider() }
                            CandidateRow(candidate: candidate) { flow.toggle(candidate.id) }
                        }
                    }
                }
                // As tall as its rows, up to a limit, so a short list does not sit in an empty box.
                .frame(height: min(260, CGFloat(flow.candidates.count) * 41))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
        .animation(.snappy, value: flow.candidates.count)
    }
}

private struct CandidateRow: View {
    let candidate: OnboardingModel.Candidate
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: candidate.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(candidate.isSelected ? Color.accentColor : Theme.metaText)
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(abbreviated(candidate.url)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if !candidate.sampleNames.isEmpty {
                        Text(candidate.sampleNames.joined(separator: ", "))
                            .font(.caption).foregroundStyle(Theme.metaText).lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Spacing.md)
                if candidate.source == .found {
                    Text("Found")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                Text(countText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(candidate.repoCount == 0 ? Theme.metaText : .secondary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 10)
            .background(isHovering ? Color.primary.opacity(0.05) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .accessibilityLabel("\(abbreviated(candidate.url)), \(countText)")
        .accessibilityAddTraits(candidate.isSelected ? .isSelected : [])
    }

    private var countText: String {
        guard let count = candidate.repoCount else { return "" }
        return count == 0 ? "no repositories yet" : Plural.count(count, "repository", "repositories")
    }

    private func abbreviated(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}

private struct SkeletonRow: View {
    @State private var dim = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Circle().fill(Color.secondary.opacity(0.2)).frame(width: 18, height: 18)
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.2)).frame(width: 180, height: 12)
            Spacer()
            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)).frame(width: 80, height: 10)
        }
        .padding(Theme.Spacing.md)
        .opacity(dim ? 0.5 : 1)
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true } }
        .accessibilityHidden(true)
    }
}

private struct ActionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .leading)
            .background(
                isHovering ? Color.primary.opacity(0.06) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
    }
}

private struct SystemScanCard: View {
    let flow: OnboardingModel

    var body: some View {
        switch flow.systemScan {
        case .idle, .stopped:
            ActionCard(
                symbol: "magnifyingglass", title: "Find repositories on this Mac",
                detail: idleDetail, action: { flow.startSystemScan() })
        case .finished(let found):
            ActionCard(
                symbol: "checkmark.circle", title: found == 0 ? "Nothing new found" : "Found \(Plural.count(found, "more folder"))",
                detail: "Search again", action: { flow.startSystemScan() })
        case .running(let folders, let repos):
            HStack(spacing: Theme.Spacing.md) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Looking… \(Plural.count(repos, "repository", "repositories"))")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    Text("\(folders) folders checked. Nothing is changed.")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
                Button("Stop") { flow.stopSystemScan() }
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 64, maxHeight: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color.accentColor.opacity(0.5)))
        }
    }

    private var idleDetail: String {
        if case .stopped = flow.systemScan { return "Stopped. Search again" }
        return "macOS may ask for access to Documents, Desktop or Downloads. Allow it, or skip those."
    }
}

// MARK: First scan

private struct ScanStep: View {
    let flow: OnboardingModel
    let app: AppModel

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if app.isScanning || app.phase == .idle {
                scanning
            } else if app.snapshots.isEmpty {
                empty
            } else {
                payoff
            }
        }
        .padding(40)
        .frame(maxWidth: 760)
        .animation(.smooth, value: app.isScanning)
    }

    private var scanning: some View {
        VStack(spacing: Theme.Spacing.lg) {
            WelcomeArt().frame(width: 220, height: 260)
            if case .scanning(let done, let total) = app.phase, total > 0 {
                Text("Reading repository \(done) of \(total)…").font(.title3.weight(.medium)).monospacedDigit()
                ProgressView(value: Double(done), total: Double(total)).frame(maxWidth: 320)
            } else {
                Text("Looking for repositories…").font(.title3.weight(.medium))
                ProgressView().controlSize(.regular)
            }
            Text("Lopper only reads. Nothing is changed.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("No repositories in those folders").font(.title2.weight(.semibold))
            Text("Try a folder higher up, or add another one.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Choose different folders") { flow.back() }
                .buttonStyle(.lopperPrimary)
                .controlSize(.large)
        }
    }

    private var payoff: some View {
        let totals = app.totals
        return VStack(spacing: Theme.Spacing.lg) {
            Text(app.heroHeadline).font(.title3).foregroundStyle(.secondary)
            Text(app.heroValue)
                .font(.system(size: 76, weight: .bold))
                .contentTransition(.numericText())
                .monospacedDigit()
            Text("\(Plural.count(totals.repositories, "repository", "repositories")) read. "
                + "\(Plural.count(totals.safe, "branch or worktree", "branches and worktrees")) are safe to remove.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: Theme.Spacing.md) {
                StatTile(title: "Safe to remove", value: "\(totals.safe)", symbol: "checkmark.circle", tint: VerdictKind.safe.tint)
                StatTile(title: "Need a look", value: "\(totals.review)", symbol: "eye", tint: VerdictKind.review.tint)
                StatTile(title: "Protected", value: "\(totals.protected)", symbol: "lock", tint: VerdictKind.protected.tint)
            }
            .frame(maxWidth: 560)

            Label("Nothing has been changed. You review every removal first.", systemImage: "hand.raised")
                .font(.callout).foregroundStyle(.secondary)

            HStack(spacing: Theme.Spacing.md) {
                Button("Change folders") { flow.back() }
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.large)
                Button {
                    app.completeOnboarding()
                } label: {
                    Text("Open Lopper").frame(minWidth: 140)
                }
                .buttonStyle(.lopperPrimary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
