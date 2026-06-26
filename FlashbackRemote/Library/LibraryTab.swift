import SwiftUI
import UIKit

struct ViewerContext: Identifiable {
    let id = UUID()
    let groupID: String
    let startID: String
}

struct LibraryTab: View {
    @StateObject private var vm = LibraryViewModel()
    @Binding var hideTabBar: Bool

    @State private var viewer: ViewerContext?
    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var collapsed: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var sharePayload: SharePayload?

    // Rename a group / name a new group from selection.
    @State private var renamingGroup: LibraryGroup?
    @State private var renameText = ""
    @State private var showRenameAlert = false
    @State private var showGroupAlert = false
    @State private var groupNameText = ""

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                if vm.groups.isEmpty {
                    emptyView
                } else {
                    content
                }
            }
            .navigationTitle("Library")
            .toolbar { toolbarContent }
            .overlay(alignment: .bottom) {
                if isSelecting { selectionActionBar }
            }
            .onAppear { vm.load() }
            .onChange(of: isSelecting) { selecting in
                withAnimation(.easeInOut(duration: 0.2)) { hideTabBar = selecting }
            }
            .onDisappear { hideTabBar = false }
            .fullScreenCover(item: $viewer) { ctx in
                PhotoViewer(vm: vm, groupID: ctx.groupID, startID: ctx.startID)
            }
            .confirmationDialog("Delete \(selection.count) photo\(selection.count == 1 ? "" : "s")?",
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    vm.delete(ids: selection)
                    exitSelection()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes the selected DNGs and their matching JPEGs from this iPhone.")
            }
            .alert("Rename group", isPresented: $showRenameAlert) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let g = renamingGroup { vm.rename(group: g, to: renameText) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(renamingGroup?.isUngrouped == true
                     ? "Creates a group with this name and moves these photos into it."
                     : "")
            }
            .alert("New group", isPresented: $showGroupAlert) {
                TextField("Group name", text: $groupNameText)
                Button("Group") {
                    vm.group(ids: selection, intoName: groupNameText)
                    exitSelection()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Moves the selected photos into a group with this name.")
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(items: payload.urls)
            }
        }
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(vm.groups) { group in
                    Section {
                        if !collapsed.contains(group.id) {
                            LazyVGrid(columns: columns, spacing: 4) {
                                ForEach(group.items) { item in
                                    cell(item, group: group)
                                }
                            }
                            .padding(.horizontal, 4)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .padding(.bottom, 90)   // clear the floating tab/selection bar
        }
        .refreshable { vm.load() }
    }

    private func cell(_ item: LibraryItem, group: LibraryGroup) -> some View {
        Button {
            if isSelecting { toggle(item) }
            else { viewer = ViewerContext(groupID: group.id, startID: item.id) }
        } label: {
            LibraryThumbnail(item: item,
                             showBadge: vm.showsRawBadges,
                             isSelecting: isSelecting,
                             isSelected: selection.contains(item.id))
        }
        .buttonStyle(.plain)
    }

    private func groupHeader(_ group: LibraryGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: collapsed.contains(group.id) ? "chevron.right" : "chevron.down")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(group.name)
                .font(.headline)
            Text("\(group.items.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { toggleCollapse(group.id) }
        }
        .onLongPressGesture { startRename(group) }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Cancel") { exitSelection() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected { selection = [] }
                    else { selection = Set(vm.allItems.map(\.id)) }
                }
            }
        } else if !vm.groups.isEmpty {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Select") { isSelecting = true }
            }
        }
    }

    private var selectionActionBar: some View {
        HStack(spacing: 22) {
            Button {
                let urls = vm.fileURLs(for: selection)
                if !urls.isEmpty { sharePayload = SharePayload(urls: urls) }
            } label: {
                Image(systemName: "square.and.arrow.up").font(.title3)
            }
            .disabled(selection.isEmpty)

            Button {
                groupNameText = ""
                showGroupAlert = true
            } label: {
                Image(systemName: "folder.badge.plus").font(.title3)
            }
            .disabled(selection.isEmpty)

            Spacer()
            Text(selection.isEmpty ? "Select Photos" : "\(selection.count) Selected")
                .font(.subheadline.weight(.medium))
            Spacer()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash").font(.title3)
            }
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var allSelected: Bool { !vm.allItems.isEmpty && selection.count == vm.allItems.count }

    private func toggle(_ item: LibraryItem) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else { selection.insert(item.id) }
    }

    private func toggleCollapse(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    private func startRename(_ group: LibraryGroup) {
        renamingGroup = group
        renameText = group.isUngrouped ? "" : group.name
        showRenameAlert = true
    }

    private func exitSelection() {
        isSelecting = false
        selection = []
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            Text("No photos yet")
                .font(.title3.bold())
            Text("This reads files saved to **On My iPhone → Flashback Remote**. Transfer with **Save Location = Files App**, then they appear here to preview, group and prune.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button { vm.load() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
        }
    }
}

