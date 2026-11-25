import Foundation
import AppKit
import Observation

/// UI state for a sort run. File copying and naming live in `SorterService`.
@MainActor
@Observable
final class SorterEngine {
    var destinationURL: URL = URL(fileURLWithPath: "/Volumes/Data/SD Photo Sort")
    var verifyDuplicatesWithHash: Bool = true
    var isProcessing: Bool = false
    var totalFiles: Int = 0
    var processedFiles: Int = 0
    var currentFileName: String = ""
    var statusLog: [String] = []
    var errorLog: [String] = []
    var copiedCount = 0
    var skippedCount = 0
    var collisionCount = 0
    var failedCount = 0
    var ignoredCounts: [String: Int] = [:]
    @ObservationIgnored private var completionSound: NSSound?

    var progressFraction: Double {
        guard totalFiles > 0 else { return 0.0 }
        return Double(processedFiles) / Double(totalFiles)
    }

    func processDroppedURLs(_ urls: [URL]) {
        guard !urls.isEmpty, !isProcessing else { return }

        isProcessing = true
        errorLog = []
        copiedCount = 0
        skippedCount = 0
        collisionCount = 0
        failedCount = 0
        ignoredCounts = [:]
        log("Processing...")

        let targetDest = destinationURL
        let useHash = verifyDuplicatesWithHash

        Task {
            let scopedURLs = (urls + [targetDest]).filter { $0.startAccessingSecurityScopedResource() }
            defer {
                for url in scopedURLs {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let (files, gatherErrors, ignored) = await Task.detached {
                SorterService.gatherFiles(from: urls)
            }.value

            totalFiles = files.count
            processedFiles = 0
            currentFileName = ""
            errorLog.append(contentsOf: gatherErrors)
            ignoredCounts = ignored

            for file in files {
                currentFileName = file.lastPathComponent
                let outcome = await Task.detached {
                    await SorterService.sortSingleFile(
                        file,
                        destination: targetDest,
                        useHashVerification: useHash
                    )
                }.value
                record(outcome)
            }

            finish(fileCount: files.count)
        }
    }

    private func record(_ outcome: SorterService.Outcome) {
        processedFiles += 1
        statusLog.append(outcome.message)
        switch outcome {
        case .copied:
            copiedCount += 1
        case .skipped:
            skippedCount += 1
        case .nameCollision:
            collisionCount += 1
            errorLog.append(outcome.message)
        case .failed:
            failedCount += 1
            errorLog.append(outcome.message)
        }
    }

    private func finish(fileCount: Int) {
        isProcessing = false
        currentFileName = ""

        let errorCount = errorLog.count
        log("---- Summary ----")
        log("Supported files found: \(fileCount)")
        log("Copied: \(copiedCount + collisionCount)  (of which renamed for name collision: \(collisionCount))")
        log("Skipped (exact SHA-256 duplicates): \(skippedCount)")
        log("Failed: \(failedCount)")
        let ignoredTotal = ignoredCounts.values.reduce(0, +)
        if ignoredTotal > 0 {
            let detail = ignoredCounts.sorted { $0.key < $1.key }
                .map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
            log("Ignored (unsupported types): \(ignoredTotal)  [\(detail)]")
        }
        if errorCount > 0 {
            log("See error panel for \(errorCount) item(s) needing attention.")
        }

        let soundName = errorCount == 0 ? "Hero" : "Basso"
        let soundPath = "/System/Library/Sounds/\(soundName).aiff"
        if let sound = NSSound(contentsOfFile: soundPath, byReference: true) {
            completionSound = sound
            sound.play()
        } else {
            print("Could not load sound at \(soundPath)")
            NSSound.beep()
        }
    }

    private func log(_ message: String) {
        statusLog.append("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
    }
}
