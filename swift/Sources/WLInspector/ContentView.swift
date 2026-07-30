import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HSplitView {
            controls
                .frame(minWidth: 380, idealWidth: 400, maxWidth: 520)
            LogView()
                .frame(minWidth: 420)
        }
        .frame(minWidth: 900, minHeight: 640)
        .toolbar { toolbar }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.connected ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 9, height: 9)
                Text(model.connected ? model.deviceName : "Not connected")
                    .font(.system(.body, design: .rounded)).bold()
            }
        }
        ToolbarItemGroup {
            if model.connected {
                Label(model.firmware, systemImage: "cpu").labelStyle(.titleAndIcon)
                Label(model.battery, systemImage: "battery.100").labelStyle(.titleAndIcon)
                Button("Disconnect") { model.disconnect() }
            } else {
                Button("Connect") { model.connect() }.keyboardShortcut("r")
            }
        }
    }

    // MARK: - Left column

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error = model.lastError, !model.connected {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                section("Keys") {
                    PadView()
                    HStack(spacing: 8) {
                        Button("Top 6") { model.selection = Set(0..<6) }
                        Button("All") { model.selection = Set(0..<Pad.keyCount) }
                        Button("None") { model.selection = [] }
                        Spacer()
                        Text("\(model.selection.count) selected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                section("Colour") {
                    ColorPicker("Colour", selection: $model.editColor, supportsOpacity: false)
                    Text(hexString(model.editColor.packedRGB))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Picker("Effect", selection: $model.editEffect) {
                        ForEach(OAI.Effect.allCases) { Text($0.label).tag($0) }
                    }
                    slider("Brightness", $model.editBrightness)
                    slider("Speed", $model.editSpeed)

                    HStack(spacing: 8) {
                        Button("Apply to selected") { model.applyToSelection() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.connected || model.selection.isEmpty)
                        Button("Clear selected") { model.clearSelection() }
                            .disabled(!model.connected || model.selection.isEmpty)
                    }
                    Button("Apply to whole keys zone") { model.applyKeysZone() }
                        .disabled(!model.connected)
                    Text("The zone is a single colour across all keys. Per-key colours override it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Underglow") {
                    ColorPicker("Colour", selection: $model.ambientColor, supportsOpacity: false)
                    Picker("Effect", selection: $model.ambientEffect) {
                        ForEach(OAI.Effect.allCases) { Text($0.label).tag($0) }
                    }
                    slider("Brightness", $model.ambientBrightness)
                    slider("Speed", $model.ambientSpeed)
                    Button("Apply underglow") { model.applyAmbient() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.connected)
                }

                section("Everything") {
                    HStack(spacing: 8) {
                        Button("Resend whole pad") { model.applyWholePad() }
                        Button("Walk keys 0→12") { model.runWalk() }
                    }
                    .disabled(!model.connected)
                    Button("All lights off", role: .destructive) { model.allOff() }
                        .disabled(!model.connected)
                    Text("Clears every key and both zones. Zones alone are not enough — key colour paints over them.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                RawCallView()
            }
            .padding(16)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(.caption, design: .monospaced)).bold()
                .foregroundStyle(.secondary)
                .kerning(1.2)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func slider(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 76, alignment: .leading)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 38, alignment: .trailing)
                .monospacedDigit()
        }
    }
}

// MARK: - Pad

struct PadView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Pad.rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in
                        keyView(key)
                    }
                }
            }
            Text("Key index is 0-based, row-major. Agent keys are 0–5.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func keyView(_ index: Int) -> some View {
        let state = model.keys[index]
        let selected = model.selection.contains(index)
        return Button {
            if selected { model.selection.remove(index) } else { model.selection.insert(index) }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(state.isLit ? state.color : Color.secondary.opacity(0.12))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35),
                                  lineWidth: selected ? 2.5 : 1)
                Text("\(index)")
                    .font(.system(.caption, design: .monospaced)).bold()
                    .foregroundStyle(state.isLit ? .black : .secondary)
            }
            .frame(width: 52, height: 40)
        }
        .buttonStyle(.plain)
        .help("Key \(index)")
    }
}

// MARK: - Raw call

struct RawCallView: View {
    @EnvironmentObject var model: AppModel
    @State private var method = OAI.methodThreads
    @State private var params = "[{\"id\":0,\"c\":16711680,\"b\":1,\"e\":1,\"s\":0.5}]"

    private let presets: [(String, String, String)] = [
        ("Per-key red on key 0", OAI.methodThreads, "[{\"id\":0,\"c\":16711680,\"b\":1,\"e\":1,\"s\":0.5}]"),
        ("Key 1 breathing amber", OAI.methodThreads, "[{\"id\":1,\"c\":16752640,\"b\":1,\"e\":4,\"s\":0.5}]"),
        ("Zones: keys off, ambient green", OAI.methodRGBConfig,
         "{\"keys\":{\"e\":0,\"b\":0,\"s\":0.5,\"m\":1,\"c\":0},\"ambient\":{\"e\":1,\"b\":1,\"s\":0.5,\"m\":1,\"c\":51283}}"),
        ("Announce host app", "host.focused_app", "{\"name\":\"WLInspector\",\"bundle_id\":\"cc.worklouder.inspector\"}"),
        ("Device status", "device.status", ""),
        ("Firmware version", "sys.version", ""),
        ("List files", "fs.list", "{\"checksum\":false,\"rec\":true}"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RAW CALL")
                .font(.system(.caption, design: .monospaced)).bold()
                .foregroundStyle(.secondary).kerning(1.2)

            TextField("method", text: $method)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            TextEditor(text: $params)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 66)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                Menu("Presets") {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                        Button(preset.0) { method = preset.1; params = preset.2 }
                    }
                }
                Spacer()
                Button("Send") { model.sendRaw(method: method, paramsJSON: params) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.connected)
            }
            Text("Params must be JSON. Remember: field names are abbreviated (c, b, e, s, m) and effect is a number.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(LogEntry.Kind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(
                        get: { model.visibleKinds.contains(kind) },
                        set: { on in
                            if on { model.visibleKinds.insert(kind) } else { model.visibleKinds.remove(kind) }
                        }
                    )) {
                        Text(kind.rawValue)
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(kind.color)
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Toggle("Pretty", isOn: $model.prettyPrint).toggleStyle(.checkbox)
                Toggle("Follow", isOn: $model.autoScroll).toggleStyle(.checkbox)
                Button("Copy") { model.copyLog() }
                Button("Clear") { model.clearLog() }
            }
            .padding(8)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.visibleEntries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.entries.count) { _ in
                    guard model.autoScroll, let last = model.visibleEntries.last else { return }
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func row(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(AppModel.stamp.string(from: entry.at))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(entry.kind.rawValue)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(entry.kind.color)
                    .frame(width: 52, alignment: .leading)
                Text(entry.title)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 68)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
