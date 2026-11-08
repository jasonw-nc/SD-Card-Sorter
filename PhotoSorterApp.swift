import SwiftUI

@main
struct PhotoSorterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 550, minHeight: 450)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
