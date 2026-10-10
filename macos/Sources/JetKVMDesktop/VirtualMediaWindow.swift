import AppKit
import JetKVMCore
import SwiftUI

/// Virtual media for one device: what is mounted, mounting an image by URL
/// or from the device's storage, and uploading images to that storage.
@MainActor
final class VirtualMediaModel: ObservableObject {
    struct Upload: Equatable {
        var id: Int64
        var filename: String
        var sent: Int64 = 0
        var total: Int64 = 0
        var bytesPerSecond: Double = 0
    }

    @Published private(set) var mounted: VirtualMediaState?
    @Published private(set) var files: [StorageFile] = []
    @Published private(set) var space: StorageSpace?
    @Published private(set) var upload: Upload?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var urlText = ""
    @Published var urlMode = VirtualMediaMode.cdrom

    private let engine: EngineProcess
    /// Local paths of uploads started in this session, to resume them.
    private var uploadPaths: [String: URL] = [:]

    init(engine: EngineProcess) {
        self.engine = engine
    }

    func refresh() async {
        do {
            mounted = try await engine.call("getVirtualMediaState", as: VirtualMediaState?.self)
            files = try await engine.call("listStorageFiles", as: StorageFiles.self).files
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            space = try? await engine.call("getStorageSpace", as: StorageSpace.self)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        busy = true
        error = nil
        do {
            try await action()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
        await refresh()
    }

    func mountURL() async {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        await perform {
            try await engine.call("mountWithHTTP", params: .object(["url": .string(url), "mode": .string(urlMode.rawValue)]))
        }
    }

    func mount(_ file: StorageFile, mode: VirtualMediaMode) async {
        await perform {
            try await engine.call("mountWithStorage", params: .object(["filename": .string(file.filename), "mode": .string(mode.rawValue)]))
        }
    }

    func eject() async {
        await perform { try await engine.call("unmountImage") }
    }

    func delete(_ file: StorageFile) async {
        await perform { try await engine.call("deleteStorageFile", params: .object(["filename": .string(file.filename)])) }
    }

    /// Uploads a local image; an earlier, interrupted upload of the same
    /// file resumes where it stopped.
    func upload(_ url: URL) async {
        guard upload == nil else { return }
        uploadPaths[url.lastPathComponent] = url
        error = nil
        do {
            try await engine.run(EngineCommand(cmd: "upload", path: url.path)) { id in
                self.upload = Upload(id: id, filename: url.lastPathComponent)
            }
        } catch {
            self.error = error.localizedDescription
        }
        upload = nil
        await refresh()
    }

    /// The local file to resume an incomplete upload from, if known.
    func resumePath(for file: StorageFile) -> URL? {
        uploadPaths[String(file.filename.dropLast(".incomplete".count))]
    }

    func cancelUpload() {
        guard let upload else { return }
        engine.send(command: EngineCommand(cmd: "cancelUpload", target: upload.id))
    }

    func progress(_ progress: UploadProgress) {
        guard upload?.id == progress.id else { return }
        upload?.sent = progress.sent
        upload?.total = progress.total
        upload?.bytesPerSecond = progress.bytesPerSecond
    }
}

struct VirtualMediaView: View {
    @ObservedObject var model: VirtualMediaModel
    @State private var confirmDelete: StorageFile?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Mounted") {
                HStack {
                    if let mounted = model.mounted {
                        Image(systemName: mounted.mode == VirtualMediaMode.cdrom.rawValue ? "opticaldisc" : "externaldrive")
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text(mounted.title).lineLimit(1).truncationMode(.middle)
                            Text("\(VirtualMediaMode(rawValue: mounted.mode)?.label ?? mounted.mode) · \(Self.bytes(mounted.size)) · \(mounted.source == "HTTP" ? "from URL" : "from device storage")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Eject") { Task { await model.eject() } }
                    } else {
                        Text("Nothing mounted").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(4)
            }

            GroupBox("Mount from URL") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("https://example.com/installer.iso", text: $model.urlText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await model.mountURL() } }
                        Picker("", selection: $model.urlMode) {
                            ForEach(VirtualMediaMode.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Button("Mount") { Task { await model.mountURL() } }
                            .disabled(model.mounted != nil || model.urlText.isEmpty || model.busy)
                    }
                    Text("The device streams the image on demand, so the server must support byte-range requests.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }

            GroupBox("Device storage") {
                VStack(alignment: .leading, spacing: 8) {
                    if model.files.isEmpty {
                        Text("No images stored on the device.").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    } else {
                        List(model.files) { file in
                            row(file)
                        }
                        .frame(minHeight: 140)
                    }
                    HStack {
                        if let space = model.space {
                            Text("\(Self.bytes(space.bytesFree)) free of \(Self.bytes(space.bytesUsed + space.bytesFree))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let upload = model.upload {
                            uploadProgress(upload)
                        } else {
                            Button("Upload Image…") { chooseUpload() }
                        }
                    }
                }
                .padding(4)
            }

            if let error = model.error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 460)
        .task { await model.refresh() }
        .confirmationDialog("Delete \(confirmDelete?.filename ?? "")?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let file = confirmDelete { Task { await model.delete(file) } }
            }
        } message: {
            Text("The image is removed from the device's storage.")
        }
    }

    @ViewBuilder private func row(_ file: StorageFile) -> some View {
        HStack {
            Image(systemName: file.isIncomplete ? "exclamationmark.triangle" : "doc")
                .foregroundStyle(file.isIncomplete ? .orange : .secondary)
            VStack(alignment: .leading) {
                Text(file.filename).lineLimit(1).truncationMode(.middle)
                Text(file.isIncomplete ? "Incomplete upload (\(Self.bytes(file.size))): upload the same file again to resume" : Self.bytes(file.size))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if file.isIncomplete {
                if let path = model.resumePath(for: file), model.upload == nil {
                    Button("Resume") { Task { await model.upload(path) } }
                }
            } else {
                Menu("Mount") {
                    ForEach(VirtualMediaMode.allCases, id: \.self) { mode in
                        Button("As \(mode.label)") { Task { await model.mount(file, mode: mode) } }
                    }
                }
                .fixedSize()
                .disabled(model.mounted != nil || model.busy)
            }
            Button(role: .destructive) { confirmDelete = file } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(model.mounted?.filename == file.filename)
        }
    }

    @ViewBuilder private func uploadProgress(_ upload: VirtualMediaModel.Upload) -> some View {
        let fraction = upload.total > 0 ? Double(upload.sent) / Double(upload.total) : 0
        HStack {
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: fraction).frame(width: 180)
                Text("\(upload.filename): \(Int(fraction * 100)) %\(upload.bytesPerSecond > 0 ? " · \(Self.bytes(Int64(upload.bytesPerSecond)))/s" : "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("Cancel") { model.cancelUpload() }
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.message = "Choose a disk image (.iso, .img) to upload to the device"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.upload(url) }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

final class VirtualMediaWindowController: NSWindowController {
    let model: VirtualMediaModel

    init(model: VirtualMediaModel, deviceName: String) {
        self.model = model
        let window = NSWindow(contentViewController: NSHostingController(rootView: VirtualMediaView(model: model)))
        window.title = "Virtual Media — \(deviceName)"
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 600, height: 520))
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
