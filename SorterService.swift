import Foundation
import AppKit
import SwiftUI
import CryptoKit
import ImageIO
import AVFoundation

class SorterService {
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

    var progressFraction: Double {
        guard totalFiles > 0 else { return 0.0 }
        return Double(processedFiles) / Double(totalFiles)
    }

    // Rest of your code...
}
