//
//  HomeViewModel.swift
//  Shot Bot
//
//  Created by Richard Witherspoon on 4/20/23.
//

import SwiftUI
import PhotosUI
import Models
import Persistence
import Purchases
import MediaManager
import StoreKit
import OSLog

@MainActor public final class HomeViewModel: ObservableObject {
    let alertTitle = "Something went wrong."
    let alertMessage = "Please make sure you are selecting a screenshot."
    private var persistenceManager: any PersistenceManaging
    private let photoLibraryManager: PhotoLibraryManager
    private let purchaseManager: any PurchaseManaging
    private let fileManager: any FileManaging
    private var combinedImageTask: Task<Void, Never>?
    private var imageQuality: ImageQuality
    private(set) var imageResults = ImageResults()
    private let logger = Logger(category: HomeViewModel.self)
    @Published public var showPurchaseView = false
    @Published public var showAutoSaveToast = false
    @Published public var showCopyToast = false
    @Published public var showQuickSaveToast = false
    @Published public var showPhotosPicker = false
    @Published public var isLoading = false
    @Published public var imageSelections: [PhotosPickerItem] = []
    @Published public var viewState: ViewState = .individualPlaceholder
    @Published public var error: Error?
    @Published public var imageType: ImageType = .individual {
        didSet {
            imageTypeDidToggle()
        }
    }
    
    var toastText: String? {
        let files = persistenceManager.autoSaveToFiles
        let photos = persistenceManager.autoSaveToPhotos
        
        if files && photos {
            return "Saved to photos & files"
        } else if files {
            return "Saved to files"
        } else if photos {
            return "Saved to photos"
        } else {
            return nil
        }
    }
    
    var photoFilter: PHPickerFilter {
        persistenceManager.imageSelectionType.filter
    }
    
    // MARK: - Initializer
    
    public init(
        persistenceManager: any PersistenceManaging = PersistenceManager.shared,
        photoLibraryManager: PhotoLibraryManager = .live,
        purchaseManager: any PurchaseManaging = PurchaseManager.shared,
        fileManager: any FileManaging = FileManager.default
    ) {
        self.persistenceManager = persistenceManager
        self.photoLibraryManager = photoLibraryManager
        self.purchaseManager = purchaseManager
        self.fileManager = fileManager
        self.imageQuality = persistenceManager.imageQuality
    }
    
    
    // MARK: - Private Helpers
    /// Updates `viewState` when `imageType` changes.
    ///
    /// Will wait for `combinedImageTask` if needed.
    private func imageTypeDidToggle() {
        switch imageType {
        case .individual:
            logger.notice("ImageType switched to individual.")

            if imageResults.hasImages {
                viewState = .individualImages(imageResults.individual)
                logger.notice("ViewState switched to individual images.")
            } else {
                viewState = .individualPlaceholder
                logger.notice("ViewState switched to individualPlaceholder.")
            }
        case .combined:
            logger.notice("ImageType switched to combined.")

            if let cachedImage = imageResults.combined {
                logger.notice("Using cached combined image.")
                viewState = .combinedImages(cachedImage)
            } else {
                logger.notice("ViewState switched to combined placeholder.")
                viewState = .combinedPlaceholder
                
                Task {
                    await combinedImageTask?.value
                    
                    guard let combined = imageResults.combined else {
                        logger.notice("ImageResults.combined is nil. ")
                        throw SBError.unsupportedImage
                    }
                        
                    guard viewState == .combinedPlaceholder else {
                        logger.info("ViewState has changed- no need to switch view state.")
                        return
                    }
                    
                    viewState = .combinedImages(combined)
                    logger.notice("ViewState switched to combined images.")
                }
            }
        }
    }
    
    /// Asks the user to confirm deleting the selected photos from the photo library if this
    /// setting is enabled.
    private func autoDeleteScreenshotsIfNeeded() async {
        guard persistenceManager.autoDeleteScreenshots else { return }
        let ids = imageSelections.compactMap(\.itemIdentifier)
        try? await photoLibraryManager.delete(ids)
        logger.notice("Deleting \(ids.count) images.")
    }
    
    /// Shows the `showAutoSaveToast` if the user has `autoSaveToFiles` or `autoSaveToPhotos` enabled
    ///
    /// Using a slight delay in order to make the UI less jarring
    private func autoSaveIfNeeded() async {
        guard persistenceManager.autoSaveToFiles || persistenceManager.autoSaveToPhotos else { return }
        
        for result in imageResults.individual {
            do {
                if persistenceManager.autoSaveToFiles {
                    try fileManager.copyToiCloudFiles(from: result.url)
                    logger.info("Saving to iCloud.")
                }
                
                if persistenceManager.autoSaveToPhotos {
                    try await photoLibraryManager.savePhoto(result.url)
                    logger.info("Saving to Photo library.")
                }
                
                try await Task.sleep(for: .seconds(0.75))
                showAutoSaveToast = true
                
                if toastText == nil {
                    logger.fault("Toast text returned nil.")
                }
                
                try await Task.sleep(for: .seconds(0.75))
            } catch {
                logger.info("An autosave error occurred: \(error.localizedDescription).")
                self.error = error
            }
        }
    }
    
