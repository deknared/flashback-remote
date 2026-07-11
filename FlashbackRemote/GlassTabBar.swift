import SwiftUI
import UIKit

// Fitness-style morphing tab bar with a scrubber gesture: dragging a finger
// across the bar live-switches pages to whichever tab is under the touch —
// like scrubbing a slider — rather than requiring a discrete tap per tab.
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

    @State private var itemFrames: [ContentView.Tab: CGRect] = [:]
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                itemView(item, selected: selection == item.tab)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: TabFramePreferenceKey.self,
                                value: [item.tab: geo.frame(in: .named("glassTabBarSpace"))]
                            )
                        }
                    )
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .coordinateSpace(name: "glassTabBarSpace")
        .onPreferenceChange(TabFramePreferenceKey.self) { itemFrames = $0 }
        .gesture(
            // minimumDistance: 0 makes a plain tap behave the same as a drag that
            // never moves — touch-down alone selects the tab under the finger,
            // and moving the finger live-scrubs between tabs before release.
            DragGesture(minimumDistance: 0, coordinateSpace: .named("glassTabBarSpace"))
                .onChanged { value in
                    guard let tab = tab(at: value.location.x), tab != selection else { return }
                    haptic.impactOccurred()
                    withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.86)) {
                        selection = tab
                    }
                }
        )
    }

    private func itemView(_ item: Item, selected: Bool) -> some View {
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
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.title)
    }

    private func tab(at x: CGFloat) -> ContentView.Tab? {
        for (tab, frame) in itemFrames where x >= frame.minX && x <= frame.maxX {
            return tab
        }
        // Off the ends of the bar (finger dragged past the first/last item) —
        // clamp to whichever edge tab is closest, so the scrub still tracks.
        guard let leftmost = itemFrames.min(by: { $0.value.minX < $1.value.minX }),
              let rightmost = itemFrames.max(by: { $0.value.maxX < $1.value.maxX }) else { return nil }
        if x < leftmost.value.minX { return leftmost.key }
        if x > rightmost.value.maxX { return rightmost.key }
        return nil
    }
}

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [ContentView.Tab: CGRect] = [:]
    static func reduce(value: inout [ContentView.Tab: CGRect], nextValue: () -> [ContentView.Tab: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
