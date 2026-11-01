//
//  ListingPhotosSection.swift
//  freebnb
//
//  The listing form's photo picker: add from the library, reorder, choose the cover, remove.
//

import PhotosUI
import SwiftUI

struct ListingPhotosSection: View {
    let vm: CreateListingViewModel
    /// False for a co-host, who can see but not change the photos (see `canEditPhotos`).
    let canEdit: Bool

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isPreparing = false
    @State private var importProblem: String?

    var body: some View {
        Section {
            ForEach(Array(vm.photos.enumerated()), id: \.element.id) { index, item in
                row(item, index: index)
            }
            .onMove(perform: moveAction)
            .onDelete(perform: deleteAction)

            if canEdit {
                addButton
            }
            if let importProblem {
                InlineErrorLabel(message: importProblem, tint: .orange)
            }
        } header: {
            Text("Photos")
        } footer: {
            Text(footerText)
        }
    }

    // Nil turns the gesture off, which is how a co-host's form stays read-only.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        canEdit ? vm.movePhotos(from:to:) : nil
    }

    private var deleteAction: ((IndexSet) -> Void)? {
        canEdit ? vm.removePhotos(at:) : nil
    }

    private var footerText: String {
        guard canEdit else { return "Only the host can change this listing's photos." }
        if vm.isUploadingPhotos { return "Uploading photos…" }
        return "The first photo is the cover. Drag to reorder, or touch and hold a photo to make it the cover. "
            + "Location data is removed from every photo before it's uploaded."
    }

    private var addButton: some View {
        PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: max(1, vm.remainingPhotoSlots),
            selectionBehavior: .ordered,
            matching: .images
        ) {
            HStack {
                Label(vm.photos.isEmpty ? "Add photos" : "Add more photos", systemImage: "photo.badge.plus")
                Spacer()
                if isPreparing {
                    ProgressView()
                } else if vm.remainingPhotoSlots == 0 {
                    Text("\(CreateListingViewModel.maxPhotos) max")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                }
            }
        }
        .disabled(vm.remainingPhotoSlots == 0 || isPreparing)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
    }

    private func row(_ item: ListingPhotoItem, index: Int) -> some View {
        HStack(spacing: 12) {
            thumbnail(item)
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(index == 0 ? "Cover photo" : "Photo \(index + 1)")
                .font(index == 0 ? Font.subheadline.weight(.semibold) : Font.subheadline)
            Spacer()
        }
        .contextMenu {
            if canEdit {
                if index > 0 {
                    Button("Make cover photo", systemImage: "star") { vm.makeCover(id: item.id) }
                }
                Button("Remove", systemImage: "trash", role: .destructive) { vm.removePhoto(id: item.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(index == 0 ? "Cover photo" : "Photo \(index + 1) of \(vm.photos.count)")
        .accessibilityActions {
            if canEdit && index > 0 {
                Button("Make cover photo") { vm.makeCover(id: item.id) }
                Button("Move up") { vm.movePhotos(from: IndexSet(integer: index), to: index - 1) }
            }
            if canEdit && index < vm.photos.count - 1 {
                Button("Move down") { vm.movePhotos(from: IndexSet(integer: index), to: index + 2) }
            }
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: ListingPhotoItem) -> some View {
        switch item.source {
        case .pending:
            if let preview = item.preview {
                Image(uiImage: preview).resizable().scaledToFill()
            } else {
                placeholder
            }
        case .stored(let urlString):
            // Stored photos only exist when editing, so the target listing is the one they belong to.
            CachedAsyncImage(listingPhoto: urlString, homeID: vm.mode.target?.id ?? "", maxPointSize: 120) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    placeholder
                }
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.tertiaryBackground)
            .overlay(Image(systemName: "photo").foregroundColor(.secondaryText))
    }

    /// Loads each pick, then downsizes and strips metadata off the main actor before it joins the form.
    private func importPhotos(_ items: [PhotosPickerItem]) async {
        pickerItems = []
        isPreparing = true
        defer { isPreparing = false }
        importProblem = nil

        var failed = 0
        for item in items.prefix(vm.remainingPhotoSlots) {
            do {
                guard let raw = try await item.loadTransferable(type: Data.self) else {
                    failed += 1
                    continue
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ListingPhotoProcessor.prepareForUpload(raw)
                }.value
                vm.addPhoto(prepared)
            } catch {
                failed += 1
            }
        }
        if failed > 0 {
            importProblem = failed == 1
                ? "One photo couldn't be added. Try picking it again."
                : "\(failed) photos couldn't be added. Try picking them again."
        }
    }
}