    /// Cancels and nils out `combinedImageTask`
    private func stopCombinedImageTask() {
        logger.debug("Stopping combined image task.")
        combinedImageTask?.cancel()
        combinedImageTask = nil
    }
    
    /// Combines images Horizontally with scaling to keep consistent spacing
    ///
    /// nonisolated in order to run on a background thread and not disrupt the main thread
    nonisolated private func createCombinedImage(from images: [UIImage]) async throws {
        logger.info("Starting combined image task.")
        
        try await Task {
            defer {
                logger.info("Ending combined image task.")
            }
            
            let imagesWidth = images.map(\.size.width).reduce(0, +)
            
            let resizedImages = images.map { image in
                let scale = (image.size.width / imagesWidth)
                let size = CGSize(
                    width: image.size.width * scale,
                    height: image.size.height * scale
                )
                return image.resized(to: size)
            }
            
            let combined = resizedImages.combineHorizontally()
            
            guard let data = combined.pngData() else {
                logger.error("No combined image png data")
                throw SBError.noData
            }
            
            let temporaryURL = URL.temporaryDirectory.appending(path: "combined.png")
            
            try data.write(to: temporaryURL)
            logger.info("Saving combined data to temporary url.")
            
            await MainActor.run {
                imageResults.combined = ShareableImage(framedScreenshot: combined, url: temporaryURL)
            }
        }.value
    }
    
