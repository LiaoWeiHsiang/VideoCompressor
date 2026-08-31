//
//  VideoEditorHostView.swift
//  VideoEditorDemo
//
//  Created by xiaoyuan on 2026/8/29.
//

#if os(macOS)
import SwiftUI
import TimelineKitUIMac

/// macOS entry: hosts the self-contained clip editor workbench.
/// The editor manages its own library + projects internally — no EditorStore
/// is injected here anymore (a project == a timeline is created inside the editor).
struct VideoEditorView: View {
    var body: some View {
        ClipEditorView { _, _ in
            // Draft already saved inside ClipEditorView; keep hook for future.
        }
    }
}

#endif

