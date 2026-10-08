import Foundation
import Testing
@testable import OpenTrafficCore

@Test func selectsSmallestRetinaVariantThatCoversDisplaySize() {
    let points = CGSize(width: 128, height: 80)
    #expect(SitePreviewVariant.bestFit(pointSize: points, displayScale: 1) == .small)
    #expect(SitePreviewVariant.bestFit(pointSize: points, displayScale: 2) == .medium)
    #expect(SitePreviewVariant.bestFit(pointSize: CGSize(width: 300, height: 180), displayScale: 2) == .large)
    #expect(SitePreviewVariant.bestFit(pointSize: CGSize(width: 500, height: 300), displayScale: 2) == .master)
}

@Test func aspectFillCropPreservesProportionsWithoutStretching() {
    let wide = SitePreviewSizing.aspectFillSourceRect(
        imageSize: CGSize(width: 2_000, height: 900),
        destinationSize: CGSize(width: 320, height: 200)
    )
    #expect(wide.height == 900)
    #expect(abs(wide.width / wide.height - 1.6) < 0.0001)
    #expect(wide.midX == 1_000)

    let tall = SitePreviewSizing.aspectFillSourceRect(
        imageSize: CGSize(width: 900, height: 2_000),
        destinationSize: CGSize(width: 320, height: 200)
    )
    #expect(tall.width == 900)
    #expect(abs(tall.width / tall.height - 1.6) < 0.0001)
    #expect(tall.midY == 1_000)
}

@Test func cacheIsBoundedAndIdentityScoped() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = SitePreviewCache(directory: directory, maximumBytes: 12)
    try await cache.store(Data(repeating: 1, count: 8), identity: "one", variant: .small)
    try await Task.sleep(for: .milliseconds(5))
    try await cache.store(Data(repeating: 2, count: 8), identity: "two", variant: .small)
    #expect(await cache.totalBytes() <= 12)
    #expect(await cache.data(identity: "two", variant: .small) == Data(repeating: 2, count: 8))
    await cache.remove(identity: "two")
    #expect(await cache.data(identity: "two", variant: .small) == nil)
}
