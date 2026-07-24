import SwiftUI
import UIKit

// Checks the SideStore source manifest for a newer version than what's
// installed, and shows a dismissible banner if one is found. The app can't
// install updates itself (SideStore owns that) — this just signals that one
// is available and offers a shortcut to open SideStore.
@MainActor
final class UpdateChecker: ObservableObject {
    @Published private(set) var latestVersion: String?
    @Published private(set) var dismissedVersion: String?

    private let sourceURL = URL(string: "https://raw.githubusercontent.com/deknared/flashback-remote/main/sidestore-source.json")!

    init() {
        dismissedVersion = UserDefaults.standard.string(forKey: "dismissedUpdateVersion")
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var updateAvailable: String? {
        guard let latest = latestVersion,
              Self.isNewer(latest, than: currentVersion),
              latest != dismissedVersion else { return nil }
        return latest
    }

    // Safe to call often (e.g. on every app foregrounding): the fetch is ~8KB,
    // and failures (like being on the camera's internet-less WiFi) just leave
    // the previous state — the next foreground retries automatically.
    func check() {
        Task {
            struct Source: Decodable {
                struct App: Decodable {
                    struct Version: Decodable { let version: String }
                    let versions: [Version]
                }
                let apps: [App]
            }
            guard let (data, _) = try? await URLSession.shared.data(from: sourceURL),
                  let decoded = try? JSONDecoder().decode(Source.self, from: data),
                  let latest = decoded.apps.first?.versions.first?.version else { return }
            latestVersion = latest
        }
    }

    // Manual check from Settings: also clears any per-version dismissal so the
    // banner re-appears if an update is available.
    func checkNow() {
        dismissedVersion = nil
        UserDefaults.standard.removeObject(forKey: "dismissedUpdateVersion")
        check()
    }

    func dismiss() {
        guard let latest = latestVersion else { return }
        dismissedVersion = latest
        UserDefaults.standard.set(latest, forKey: "dismissedUpdateVersion")
    }

    // Compares dotted version strings component-by-component (e.g. "1.3.10" > "1.3.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

struct UpdateBanner: View {
    let version: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available — v\(version)")
                    .font(.subheadline.weight(.semibold))
                Text("Open SideStore → My Apps to update")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openSideStore()
            } label: {
                Text("Open")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    // Best-effort: only works if SideStore is installed and registers this scheme.
    // If it isn't, UIApplication silently does nothing — no crash, no dead end.
    private func openSideStore() {
        guard let url = URL(string: "sidestore://") else { return }
        UIApplication.shared.open(url)
    }
}
