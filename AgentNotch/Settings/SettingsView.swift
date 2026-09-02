import AppKit
import Combine
import Sparkle
import SwiftUI

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let store: UsageStore
    let updater: SPUUpdater

    private static let width: CGFloat = 460

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                assistants
                placement
                presence
                updates
                footer
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Agent Notch")
                .font(.system(size: 22, weight: .bold))
            Text("Reads usage from the tools already signed in on this Mac and never signs in itself.")
                .settingsDetail()
        }
    }

    private var assistants: some View {
        Section("Assistants") {
            VStack(spacing: 8) {
                ForEach(ProviderID.allCases) { id in
                    AccountRow(
                        id: id,
                        status: store.status(for: id),
                        isEnabled: Binding(
                            get: { !preferences.hiddenProviders.contains(id) },
                            set: { preferences.setProvider(id, enabled: $0) }
                        )
                    )
                }
            }
            Text("You stay signed in to the tool that owns each account. Switch accounts there and the notch follows.")
                .settingsDetail()
            if !preferences.hiddenProviders.contains(.claude) {
                Text(
                    "Claude's token is read from Claude Code's keychain item. macOS asks once whether to allow that; choosing Always Allow keeps it quiet."
                )
                .settingsDetail()
            }
        }
    }

    private var placement: some View {
        Section("Where the notch appears") {
            SettingsPicker(selection: $preferences.notchVisibility)
            SettingsPicker(selection: $preferences.notchEdge)
        }
    }

    private var presence: some View {
        Section("App icon") {
            SettingsPicker(selection: $preferences.appPresence)
            SettingsCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                            .font(.system(size: 13, weight: .medium))
                        if let error = preferences.loginItemError {
                            Text(error).settingsDetail()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("", isOn: $preferences.opensAtLogin)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
        }
    }

    private var updates: some View {
        UpdaterSettingsView(updater: updater)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text("Built with")
            Image(systemName: "heart.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .accessibilityLabel("love")
            Text("by")
            Link("Luca Becker", destination: URL(string: "https://x.com/itslucadev")!)
            Text("·")
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

/// Section title plus its content, spaced like a System Settings group.
private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content
        }
    }
}

/// Rounded surface shared by rows and the login toggle so trailing switches line up.
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Equal-width segmented control with the selected option's explanation underneath.
private struct SettingsPicker<Option: CaseIterable & Identifiable & Hashable & SettingsOption>: View
where Option.AllCases: RandomAccessCollection {
    @Binding var selection: Option

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(Option.allCases) { option in
                    let selected = option == selection
                    Text(option.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            selected ? Color.primary.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.18)) { selection = option }
                        }
                }
            }
            .padding(3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            Text(selection.detail)
                .settingsDetail()
                .padding(.horizontal, 2)
        }
    }
}

protocol SettingsOption {
    var title: String { get }
    var detail: String { get }
}

extension NotchVisibility: SettingsOption {}
extension NotchEdge: SettingsOption {}
extension AppPresence: SettingsOption {}

private extension Text {
    func settingsDetail() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Sparkle-backed update preferences. Properties are only written when the user toggles them.
private struct UpdaterSettingsView: View {
    let updater: SPUUpdater

    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool
    @State private var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticallyChecksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
        _automaticallyDownloadsUpdates = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        Section("Updates") {
            SettingsCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("Automatically check for updates")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("", isOn: $automaticallyChecksForUpdates)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    HStack(spacing: 12) {
                        Text("Download updates automatically")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Toggle("", isOn: $automaticallyDownloadsUpdates)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(!automaticallyChecksForUpdates)
                    }
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canCheckForUpdates)
                }
            }
            Text("Updates are signed and served from lucabecker.dev.")
                .settingsDetail()
        }
        .onChange(of: automaticallyChecksForUpdates) { _, value in
            updater.automaticallyChecksForUpdates = value
        }
        .onChange(of: automaticallyDownloadsUpdates) { _, value in
            updater.automaticallyDownloadsUpdates = value
        }
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheckForUpdates = $0 }
    }
}

/// One assistant: glyph, name and status, a button into the owning tool and the on/off switch.
struct AccountRow: View {
    let id: ProviderID
    let status: ProviderStatus
    @Binding var isEnabled: Bool

    var body: some View {
        SettingsCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(.black)
                    Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    ProviderGlyph(id: id)
                        .frame(width: 15, height: 15)
                        .foregroundStyle(.white)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(id.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    NSWorkspace.shared.open(id.manageURL)
                } label: {
                    Text(id.manageTitle).frame(width: 84)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Toggle("", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
        }
    }

    private var statusText: String {
        guard isEnabled else { return "Off. The notch is not reading \(id.ownerTool)." }
        switch status {
        case .ready(let snapshot, _):
            let who = [snapshot.account, snapshot.plan].compactMap { $0 }.joined(separator: " · ")
            return who.isEmpty ? "Signed in through \(id.ownerTool)" : who
        case .waiting: return "Waiting for the first reading"
        case .needsAuth(let message): return message
        case .failed(let message): return message
        }
    }
}