    /// If their are multiple image results, it will start the process of combining them horizontally
    private func combineDeviceFrames() {
        guard imageResults.hasMultipleImages else { return }
        
        stopCombinedImageTask()
        
        combinedImageTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            try? await createCombinedImage(
                from: imageResults.individual.map(\.framedScreenshot)
            )
        }
    }
    
    /// Loads an array of `Screenshot`from different source types depending on the input `PhotoSource`
    private func getScreenshots(from source: PhotoSource) async throws -> [UIScreenshot] {
        let screenshots: [UIScreenshot]
        
        switch source {
        case .photoPicker:
            logger.info("Fetching images from the photos picker.")
            screenshots = try await imageSelections.loadUImages()
        case .dropItems(let items):
            logger.info("Using dropped photos (\(items.count)).")
            screenshots = items.compactMap { UIImage(data: $0) }
        case .existingScreenshots(let existing):
            logger.info("Using existing screenshots (\(existing.count)).")
            screenshots = existing
        }
        
        return screenshots
    }
    
    /// Updates `imageResults` `individual`property and counts up `PersistenceManaging.deviceFrameCreations`
    private func updateImageResultsIndividualImages(using screenshots: [UIImage]) async throws {
        var shareableImages = [ShareableImage]()
        
        for (i, screenshot) in screenshots.enumerated() {
            let shareableImage = try await createDeviceFrame(using: screenshot, count: i)
            
            shareableImages.append(shareableImage)
            persistenceManager.deviceFrameCreations += 1
        }
        
        logger.debug("Setting imageResults.individual with \(shareableImages.count) items.")
        imageResults.individual = shareableImages
    }
    
    /// Starts the image pipeline using the passed in screenshots
    private func processSelectedPhotos(
        resetView: Bool,
        source: PhotoSource
    ) async throws {
        // Loading
        logger.info("Starting processing selected photos")
        isLoading = true
        defer {
            logger.info("Ending processing selected photos.")
            isLoading = false
        }
       
        // Prep
        stopCombinedImageTask()
        
        let screenshots = try await getScreenshots(from: source)
        
        guard !screenshots.isEmpty else { return }
        
        // Update view
        if resetView {
            logger.info("Resetting view state, imageType, and removing image results.")
            viewState = .individualPlaceholder
            imageType = .individual
            imageResults.removeAll()
        }
        
        // ImageResults updating
        imageResults.originalScreenshots = screenshots
        try await updateImageResultsIndividualImages(using: screenshots)
        
        // Reset view
        if resetView || imageType == .individual {
            logger.info("Setting viewState to individualImages and ending isLoading.")
            viewState = .individualImages(imageResults.individual)
            isLoading = false
        }
        
        guard imageResults.hasImages else {
            logger.fault("Processing selected photos returning early because imageResults has no image.")
            return
        }
        
        combineDeviceFrames()
        
        if imageType == .combined {
            logger.debug("Processing selected photos waiting for combined image task value.")
            await combinedImageTask?.value
            
            guard let combined = imageResults.combined else {
                logger.fault("Processing selected photos returning early because combined image results has no image.")
                throw SBError.unsupportedImage
            }
            
            logger.fault("Setting viewState to combinedImages")
            viewState = .combinedImages(combined)
        }
        
        // Post FramedScreenshot generation
        await autoSaveIfNeeded()
        await autoDeleteScreenshotsIfNeeded()
        askForAReview()
    }
    
    /// Asks the user for a review
    private func askForAReview() {
        let deviceFrameCreations = persistenceManager.deviceFrameCreations
        let numberOfActivations = persistenceManager.numberOfActivations

        guard deviceFrameCreations > 3 && numberOfActivations > 3 else {
            logger.debug("Review prompt criteria not met. DeviceFrameCreations: \(deviceFrameCreations), numberOfActivations: \(numberOfActivations).")
            return
        }
            
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            logger.fault("Could not find UIWindowScene to ask for review")
            return
        }
        
        if let date = persistenceManager.lastReviewPromptDate {
            guard date >= Date.now.adding(days: 3) else {
                logger.debug("Last review prompt date to recent: \(date).")
                return
            }
        }
            
        SKStoreReviewController.requestReview(in: scene)
        
        persistenceManager.lastReviewPromptDate = .now
        logger.log("Prompting the user for a review")
    }
    
    // MARK: - Public
    
    /// Starts the image pipeline with `dropItems` as the photo source
    public func didDropItem(_ items: [Data]) async {
        do {
            try await processSelectedPhotos(resetView: false, source: .dropItems(items))
        } catch {
            self.error = error
        }
    }
    
    /// Shows the user the photo picker and then uses their selection to kick off the image pipeline
    /// using `photoPicker` as the image source
    public func imageSelectionsDidChange() async {
        do {
            try await processSelectedPhotos(resetView: true, source: .photoPicker)
        } catch {
            self.error = error
        }
    }
    
    /// If not loading, show the photo picker.
    public func selectPhotos() {
        guard persistenceManager.canSaveFramedScreenshot else {
            showPurchaseView = true
            return
        }
        
        guard !isLoading else {
            logger.fault("Trying to select photos while in a loading state.")
            return
        }
        
        showPhotosPicker = true
    }
    
    /// Creates a `ShareableImage` from a `UIScreenshot`
    ///
    /// Will auto save to files or photos if necessary
    public func createDeviceFrame(using screenshot: UIScreenshot, count: Int) async throws -> ShareableImage {
        let framedScreenshot = try screenshot.framedScreenshot(quality: persistenceManager.imageQuality)
        let path = "Framed Screenshot \(count)_\(UUID()).png"
        let temporaryURL = URL.temporaryDirectory.appending(path: path)
        
        guard let data = framedScreenshot.pngData() else {
            logger.error("Could not get png data for framedScreenshot.")
            throw SBError.noData
        }
        
        try data.write(to: temporaryURL)
        logger.info("Writing \(path) to temporary url.")
        
        return ShareableImage(
            framedScreenshot: framedScreenshot,
            url: temporaryURL
        )
    }
    
    /// Clears all images when the user backgrounds the app, if the setting is enabled.
    public func clearImagesOnAppBackground() {
        guard persistenceManager.clearImagesOnAppBackground else { return }
        
        stopCombinedImageTask()
        viewState = .individualPlaceholder
        imageType = .individual
        imageResults.removeAll()
        imageSelections.removeAll()
        logger.info("Clearing images on app background")
    }
    
    /// Checks if the users has changed image quality. If so, the original screenshots are rerun
    /// though the pipeline to create new framed screenshots based on the new image quality.
    public func changeImageQualityIfNeeded() async {
        guard imageQuality != persistenceManager.imageQuality else { return }
        
        logger.info("Re-running pipeline due to image quality change.")
        
        imageQuality = persistenceManager.imageQuality
        
        await combinedImageTask?.value
        
        try? await processSelectedPhotos(
            resetView: false,
            source: .existingScreenshots(imageResults.originalScreenshots)
        )
    }
    
    /// Copies a framed screenshot to the clipboard
    public func copy(_ image: UIFramedScreenshot) {
        guard persistenceManager.canSaveFramedScreenshot else {
            showPurchaseView = true
            return
        }
        
        UIPasteboard.general.image = image
        showCopyToast = true
        logger.debug("Copying image.")
    }
    
    /// Saves a framed screenshot to the users photo library
    public func save(_ image: UIFramedScreenshot) async {
        guard persistenceManager.canSaveFramedScreenshot else {
            showPurchaseView = true
            return
        }
        
        do {
            try await photoLibraryManager.save(image)
            showQuickSaveToast = true
            logger.debug("Manually saving image.")
        } catch {
            logger.error("Error manually saving image: \(error.localizedDescription).")
            self.error = error
        }
    }
    
    /// Requests photo library addition authorization
    public func requestPhotoLibraryAdditionAuthorization() async {
        await photoLibraryManager.requestPhotoLibraryAdditionAuthorization()
        
        let status = photoLibraryManager.photoAdditionStatus.title
        logger.info("Finished requesting photo library addition authorization. Status: \(status).")
    }
}
