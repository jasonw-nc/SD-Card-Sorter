import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var engine = SorterEngine()
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photo Sorter")
                        .font(.title2)
                        .bold()
                    Text("Auto-organize RAW and JPEG files into structured folders")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                HStack(spacing: 4) {
                    Text("SHA-256 Verification")
                        .foregroundStyle(.secondary)
                    Text("ON")
                        .bold()
                        .foregroundStyle(.green)
                }
                .font(.caption)
            }
            .padding(.horizontal)
            
            // Destination Selector
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.blue)
                Text(engine.destinationURL.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Change...") {
                    selectDestinationFolder()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
 
 // Removed UI Toggle in leu of SHA-256 always on
 //           // SHA-256 UI Toggle
 //           Toggle("SHA-256 Verify", isOn: $engine.verifyDuplicatesWithHash)
 //               .toggleStyle(.checkbox)
 //               .disabled(engine.isProcessing)
 //               .padding(.horizontal)
 //               .padding(.vertical, 4)

            // Drop Area
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(isTargeted ? Color.accentColor.opacity(0.05) : Color.clear)

                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.largeTitle)
                        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                    Text("Drag and Drop Photos or Folders Here")
                        .font(.headline)
                    Text("Supports .CR3, .JPG, .JPEG, .MOV, .MP4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 140)
            .padding(.horizontal)
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }

            // Progress Section
            if engine.isProcessing || engine.processedFiles > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(engine.isProcessing ? "Processing: \(engine.currentFileName)" : "Completed")
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text("\(engine.processedFiles) of \(engine.totalFiles)")
                            .font(.caption)
                            .monospacedDigit()
                    }
                    ProgressView(value: engine.progressFraction)
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal)
            }
            
            // Error Console (only appears when errors exist)
            if !engine.errorLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Errors (\(engine.errorLog.count))",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Copy All") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                engine.errorLog.joined(separator: "\n"),
                                forType: .string
                            )
                        }
                        .controlSize(.small)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(engine.errorLog.enumerated()), id: \.offset) { _, message in
                                Text(message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(minHeight: 60, maxHeight: 140)
                    .background(Color.red.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red.opacity(0.5), lineWidth: 1)
                    )
                    .cornerRadius(6)
                }
                .padding(.horizontal)
                .transition(.opacity)
            }

            // Activity Log Console
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Activity Console")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Export Log...") {
                        exportLog()
                    }
                    .controlSize(.small)
                    .disabled(engine.statusLog.isEmpty || engine.isProcessing)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(engine.statusLog.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .id(index)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.8))
                    .cornerRadius(6)
                    .onChange(of: engine.statusLog.count) { _, newCount in
                        if newCount > 0 {
                            proxy.scrollTo(newCount - 1, anchor: .bottom)
                        }
                    }
                }
                .frame(minHeight: 120)
                .padding(.horizontal)
            }
        }
        .padding(.vertical)
    }
    
    private func selectDestinationFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        
        if panel.runModal() == .OK, let url = panel.url {
            engine.destinationURL = url
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let urlsLock = NSLock()
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    urlsLock.lock()
                    urls.append(url)
                    urlsLock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                engine.processDroppedURLs(urls)
            }
        }
        return true
    }

    private func exportLog() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HHmm"
        panel.nameFieldStringValue = "Sorter Log \(stamp.string(from: Date())).txt"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var text = engine.statusLog.joined(separator: "\n")
        if !engine.errorLog.isEmpty {
            text += "\n\n==== ERRORS (\(engine.errorLog.count)) ====\n"
            text += engine.errorLog.joined(separator: "\n")
        }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
