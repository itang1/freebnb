//
//  ListingPhotoTests.swift
//  freebnbTests
//
//  Listing photos: metadata stripping and downscaling before upload, Storage paths, the form's photo list,
//  and HomeStore's ordered, all-or-nothing upload.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import freebnb

/// A JPEG of the given size carrying GPS and camera metadata, like a photo straight off a phone.
private func makeGeotaggedJPEG(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())

    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
    ))
    let properties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 34.1613,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 118.1676,
            kCGImagePropertyGPSLongitudeRef: "W"
        ],
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Apple",
            kCGImagePropertyTIFFModel: "iPhone"
        ]
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return output as Data
}

private func properties(of data: Data) throws -> [CFString: Any] {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
}

struct ListingPhotoProcessorTests {
    @Test func theFixtureReallyCarriesLocation() throws {
        let original = try makeGeotaggedJPEG(width: 64, height: 48)
        #expect(try properties(of: original)[kCGImagePropertyGPSDictionary] != nil)
    }

    @Test func stripsLocationAndCameraMetadata() throws {
        let prepared = try ListingPhotoProcessor.prepareForUpload(makeGeotaggedJPEG(width: 64, height: 48))
        let props = try properties(of: prepared)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
    }

    @Test func downscalesTheLongEdgeAndKeepsTheAspectRatio() throws {
        let prepared = try ListingPhotoProcessor.prepareForUpload(
            makeGeotaggedJPEG(width: 4000, height: 3000), maxPixelSize: 2048
        )
        let props = try properties(of: prepared)
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 2048)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 1536)
    }

    @Test func neverUpscalesASmallPhoto() throws {
        let prepared = try ListingPhotoProcessor.prepareForUpload(makeGeotaggedJPEG(width: 640, height: 480))
        #expect(try properties(of: prepared)[kCGImagePropertyPixelWidth] as? Int == 640)
    }

    @Test func rejectsDataThatIsNotAnImage() {
        #expect(throws: ListingPhotoProcessor.ProcessingError.self) {
            try ListingPhotoProcessor.prepareForUpload(Data("not a photo".utf8))
        }
    }
}

struct ListingPhotoPathTests {
    @Test func newPathsAreScopedToTheListingAndNeverRepeat() {
        let first = ListingPhotoPath.newObjectPath(hostUserID: "host", listingID: "home-1")
        let second = ListingPhotoPath.newObjectPath(hostUserID: "host", listingID: "home-1")
        #expect(first.hasPrefix("listings/host/home-1/"))
        #expect(first.hasSuffix(".jpg"))
        #expect(first != second)
    }

    @Test func readsTheObjectPathOutOfADownloadURL() throws {
        let url = try #require(URL(string:
            "https://firebasestorage.googleapis.com/v0/b/freebnb.appspot.com/o/listings%2Fhost%2Fhome-1%2Fabc.jpg?alt=media&token=t"
        ))
        #expect(ListingPhotoPath.objectPath(fromDownloadURL: url) == "listings/host/home-1/abc.jpg")
    }

    @Test func readsTheObjectPathOutOfAnEmulatorURL() throws {
        let url = try #require(URL(string: "http://127.0.0.1:9199/v0/b/demo/o/listings%2Fh%2Fl%2Fx.jpg?alt=media"))
        #expect(ListingPhotoPath.objectPath(fromDownloadURL: url) == "listings/h/l/x.jpg")
    }

    @Test func ignoresURLsThatAreNotStorageDownloads() throws {
        let url = try #require(URL(string: "https://example.com/cover.jpg"))
        #expect(ListingPhotoPath.objectPath(fromDownloadURL: url) == nil)
    }

    @Test func storedReferencesAreGsURLsThatRoundTrip() throws {
        let path = "listings/host/home-1/abc.jpg"
        let stored = try #require(ListingPhotoPath.storedReference(bucket: "freebnb.appspot.com", objectPath: path))
        #expect(stored.absoluteString == "gs://freebnb.appspot.com/listings/host/home-1/abc.jpg")
        #expect(ListingPhotoPath.objectPath(fromStoredReference: stored) == path)
    }

    @Test func storedReferenceParsingStillReadsOlderDownloadURLs() throws {
        let url = try #require(URL(string:
            "https://firebasestorage.googleapis.com/v0/b/b/o/listings%2Fhost%2Fhome-1%2Fabc.jpg?alt=media&token=t"
        ))
        #expect(ListingPhotoPath.objectPath(fromStoredReference: url) == "listings/host/home-1/abc.jpg")
        #expect(ListingPhotoPath.objectPath(fromStoredReference: try #require(URL(string: "gs://bucket"))) == nil)
        #expect(ListingPhotoPath.objectPath(fromStoredReference: try #require(URL(string: "https://example.com/a.jpg"))) == nil)
    }
}

/// Records uploads; fails the upload whose bytes match `failOn`.
private final class RecordingUploader: PhotoUploader, @unchecked Sendable {
    private let lock = NSLock()
    private var _deleted: [URL] = []
    let failOn: Data?

    init(failOn: Data? = nil) { self.failOn = failOn }

    var deleted: [URL] { lock.withLock { _deleted } }

