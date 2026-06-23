import SwiftUI
import UIKit

struct LibraryTab: View {
    @StateObject private var vm = LibraryViewModel()
    @Binding var hideTabBar: Bool

    @State private var viewerItem: LibraryItem?
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
            .fullScreenCover(item: $viewerItem) { item in
                PhotoViewer(vm: vm, startID: item.id)
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
                            if isSelecting { toggle(item) } else { viewerItem = item }
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
            .padding(.bottom, 80)   // clear the floating tab/selection bar
        }
        .refreshable { vm.load() }
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
                    else { selection = Set(vm.items.map(\.id)) }
                }
            }
        }
    }

    private var selectionActionBar: some View {
        HStack {
            Button {
                shareURLs = vm.fileURLs(for: selection)
                showShare = true
            } label: {
                Image(systemName: "square.and.arrow.up").font(.title3)
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
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 2)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var allSelected: Bool { !vm.items.isEmpty && selection.count == vm.items.count }

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
    let startID: String

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showDeleteConfirm = false
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if vm.items.isEmpty {
                Color.clear.onAppear { dismiss() }
            } else {
                TabView(selection: $index) {
                    ForEach(Array(vm.items.enumerated()), id: \.element.id) { i, item in
                        PageImageView(item: item).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    filmstrip
                }
            }
        }
        .onAppear { index = vm.items.firstIndex { $0.id == startID } ?? 0 }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Removes the DNG and any matching JPEG from this iPhone.")
        }
        .sheet(isPresented: $showShare) {
            if vm.items.indices.contains(index) {
                ShareSheet(items: [vm.items[index].dngURL, vm.items[index].jpegURL].compactMap { $0 })
            }
        }
    }

    private var current: LibraryItem? { vm.items.indices.contains(index) ? vm.items[index] : nil }

    private var topBar: some View {
        HStack {
            Button("Done") { dismiss() }
            Spacer()
            Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(vm.items.enumerated()), id: \.element.id) { i, item in
                        FilmstripThumb(item: item, isCurrent: i == index)
                            .id(i)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.2)) { index = i }
                            }
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: 64)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .onChange(of: index) { i in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(i, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(index, anchor: .center) }
        }
    }

    private func deleteCurrent() {
        guard let item = current else { return }
        let wasLast = index >= vm.items.count - 1
        vm.delete(item)
        if vm.items.isEmpty { dismiss(); return }
        if wasLast { index = vm.items.count - 1 }
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

struct FilmstripThumb: View {
    let item: LibraryItem
    let isCurrent: Bool
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(.secondarySystemBackground))
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white, lineWidth: isCurrent ? 2 : 0)
            }
            .opacity(isCurrent ? 1 : 0.6)
            .task(id: item.id) {
                if let cached = ThumbnailCache.shared.image(for: item.id) { image = cached; return }
                guard let url = item.thumbnailSourceURL else { return }
                let img = await Task.detached(priority: .utility) {
                    ImageDecoder.thumbnail(url: url, maxPixel: 200)
                }.value
                if let img { ThumbnailCache.shared.set(img, for: item.id); image = img }
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
