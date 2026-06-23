import SwiftUI
import UIKit

struct LibraryTab: View {
    @StateObject private var vm = LibraryViewModel()
    @State private var selected: LibraryItem?

    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var shareURLs: [URL] = []
    @State private var showShare = false

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                if vm.items.isEmpty {
                    emptyView
                } else {
                    grid
                }
            }
            .navigationTitle(isSelecting ? "\(selection.count) selected" : "Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .onAppear { vm.load() }
            .fullScreenCover(item: $selected) { item in
                LibraryDetailView(item: item) {
                    vm.delete(item)
                    selected = nil
                }
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
            .sheet(isPresented: $showShare) {
                ShareSheet(items: shareURLs)
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(vm.items) { item in
                    LibraryThumbnail(item: item,
                                     showBadge: vm.showsRawBadges,
                                     isSelecting: isSelecting,
                                     isSelected: selection.contains(item.id))
                        .onTapGesture {
                            if isSelecting { toggle(item) } else { selected = item }
                        }
                        .onLongPressGesture {
                            if !isSelecting {
                                isSelecting = true
                                selection = [item.id]
                            }
                        }
                }
            }
            .padding(4)
            .padding(.bottom, 70)   // clear the floating tab bar
        }
        .refreshable { vm.load() }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Done") { exitSelection() }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Button("Select All") { selection = Set(vm.items.map(\.id)) }
                    Button("Deselect All") { selection = [] }
                } label: {
                    Image(systemName: "checklist")
                }
                Button {
                    shareURLs = vm.fileURLs(for: selection)
                    showShare = true
                } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(selection.isEmpty)
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: { Image(systemName: "trash") }
                    .disabled(selection.isEmpty)
            }
        } else if !vm.items.isEmpty {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Select") { isSelecting = true }
            }
        }
    }

    private func toggle(_ item: LibraryItem) {
        if selection.contains(item.id) { selection.remove(item.id) }
        else { selection.insert(item.id) }
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
            Text("This reads files saved to **On My iPhone → Flashback Remote**. Transfer with **Save Location = Files App**, then they appear here to preview and prune.")
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

// MARK: - Thumbnail cell

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

// MARK: - Full-screen detail

struct LibraryDetailView: View {
    let item: LibraryItem
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true
    @State private var showDeleteConfirm = false
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableImage(image: image)
                } else if loading {
                    ProgressView().tint(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("Couldn't decode this file").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(item.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text(item.sizeMB + (item.isRawOnly ? " · RAW only" : ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .confirmationDialog("Delete this photo?",
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(item.dngURL != nil && item.jpegURL != nil
                     ? "Removes both the DNG and its JPEG from this iPhone."
                     : "Removes this file from this iPhone.")
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: [item.dngURL, item.jpegURL].compactMap { $0 })
            }
            .task { await loadFull() }
        }
    }

    private func loadFull() async {
        guard let url = item.primaryURL else { loading = false; return }
        let img = await Task.detached(priority: .userInitiated) {
            ImageDecoder.fullImage(url: url)
        }.value
        image = img
        loading = false
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
                    .onChanged { value in scale = max(1, lastScale * value) }
                    .onEnded { _ in lastScale = scale; if scale <= 1 { withAnimation { offset = .zero; lastOffset = .zero } } }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation {
                    if scale > 1 { scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero }
                    else { scale = 2.5; lastScale = 2.5 }
                }
            }
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