    func upload(imageData: Data, listingID: String, hostUserID: String) async throws -> URL {
        if imageData == failOn {
            // Fails after the others have landed, so there's something to clean up.
            try await Task.sleep(nanoseconds: 50_000_000)
            throw URLError(.notConnectedToInternet)
        }
        // Later images finish first, so the order has to come from the store, not from completion.
        try await Task.sleep(nanoseconds: UInt64(1_000_000 * (10 - min(imageData.count, 10))))
        let name = String(decoding: imageData, as: UTF8.self)
        guard let url = URL(string: "https://example.com/\(hostUserID)/\(listingID)/\(name).jpg") else {
            throw URLError(.badURL)
        }
        return url
    }

    func delete(photoURL: URL) async throws {
        lock.withLock { _deleted.append(photoURL) }
    }
}

@MainActor
struct HomeStorePhotoTests {
    @Test func uploadsReturnURLsInTheOrderGiven() async throws {
        let store = HomeStore(repository: InMemoryHomesRepository(), photoUploader: RecordingUploader())
        let images = ["a", "bb", "ccc", "dddd"].map { Data($0.utf8) }

        let urls = try await store.uploadPhotos(images, listingID: "home-1", hostUserID: "host")

        #expect(urls.map(\.lastPathComponent) == ["a.jpg", "bb.jpg", "ccc.jpg", "dddd.jpg"])
    }

    @Test func aFailedUploadRemovesTheOnesThatLanded() async throws {
        let uploader = RecordingUploader(failOn: Data("bad".utf8))
        let store = HomeStore(repository: InMemoryHomesRepository(), photoUploader: uploader)

        await #expect(throws: URLError.self) {
            _ = try await store.uploadPhotos([Data("a".utf8), Data("bad".utf8)], listingID: "home-1", hostUserID: "host")
        }
        #expect(uploader.deleted.map(\.lastPathComponent) == ["a.jpg"])
    }
}

@MainActor
struct ListingFormPhotoTests {
    private func makeHome(photos: [String]?) -> Home {
        var home = Home(
            hostUserID: "host",
            hostName: "Host",
            address: Address(city: "Pasadena", state: "CA", zip: "91103"),
            description: nil,
            contactPreference: .inApp,
            hostContactInfo: nil,
            hostMotivation: .open,
            sleeping: Sleeping(numGuestRooms: 1, arrangements: ["bed": 1]),
            guestPolicy: GuestPolicy(maxGuests: 2, maxStayDays: 7, kidsAllowed: true, guestPetsAllowed: false),
            amenities: Amenities(
                hasAC: false, hasHeating: false, hasKitchen: false, hasFridgeSpace: false,
                hasMicrowave: false, hasTV: false, hasWifi: false,
                hasPrivateGuestBathroom: false, hostHasPets: false, parkingDetails: "",
                hasInUnitLaundry: false, hasCoinLaundryNearby: false,
                providesPillows: false, providesBlankets: false, providesTowels: false,
                providesToiletries: false, foodProvision: .none
            ),
            cancellationPolicy: .flexible
        )
        home.photoURLs = photos
        return home
    }

    @Test func anEditOpensWithTheStoredPhotosInOrder() {
        let vm = CreateListingViewModel(mode: .edit(makeHome(photos: ["https://x/1.jpg", "https://x/2.jpg"])))
        #expect(vm.photos.compactMap(\.storedURL) == ["https://x/1.jpg", "https://x/2.jpg"])
    }

    /// A duplicate's photos would live in the original's Storage folder and vanish with it.
    @Test func aDuplicateStartsWithoutPhotos() {
        let vm = CreateListingViewModel(mode: .duplicate(makeHome(photos: ["https://x/1.jpg"])))
        #expect(vm.photos.isEmpty)
    }

    @Test func makingACoverMovesItFirst() {
        let vm = CreateListingViewModel(mode: .edit(makeHome(photos: ["https://x/1.jpg", "https://x/2.jpg", "https://x/3.jpg"])))
        vm.makeCover(id: vm.photos[2].id)
        #expect(vm.photos.compactMap(\.storedURL) == ["https://x/3.jpg", "https://x/1.jpg", "https://x/2.jpg"])
    }

    @Test func addingStopsAtTheRulesCap() {
        let vm = CreateListingViewModel(mode: .create)
        for _ in 0..<(CreateListingViewModel.maxPhotos + 3) { vm.addPhoto(Data([0xFF])) }
        #expect(vm.photos.count == CreateListingViewModel.maxPhotos)
        #expect(vm.remainingPhotoSlots == 0)
    }

    @Test func onlyTheHostEditsPhotos() {
        let vm = CreateListingViewModel(mode: .edit(makeHome(photos: nil)))
        #expect(vm.canEditPhotos(userID: "host"))
        #expect(!vm.canEditPhotos(userID: "cohost"))
        #expect(CreateListingViewModel(mode: .create).canEditPhotos(userID: "anyone"))
    }

    @Test func pendingPhotosUploadUnderTheListingAndBecomeStored() async throws {
        let store = HomeStore(repository: InMemoryHomesRepository(), photoUploader: RecordingUploader())
        let vm = CreateListingViewModel(mode: .edit(makeHome(photos: ["https://x/1.jpg"])))
        vm.addPhoto(Data("new".utf8))

        let urls = try await vm.uploadPendingPhotos(homeStore: store, listingID: "home-1", hostUserID: "host")

        #expect(urls == ["https://x/1.jpg", "https://example.com/host/home-1/new.jpg"])
        #expect(vm.photos.allSatisfy { $0.storedURL != nil })
    }
}
