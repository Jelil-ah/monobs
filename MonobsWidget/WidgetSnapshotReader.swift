//
//  WidgetSnapshotReader.swift
//  MonobsWidget
//

import Foundation
import MonobsKit

/// Story 3.2 — READ-ONLY access to the shared container from the WidgetKit
/// extension. The extension NEVER writes, NEVER opens a socket, NEVER touches the
/// network: it only reads the single shared file the app process writes and hands
/// the bytes to the shared defensive decoder (MonobsKit).
///
/// A missing/illegible file (app never launched, or mid-rename) ⇒ `.unreadable`,
/// which the timeline provider renders as a readable degradation view — never a
/// crash (mirror of AD-10 client tolerance, extended to the app↔widget channel).
enum WidgetSnapshotReader {
    static func read(fileManager: FileManager = .default) -> SharedSnapshotDecodeResult {
        guard let fileURL = try? SharedSnapshotLocation.stateFileURL(fileManager: fileManager),
              let data = try? Data(contentsOf: fileURL) else {
            return .unreadable
        }
        return SharedSnapshotCodec.decode(data)
    }
}
