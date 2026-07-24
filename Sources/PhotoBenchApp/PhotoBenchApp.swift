import Foundation
import PhotoCore
import SwiftUI

@main
struct PhotoBenchApp: App {
    @StateObject private var model: EditorModel

    init() {
        let defaultPath = "/Users/takuyatakahama/Documents/app/NIHO/others/photo"
        let initialPath = CommandLine.arguments.dropFirst().first ?? defaultPath
        _model = StateObject(
            wrappedValue: EditorModel(
                initialDirectoryHint: URL(fileURLWithPath: initialPath, isDirectory: true)
            )
        )
    }

    var body: some Scene {
        WindowGroup("Photo Bench") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_140, minHeight: 720)
        }
        .defaultSize(width: 1_440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("写真フォルダを開く…", action: model.chooseFolder)
                    .keyboardShortcut("o")
                Button("XMPプリセットを読み込む…", action: model.importPreset)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("JPEGを書き出す…", action: model.exportFromPanel)
                    .keyboardShortcut("e", modifiers: [.command])
                    .disabled(!model.canExport)
            }
        }
    }
}
