import SwiftUI

// Fitness-style morphing tab bar: a compact glass pill of bare icons where the
// active tab expands into a wider tinted segment showing its label. The tinted
// segment slides between tabs via matchedGeometryEffect.
struct GlassTabBar: View {
    @Binding var selection: ContentView.Tab
    @Namespace private var ns

    struct Item: Identifiable {
        var id: ContentView.Tab { tab }
        let tab: ContentView.Tab
        let title: String
        let icon: String
    }

    let items: [Item]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = selection == item.tab
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selection = item.tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .symbolVariant(selected ? .fill : .none)
                        if selected {
                            Text(item.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, selected ? 14 : 11)
                    .frame(height: 42)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.18))
                                .matchedGeometryEffect(id: "activeSegment", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)   // safety margin from screen edges on narrow devices
    }
}
