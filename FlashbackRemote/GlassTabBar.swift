import SwiftUI

// A floating, translucent tab bar inspired by the iOS 26 "Liquid Glass" style.
// Built with materials so it runs on the current deployment target (the real
// iOS 26 glass APIs need the iOS 26 SDK).
struct GlassTabBar: View {
    @Binding var selection: ContentView.Tab

    struct Item: Identifiable {
        var id: ContentView.Tab { tab }
        let tab: ContentView.Tab
        let title: String
        let icon: String
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let selected = selection == item.tab
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        selection = item.tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 18, weight: .semibold))
                            .symbolVariant(selected ? .fill : .none)
                        Text(item.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.16))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
    }
}
