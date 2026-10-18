import PhotosUI
import SwiftUI

struct PhotosTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var photos: [Item]?
    @State private var error: String?
    @State private var opening: Item?
    @State private var picking = false
    @State private var selection: [PhotosPickerItem] = []

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).padding()
                }
                if let photos {
                    if photos.isEmpty {
                        ContentUnavailableView {
                            Label("No photos or videos yet", systemImage: "photo.on.rectangle")
                        } description: {
                            Text("Add some with the + button, or turn on Camera backup in Settings.")
                        }
                        .padding(.top, 80)
                    }
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(months(photos), id: \.title) { month in
                            Section {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(month.items) { p in tile(p) }
                                }
                            } header: {
                                Text(month.title).font(.headline)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal).padding(.vertical, 6)
                                    .background(.bar)
                            }
                        }
                    }
                } else if error == nil {
                    ProgressView().padding(.top, 120)
                }
            }
            .navigationTitle("Photos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { picking = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add photos")
                }
            }
            .refreshable { await load() }
            .task(id: model.changes) { await load() }
            .photosPicker(isPresented: $picking, selection: $selection, matching: .any(of: [.images, .videos]),
                          preferredItemEncoding: .current)
            .onChange(of: selection) { _, picked in
                guard !picked.isEmpty else { return }
                selection = []
                Task { await Picking.uploadPhotos(picked, parent: nil, model: model) }
            }
            .opensFiles($opening)
        }
        .safeAreaInset(edge: .bottom) { TransfersBar() }
    }

    private func tile(_ p: Item) -> some View {
        Button { opening = p } label: {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { ThumbView(item: p, square: true) }
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if p.isVideo {
                        Image(systemName: "play.fill").font(.caption).foregroundStyle(.white)
                            .padding(5).shadow(radius: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(p.name)
    }

    private struct Month {
        let title: String
        let items: [Item]
    }

    private func months(_ items: [Item]) -> [Month] {
        var out: [Month] = []
        for p in items {
            let title = p.date.formatted(.dateTime.year().month(.wide))
            if out.last?.title == title {
                out[out.count - 1] = Month(title: title, items: out[out.count - 1].items + [p])
            } else {
                out.append(Month(title: title, items: [p]))
            }
        }
        return out
    }

    private func load() async {
        do {
            photos = try await model.cloud.photos()
            error = nil
        } catch is CancellationError {
        } catch {
            if (error as? ApiError)?.status == 401 { await model.signOut(); return }
            if (error as? URLError)?.code == .cancelled { return }
            self.error = error.localizedDescription
        }
    }
}