// MARK: - Grid thumbnail

struct LibraryThumbnail: View {
    let item: LibraryItem
    let showBadge: Bool
    let isSelecting: Bool
    let isSelected: Bool
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ProgressView()
                }
            }
            .overlay(alignment: .topTrailing) {
                if showBadge && item.dngURL != nil {
                    Text("RAW")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                        .background(Circle().fill(.black.opacity(0.25)))
                        .padding(5)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                if isSelecting && isSelected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .task(id: item.id) { await loadThumb() }
    }

    private func loadThumb() async {
        if let cached = ThumbnailCache.shared.image(for: item.id) {
            image = cached
            return
        }
        guard let url = item.thumbnailSourceURL else { return }
        let img = await Task.detached(priority: .userInitiated) {
            ImageDecoder.thumbnail(url: url, maxPixel: 400)
        }.value
        if let img {
            ThumbnailCache.shared.set(img, for: item.id)
            image = img
        }
    }
}

// MARK: - Paged full-screen viewer (Photos-style)

struct PhotoViewer: View {
    @ObservedObject var vm: LibraryViewModel
    let groupID: String
    let startID: String

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showDeleteConfirm = false
    @State private var sharePayload: SharePayload?

    // Scoped to the photo's own group, so the strip is one roll/folder only.
    private var items: [LibraryItem] { vm.items(inGroupID: groupID) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if items.isEmpty {
                Color.clear.onAppear { dismiss() }
            } else {
                TabView(selection: $index) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        PageImageView(item: item).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if let c = current {
                        Text(c.displayName)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 8)
                    }
                    filmstrip
                }
            }
        }
        .onAppear { index = items.firstIndex { $0.id == startID } ?? 0 }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Removes the DNG and any matching JPEG from this iPhone.")
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(items: payload.urls)
        }
    }

    private var current: LibraryItem? { items.indices.contains(index) ? items[index] : nil }

    private var topBar: some View {
        HStack {
            Button("Done") { dismiss() }
            Spacer()
            Button {
                if let c = current {
                    sharePayload = SharePayload(urls: [c.dngURL, c.jpegURL].compactMap { $0 })
                }
            } label: { Image(systemName: "square.and.arrow.up") }
            Button(role: .destructive) { showDeleteConfirm = true } label: { Image(systemName: "trash") }
                .padding(.leading, 16)
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var filmstrip: some View {
        FilmstripScrubber(items: items, index: $index)
            .frame(height: 64)
            .background(.ultraThinMaterial)
    }

    private func deleteCurrent() {
        guard let item = current else { return }
        let wasLast = index >= items.count - 1
        vm.delete(item)
        if items.isEmpty { dismiss(); return }
        if wasLast { index = items.count - 1 }
    }
}

struct PageImageView: View {
    let item: LibraryItem
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImage(image: image)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.id) {
            if image == nil, let thumb = ThumbnailCache.shared.image(for: item.id) {
                image = thumb   // instant placeholder
            }
            guard let url = item.primaryURL else { return }
            let full = await Task.detached(priority: .userInitiated) {
                ImageDecoder.fullImage(url: url)
            }.value
            if let full { image = full }
        }
    }
}

// Continuous, smoothly-scrubbing filmstrip (UIScrollView-backed). The centred
// frame is the current photo; neighbours shrink/fade (cover-flow). Scrubbing the
// strip updates the photo live; swiping the photo scrolls the strip back.
struct FilmstripScrubber: UIViewRepresentable {
    let items: [LibraryItem]
    @Binding var index: Int

