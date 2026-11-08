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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Task {
                let scopedURLs = (urls + [targetDest]).filter { $0.startAccessingSecurityScopedResource() }
                defer {
                    for url in scopedURLs {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let (files, gatherErrors, ignored) = SorterService.gatherFiles(from: urls)

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.totalFiles = files.count
                    self.processedFiles = 0
                    self.currentFileName = ""
                    self.errorLog.append(contentsOf: gatherErrors)
                    self.ignoredCounts = ignored
                }
                
                for file in files {
                    DispatchQueue.main.async {
                        self?.currentFileName = file.lastPathComponent
                    }

                    let result = await SorterService.sortSingleFile(
                        file,
                        destination: targetDest,
                        useHashVerification: useHash
                    )

                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.processedFiles += 1
                        self.statusLog.append(result)
                        if result.hasPrefix("Copied") {
                            self.copiedCount += 1
                        } else if result.hasPrefix("Skipped") {
                            self.skippedCount += 1
                        } else if result.hasPrefix("Name Collision") {
                            self.collisionCount += 1
                        } else if SorterService.isErrorResult(result) {
                            self.failedCount += 1
                        }

                        if SorterService.isErrorResult(result) {
                            self.errorLog.append(result)
                        }
                    }
                }

                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isProcessing = false
                    self.currentFileName = ""

                    let errorCount = self.errorLog.count
                    self.log("---- Summary ----")
                    self.log("Supported files found: \(files.count)")
                    self.log("Copied: \(self.copiedCount + self.collisionCount)  (of which renamed for name collision: \(self.collisionCount))")
                    self.log("Skipped (exact SHA-256 duplicates): \(self.skippedCount)")
                    self.log("Failed: \(self.failedCount)")
                    let ignoredTotal = self.ignoredCounts.values.reduce(0, +)
                    if ignoredTotal > 0 {
                        let detail = self.ignoredCounts.sorted { $0.key < $1.key }
                            .map { "\($0.key) x\($0.value)" }.joined(separator: ", ")
                        self.log("Ignored (unsupported types): \(ignoredTotal)  [\(detail)]")
                    }
                    if errorCount > 0 {
                        self.log("See error panel for \(errorCount) item(s) needing attention.")
                    }
                    
                    let soundName = errorCount == 0 ? "Hero" : "Basso"
                    let soundPath = "/System/Library/Sounds/\(soundName).aiff"
                    if let sound = NSSound(contentsOfFile: soundPath, byReference: true) {
                        self.completionSound = sound
                        sound.play()
                    } else {
                        print("Could not load sound at \(soundPath)")
                        NSSound.beep()
                    }
                }
            }
        }
    }

    private static func gatherFiles(from urls: [URL]) -> (files: [URL], errors: [String], ignored: [String: Int]) {
        var results: [URL] = []
        var errors: [String] = []
        var ignored: [String: Int] = [:]
        let fileManager = FileManager.default
        let supportedExtensions: Set<String> = ["cr2", "cr3", "hif", "jpg", "jpeg", "heic", "heif", "mov", "mp4", "mpg", "mpeg", "avi", "nef", "rw2", "png", "arw", "tif", "tiff"]

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                errors.append("Not found or unreadable: \(url.path)")
                continue
            }

            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { inaccessibleURL, error in
                        errors.append("Skipped inaccessible item \(inaccessibleURL.path): \(error.localizedDescription)")
                        return true
                    }
                ) else {
                    errors.append("Could not read folder: \(url.path)")
                    continue
                }

                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                          values.isRegularFile == true else {
                        continue
                    }
                    let ext = fileURL.pathExtension.lowercased()
                    if supportedExtensions.contains(ext) {
                        results.append(fileURL)
                    } else {
                        ignored[ext.isEmpty ? "(none)" : ext, default: 0] += 1
                    }
                }
            } else {
                let ext = url.pathExtension.lowercased()
                if supportedExtensions.contains(ext) {
                    results.append(url)
                } else {
                    ignored[ext.isEmpty ? "(none)" : ext, default: 0] += 1
                }
            }
        }

        return (results, errors, ignored)
    }

    private static func stripCopyMarker(_ base: String) -> String {
        // Only strip " (N)" from camera-style numbering (IMG_1234, DSC03351, MVI_1057...),
        // never from descriptive names like "Spring (117)".
        let cameraStyle = "^_?[A-Za-z]{0,6}_?[0-9]{3,}(_mod|_edited)? \\([0-9]+\\)$"
        guard base.range(of: cameraStyle, options: .regularExpression) != nil else { return base }
        return base.replacingOccurrences(of: " \\([0-9]+\\)$", with: "", options: .regularExpression)
    }
    
    private static func sortSingleFile(_ fileURL: URL, destination: URL, useHashVerification: Bool) async -> String {
        guard let found = await fetchCreationDate(for: fileURL) else {
            return "Failed metadata read: \(fileURL.lastPathComponent)"
        }
        let rawDate = found.date
        
        let dateComponents = rawDate.prefix(10).components(separatedBy: ":")
        guard dateComponents.count == 3 else {
            return "Invalid date format for: \(fileURL.lastPathComponent)"
        }
        
        let year = dateComponents[0]
        let rawMonth = dateComponents[1]

        let monthNames: [String: String] = [
            "01": "01 Jan",
            "02": "02 Feb",
            "03": "03 Mar",
            "04": "04 Apr",
            "05": "05 May",
            "06": "06 Jun",
            "07": "07 Jul",
            "08": "08 Aug",
            "09": "09 Sept",
            "10": "10 Oct",
            "11": "11 Nov",
            "12": "12 Dec"
        ]

        let month = monthNames[rawMonth] ?? rawMonth
        let ext = fileURL.pathExtension.lowercased()
        let cameraModel = await fetchCameraModel(for: fileURL)
        let dateNote = found.fromFile ? " [date from file]" : ""
        let destinationFileName = renamedFileName(for: fileURL, cameraModel: cameraModel)
        
        let subFolder: String?
        if ext == "cr2" || ext == "cr3" || ext == "nef" || ext == "rw2" || ext == "arw" {
            subFolder = "_RAW"
        } else if ext == "jpg" || ext == "jpeg" || ext == "hif" || ext == "heic" || ext == "heif"  || ext == "png" || ext == "tif" || ext == "tiff" {
            subFolder = nil
        } else if ext == "mov" || ext == "mp4" || ext == "mpg" || ext == "mpeg" || ext == "avi" {
            subFolder = "_Video"
        } else {
            subFolder = "_Other"
        }

        var targetFolderURL = destination
            .appendingPathComponent(year)
            .appendingPathComponent(month)

        if let subFolder {
            targetFolderURL.appendPathComponent(subFolder)
        }

        let destinationDescription = [year, month, subFolder]
            .compactMap { $0 }
            .joined(separator: "/")
        let fm = FileManager.default

        do {
            try fm.createDirectory(at: targetFolderURL, withIntermediateDirectories: true)

            let baseName = (destinationFileName as NSString).deletingPathExtension
            let extensionName = (destinationFileName as NSString).pathExtension
            let incomingSize = getFileSize(at: fileURL)
            var incomingHash: String? = nil   // computed only if a same-size file exists

            var attempt = 0
            while attempt <= 99 {
                let candidateName = attempt == 0
                    ? destinationFileName
                    : "\(baseName)_\(attempt).\(extensionName)"
                let candidateURL = targetFolderURL.appendingPathComponent(candidateName)

                // Free name: copy here
                if !fm.fileExists(atPath: candidateURL.path) {
                    try fm.copyItem(at: fileURL, to: candidateURL)
                    applyMetadataDates(to: candidateURL, rawDate: rawDate)
                    return attempt == 0
                        ? "Copied & Synced Date -> \(destinationDescription)/\(candidateName)\(dateNote)"
                        : "Name Collision -> \(destinationDescription)/\(candidateName)"
                }

                // Name taken: skip ONLY if byte-for-byte identical
                if getFileSize(at: candidateURL) == incomingSize {
                    if incomingHash == nil {
                        incomingHash = try calculateSHA256(for: fileURL)
                    }
                    if try calculateSHA256(for: candidateURL) == incomingHash {
                        return "Skipped (SHA-256 Verified Duplicate) -> \(fileURL.lastPathComponent)"
                    }
                }
                
                // Same image data and metadata apart from the color profile?
                // Skip unless the file already in the tree is the Camera RGB one.
                if ["jpg", "jpeg"].contains(fileURL.pathExtension.lowercased()),
                   let incomingImageHash = jpegImageDataHash(for: fileURL),
                   incomingImageHash == jpegImageDataHash(for: candidateURL),
                   sameMetadataExceptProfile(fileURL, candidateURL) {
                    let cameraRGB = "Camera RGB Profile"
                    let existingProfile = profileName(of: candidateURL)
                    if existingProfile != cameraRGB || profileName(of: fileURL) == cameraRGB {
                        return "Skipped (same image, profile differs; kept existing) -> \(fileURL.lastPathComponent)"
                    }
                }
                
                attempt += 1
            }

            return "Error sorting \(fileURL.lastPathComponent): too many name collisions"
        } catch {
            return "Error sorting \(fileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private static func renamedFileName(for fileURL: URL, cameraModel: String?) -> String {
        let originalBase = fileURL.deletingPathExtension().lastPathComponent

        guard let cameraModel else {
            return "\(stripCopyMarker(originalBase)).\(fileURL.pathExtension)"
        }

        guard let modelPrefix = normalizedCameraModel(cameraModel) else {
            return "\(stripCopyMarker(originalBase)).\(fileURL.pathExtension)"
        }
        
        if originalBase.hasPrefix(modelPrefix) {
            return "\(stripCopyMarker(originalBase)).\(fileURL.pathExtension)"
        }

        let baseName = originalBase
        let upperBase = baseName.uppercased()

        let dropCount: Int
        if upperBase.hasPrefix("IMG_") || upperBase.hasPrefix("_MG_") {
            dropCount = 4
        } else if upperBase.hasPrefix("DSCN") {
            dropCount = 4
        } else if upperBase.hasPrefix("DSC") {
            dropCount = 3
        } else {
            dropCount = 0
        }
        let strippedPrefix = droppedPrefix ? String(baseName.dropFirst(dropCount)) : baseName

        // Strip copy markers (1234-2, 1234_2, 1234 (2)) but keep an edit suffix: 1234-2_mod -> 1234_mod
        if strippedPrefix,
           let regex = try? NSRegularExpression(pattern: "^([0-9]+)(?:-[0-9]+|_[0-9]+| \\([0-9]+\\))?(_mod|_edited)?(?: \\([0-9]+\\))?$"),
           let m = regex.firstMatch(in: sequence, range: NSRange(sequence.startIndex..., in: sequence)),
           let digitsRange = Range(m.range(at: 1), in: sequence) {
            var rebuilt = String(sequence[digitsRange])
            if m.range(at: 2).location != NSNotFound, let r = Range(m.range(at: 2), in: sequence) {
                rebuilt += String(sequence[r])
            }
            sequence = rebuilt
        }

        sequence = stripCopyMarker(sequence)

        return "\(modelPrefix)\(sequence).\(fileURL.pathExtension)"
    }
    
    private static func normalizedCameraModel(_ model: String) -> String? {
        if let phonePrefix = iPhonePrefix(from: model) {
                return phonePrefix
            }
        
        let normalizedModel = model.uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        if normalizedModel.contains("R7") {
            return "R7_"
        } else if normalizedModel.contains("R50") {
            return "R50_"
        } else if normalizedModel.hasSuffix("REBELXT") {
            return "XT_"
        } else if normalizedModel.contains("EOSR") && !normalizedModel.contains("REBEL") {
            return "R_"
        } else if normalizedModel.contains("80D") {
            return "80D_"
        } else if normalizedModel.contains("40D") {
            return "40D_"
        } else if normalizedModel.contains("30D") {
            return "30D_"
        } else if normalizedModel.contains("20D") {
            return "20D_"
        } else if normalizedModel.contains("G5X") {
            return "G5X_"
        } else if normalizedModel.contains("DMCGF3") {
            return "GF3_"
        } else if normalizedModel.hasSuffix("DSCH20") {
            return "H20_"
        } else if normalizedModel.hasSuffix("DSCW1") {
            return "W1_"
        } else if normalizedModel.contains("DSCRX100") {
            return "RX1_"         // RX100 and RX100M3
        } else if normalizedModel.contains("COOLPIXS6000") {
            return "Nik_"
        } else if normalizedModel.contains("VIXIAHF10") {
            return "HF10_"        // Canon Camcorder

        // Other cameras in the family.  LC = Louie; PM = Peggy; SM = Sarah; PD = Paul
        } else if normalizedModel.contains("REBELT2I") {
            return "T2i_"
        } else if normalizedModel.contains("POWERSHOTA95") {
            return "LC1_"
        } else if normalizedModel.contains("POWERSHOTS5IS") {
            return "LC2_"
        } else if normalizedModel.contains("ELPH") || normalizedModel.contains("IXUS220") {
            return "PM1_"
        } else if normalizedModel.contains("POWERSHOTSD1000") {
            return "PM2_"
        } else if normalizedModel.contains("SD4500") {
            return "PM3_"
        } else if normalizedModel.contains("SX620") {
            return "PM4_"         // Peggy's 4th Canon
        } else if normalizedModel.hasSuffix("DSCHX1") {
            return "SM2_"         // Sarah's Sony HX1
        } else if normalizedModel.contains("COOLPIXS8100") {
            return "SM1_"         // Sarah's Nikon S8100
        } else if normalizedModel.contains("DSCH50") {
            return "PD1_"         // Paul's Sony
        } else if normalizedModel.contains("SD1200") {
            return "SPM_"         // Sister Peggy
        
        } else {
            return nil
        }
    }

    private static func fetchCameraModel(for fileURL: URL) async -> String? {
        if let imageModel = fetchImageCameraModel(for: fileURL) {
            return imageModel
        }
        return await fetchVideoCameraModel(for: fileURL)
    }

    private static func fetchImageCameraModel(for fileURL: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let tiffProperties = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return tiffProperties?[kCGImagePropertyTIFFModel] as? String
    }

    private static func fetchVideoCameraModel(for fileURL: URL) async -> String? {
        let asset = AVURLAsset(url: fileURL)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        let models = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierModel)
        guard let item = models.first else { return nil }
        return try? await item.load(.stringValue)
    }

    private static func iPhonePrefix(from model: String) -> String? {
        let lower = model.lowercased()
        guard lower.hasPrefix("iphone") else { return nil }
        let rest = lower.dropFirst("iphone".count).trimmingCharacters(in: .whitespaces)

        // SE models: "se (3rd generation)" -> SE3_, plain "se" -> SE1_
        if rest.hasPrefix("se") {
            let gen = rest.first(where: { $0.isNumber }).map(String.init) ?? "1"
            return "SE\(gen)_"
        }

        // Everything else: iP + generation + short suffix
        let digits = rest.prefix(while: { $0.isNumber })
        var tail = String(rest.dropFirst(digits.count))
        tail = tail.replacingOccurrences(of: "pro max", with: "pm")
            .replacingOccurrences(of: "pro", with: "p")
            .replacingOccurrences(of: "plus", with: "pl")
            .replacingOccurrences(of: "mini", with: "m")
            .filter { $0.isLetter || $0.isNumber }
            .uppercased()
        return "iP\(digits)\(tail)_"
    }
    
    private static func calculateSHA256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var reachedEnd = false
        while !reachedEnd {
            try autoreleasepool {
                if let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                    hasher.update(data: chunk)
                } else {
                    reachedEnd = true
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    
    // Hash of a JPEG's compressed image data only: skips every APPn (EXIF, ICC, XMP...) and COM segment.
    private static func jpegImageDataHash(for url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let bytes = [UInt8](data)

        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            return nil
        }

        var hasher = SHA256()
        hasher.update(data: Data([0xFF, 0xD8]))
        var index = 2
        var foundScan = false

        while index < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let markerStart = index

            repeat {
                index += 1
            } while index < bytes.count && bytes[index] == 0xFF

            guard index < bytes.count else { return nil }
            let marker = bytes[index]
            index += 1

            if marker == 0xD9 {
                hasher.update(data: data.subdata(in: markerStart..<index))
                break
            }

            // Restart markers and the temporary marker have no length field.
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                hasher.update(data: data.subdata(in: markerStart..<index))
                continue
            }

            guard index + 1 < bytes.count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            let segmentEnd = index + length
            guard length >= 2, segmentEnd <= bytes.count else { return nil }

            if marker == 0xDA {
                foundScan = true
                hasher.update(data: data.subdata(in: markerStart..<bytes.count))
                break
            }

            // APP segments and comments contain metadata, including ICC color profiles.
            if !(0xE0...0xEF).contains(marker) && marker != 0xFE {
                hasher.update(data: data.subdata(in: markerStart..<segmentEnd))
            }

            index = segmentEnd
        }

        return foundScan ? hasher.finalize().map { String(format: "%02x", $0) }.joined() : nil
    }

    private static func sameMetadataExceptProfile(_ firstURL: URL, _ secondURL: URL) -> Bool {
        func properties(for url: URL) -> NSDictionary? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  var imageProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
                return nil
            }

            imageProperties.removeValue(forKey: kCGImagePropertyProfileName as String)
            return imageProperties as NSDictionary
        }

        guard let first = properties(for: firstURL), let second = properties(for: secondURL) else {
            return false
        }

        return first.isEqual(second)
    }

    private static func profileName(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        return properties[kCGImagePropertyProfileName] as? String
    }

    private static func getFileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }
    
    private static func applyMetadataDates(to fileURL: URL, rawDate: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        guard let date = formatter.date(from: rawDate) else { return }

        try? FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: fileURL.path
        )
    }

    private static func fetchCreationDate(for fileURL: URL) async -> (date: String, fromFile: Bool)? {
        if let imageDate = fetchImageCreationDate(for: fileURL) {
            return (imageDate, false)
        }

        let fileDate = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        let usableFileDate: Date? = {
            guard let fileDate, Calendar.current.component(.year, from: fileDate) >= 1990 else { return nil }
            return fileDate
        }()

        if let video = await fetchVideoCreationDate(for: fileURL) {
            if video.fromCaptureTag { return (video.date, false) }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let usableFileDate,
               let containerDate = formatter.date(from: video.date),
               usableFileDate < containerDate {
                return (metadataDateString(from: usableFileDate), true)
            }
            return (video.date, false)
        }

        if let usableFileDate {
            return (metadataDateString(from: usableFileDate), true)
        }
        return nil
    }
    
    private static func isLegacyVideo(_ fileURL: URL) -> Bool {
        ["mpg", "mpeg", "avi"].contains(fileURL.pathExtension.lowercased())
    }
    
    private static func fetchImageCreationDate(for fileURL: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let exifProperties = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiffProperties = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        return (exifProperties?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exifProperties?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiffProperties?[kCGImagePropertyTIFFDateTime] as? String)
    }

    private static func fetchVideoCreationDate(for fileURL: URL) async -> (date: String, fromCaptureTag: Bool)? {
        let asset = AVURLAsset(url: fileURL)

        if let items = try? await asset.load(.metadata) {
            let tagged = AVMetadataItem.metadataItems(
                from: items,
                filteredByIdentifier: .quickTimeMetadataCreationDate
            )
            if let item = tagged.first,
               let text = try? await item.load(.stringValue),
               let formatted = exifStyleDate(fromISO: text) {
                return (formatted, true)
            }
        }

        do {
            guard let creationDate = try await asset.load(.creationDate) else {
                return nil
            }

            if let date = try await creationDate.load(.dateValue) {
                return (metadataDateString(from: date), false)
            }

            if let dateString = try await creationDate.load(.stringValue),
               let parsed = ISO8601DateFormatter().date(from: dateString) {
                return (metadataDateString(from: parsed), false)
            }
        } catch {
            return nil
        }

        return nil
    }
    
    private static func exifStyleDate(fromISO text: String) -> String? {
        let chars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(19))
        guard chars.count == 19,
              chars[4] == "-" || chars[4] == ":",
              chars[7] == "-" || chars[7] == ":",
              chars[10] == "T" || chars[10] == " ",
              chars[0...3].allSatisfy({ $0.isNumber }) else { return nil }
        var out = chars
        out[4] = ":"
        out[7] = ":"
        out[10] = " "
        return String(out)
    }
    
    private static func metadataDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    private static func isErrorResult(_ result: String) -> Bool {
        result.hasPrefix("Failed")
            || result.hasPrefix("Invalid")
            || result.hasPrefix("Error")
            || result.hasPrefix("Name Collision")
    }
    
    private func log(_ message: String) {
        statusLog.append("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
    }
}
