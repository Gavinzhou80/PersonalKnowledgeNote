import AppSupport
import DocumentImport
import Foundation
import KnowledgeCore
import SwiftUI

/// Three-pane reading workbench: document list with import control in
/// the sidebar, the artifact reading view in the content pane, and the
/// outline in the inspector.
struct ReadingWorkbenchView: View {
    let model: ReadingWorkbenchModel

    @State private var selectedDocumentID: SourceDocumentID?
    @State private var importField = ""
    @State private var scrollRequest: ReadingScrollRequest?
    @SceneStorage("reading.inspectorVisible")
    private var inspectorVisible = true
    @SceneStorage("reading.columnVisibility")
    private var columnVisibilityRaw = "all"

    private var store: ReadingWorkbenchStore { model.readingStore }
    private var importTasks: ImportTaskStore { model.importTaskStore }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                columnVisibilityRaw == "detailOnly" ? .detailOnly : .all
            },
            set: { newValue in
                columnVisibilityRaw = newValue == .detailOnly
                    ? "detailOnly"
                    : "all"
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            sidebar
        } detail: {
            readingPane
                .inspector(isPresented: $inspectorVisible) {
                    outline
                        .inspectorColumnWidth(min: 180, ideal: 240)
                }
                .toolbar {
                    ToolbarItem {
                        Button(
                            "Toggle Outline",
                            systemImage: "list.bullet.indent"
                        ) {
                            inspectorVisible.toggle()
                        }
                    }
                }
        }
        .onChange(of: selectedDocumentID) { _, newValue in
            Task { await store.select(newValue) }
        }
        .onChange(of: importTasks.completedTaskIDs) { oldValue, newValue in
            guard !newValue.subtracting(oldValue).isEmpty else {
                return
            }
            Task { await store.loadDocumentList() }
        }
    }

    private var sidebar: some View {
        List(selection: $selectedDocumentID) {
            Section("Documents") {
                ForEach(store.summaries, id: \.documentID) { summary in
                    Text(summary.title)
                        .lineLimit(2)
                        .tag(summary.documentID)
                }
            }
            if !importTasks.tasks.isEmpty {
                Section("Imports") {
                    ForEach(importTasks.tasks, id: \.id) { task in
                        let presentation = ImportCenterPresentation
                            .task(task)
                        Label(
                            presentation.message,
                            systemImage: presentation.systemImage
                        )
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .safeAreaInset(edge: .bottom) {
            importControl
        }
    }

    private var importControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Import a web page URL…", text: $importField)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    submitImport()
                }
            HStack {
                Button("Import") {
                    submitImport()
                }
                .disabled(importField.isEmpty)
                if store.importState == .invalidURL {
                    Text("Enter a valid http(s) URL")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(.bar)
    }

    @ViewBuilder
    private var readingPane: some View {
        if let loadURL = store.artifactLoadURL {
            ArtifactWebView(
                library: model.libraryPort,
                loadURL: loadURL,
                scrollRequest: scrollRequest
            )
            // Keying by the load URL keeps one WKWebView alive per
            // document; a rebuilt representable would race its initial
            // load against the in-flight one (frame load error 102).
            .id(loadURL)
        } else {
            ContentUnavailableView(
                "No Document Selected",
                systemImage: "book",
                description: Text(
                    "Choose a document from the sidebar to read it."
                )
            )
        }
    }

    private var outline: some View {
        List(store.outline, id: \.blockIndex) { node in
            Button {
                scrollRequest = ReadingScrollRequest(
                    blockIndex: node.blockIndex
                )
            } label: {
                Text(node.text)
                    .lineLimit(2)
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(max(node.level - 1, 0)) * 12)
        }
        .overlay {
            if store.outline.isEmpty {
                ContentUnavailableView(
                    "No Outline",
                    systemImage: "list.bullet",
                    description: Text(
                        "This document has no headings."
                    )
                )
            }
        }
    }

    private func submitImport() {
        let raw = importField
        Task {
            await store.submitImport(rawURL: raw)
            if store.importState == .submitted {
                importField = ""
            }
        }
    }
}