    let itemWidth: CGFloat = 42
    let itemHeight: CGFloat = 50
    let spacing: CGFloat = 3
    var pitch: CGFloat { itemWidth + spacing }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.showsHorizontalScrollIndicator = false
        sv.decelerationRate = .fast
        sv.backgroundColor = .clear
        sv.delegate = context.coordinator

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = spacing
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        sv.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sv.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: sv.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: sv.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: sv.contentLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalTo: sv.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.scrollView = sv
        context.coordinator.stack = stack
        context.coordinator.rebuild(items)
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.count != items.count { context.coordinator.rebuild(items) }
        let inset = max(0, (sv.bounds.width - itemWidth) / 2)
        if abs(sv.contentInset.left - inset) > 0.5 {
            sv.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        }
        context.coordinator.scrollTo(index, animated: context.coordinator.didInitialLayout)
        context.coordinator.didInitialLayout = true
        context.coordinator.updateTransforms()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: FilmstripScrubber
        weak var scrollView: UIScrollView?
        weak var stack: UIStackView?
        var imageViews: [UIImageView] = []
        var count = 0
        var isUserScrolling = false
        var didInitialLayout = false

        init(_ p: FilmstripScrubber) { parent = p }

        func rebuild(_ items: [LibraryItem]) {
            guard let stack else { return }
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            imageViews = []
            for item in items {
                let iv = UIImageView()
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.backgroundColor = .secondarySystemBackground
                iv.layer.cornerRadius = 5
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.widthAnchor.constraint(equalToConstant: parent.itemWidth).isActive = true
                iv.heightAnchor.constraint(equalToConstant: parent.itemHeight).isActive = true
                stack.addArrangedSubview(iv)
                imageViews.append(iv)
                load(item, into: iv)
            }
            count = items.count
        }

        private func load(_ item: LibraryItem, into iv: UIImageView) {
            if let cached = ThumbnailCache.shared.image(for: item.id) { iv.image = cached; return }
            guard let url = item.thumbnailSourceURL else { return }
            Task.detached(priority: .utility) {
                guard let img = ImageDecoder.thumbnail(url: url, maxPixel: 200) else { return }
                ThumbnailCache.shared.set(img, for: item.id)
                await MainActor.run { iv.image = img }
            }
        }

        func scrollTo(_ index: Int, animated: Bool) {
            guard let sv = scrollView, !isUserScrolling, count > 0 else { return }
            let i = max(0, min(count - 1, index))
            let targetX = CGFloat(i) * parent.pitch + parent.itemWidth / 2 - sv.bounds.width / 2
            sv.setContentOffset(CGPoint(x: targetX, y: 0), animated: animated)
        }

        func updateTransforms() {
            guard let sv = scrollView else { return }
            let viewportCenter = sv.contentOffset.x + sv.bounds.width / 2
            for (i, iv) in imageViews.enumerated() {
                let itemCenter = CGFloat(i) * parent.pitch + parent.itemWidth / 2
                let d = abs(itemCenter - viewportCenter)
                let t = max(0, 1 - d / (parent.pitch * 2.5))
                let scale = 0.7 + 0.3 * t
                iv.transform = CGAffineTransform(scaleX: scale, y: scale)
                iv.alpha = 0.45 + 0.55 * t
            }
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { isUserScrolling = true }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateTransforms()
            guard isUserScrolling, count > 0 else { return }
            let viewportCenter = scrollView.contentOffset.x + scrollView.bounds.width / 2
            let i = Int(((viewportCenter - parent.itemWidth / 2) / parent.pitch).rounded())
            let clamped = max(0, min(count - 1, i))
            if clamped != parent.index { parent.index = clamped }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { isUserScrolling = false; scrollTo(parent.index, animated: true) }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            isUserScrolling = false
            scrollTo(parent.index, animated: true)
        }
    }
}

// MARK: - Pinch/pan zoom

struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in scale = min(max(1, lastScale * value), 6) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1 { withAnimation(.easeOut(duration: 0.2)) { offset = .zero; lastOffset = .zero } }
                    }
            )
            // Attach the pan gesture ONLY when zoomed in. At 1× there's no drag
            // gesture at all, so the parent paging TabView gets clean horizontal
            // swipes (no more getting stuck midway between photos).
            .applyIf(scale > 1) { view in
                view.gesture(
                    DragGesture()
                        .onChanged { value in
                            offset = CGSize(width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height)
                        }
                        .onEnded { _ in lastOffset = offset }
                )
            }
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.25)) {
                    if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                    else { scale = 2.5; lastScale = 2.5 }
                }
            }
    }
}

// MARK: - Share sheet

struct SharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension View {
    /// Conditionally apply a modifier. Used to attach the pan gesture only when
    /// the image is zoomed in.
    @ViewBuilder
    func applyIf<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}
