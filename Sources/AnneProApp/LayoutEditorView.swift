import AnneProKit
import SwiftUI

struct LayoutEditorView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var layerState = LocalState(KeyLayout.Layer.base)
    @StateObject private var editingState = LocalState<PhysicalKey?>(nil)

    private var layer: KeyLayout.Layer { layerState.value }
    private var editing: PhysicalKey? {
        get { editingState.value }
        nonmutating set { editingState.value = newValue }
    }

    var body: some View {
        VStack(spacing: 16) {
            Picker("Layer", selection: $layerState.value) {
                ForEach(KeyLayout.Layer.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            KeyboardCase {
                KeyboardCanvas { key, _ in
                    let code = model.layout[layer, key]
                    let locked = model.layout.isLocked(key, on: layer)
                    LayoutKeycap(
                        code: code,
                        isLocked: locked,
                        isSelected: editing?.id == key.id,
                        isChanged: code != KeyLayout.windows[layer, key]
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { if !locked { editing = key } }
                    .popover(isPresented: Binding(
                        get: { editing?.id == key.id },
                        set: { if !$0 { editing = nil } }
                    ), arrowEdge: .bottom) {
                        KeyCodePicker(current: code, allowSpecial: layer == .base) { newCode in
                            model.assign(newCode, to: key, on: layer)
                            editing = nil
                        }
                    }
                    .help(locked ? lockReason(for: key) : "\(KeyCode.named(code).name) — click to change")
                }
            }

            HStack(spacing: 8) {
                Text("Start from").font(.headline)
                ForEach(KeyLayout.presets, id: \.name) { preset in
                    Button(preset.name) { model.applyLayoutPreset(preset.layout) }
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text("Differs from the Windows layout")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.layout.issues, id: \.description) { issue in
                    Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(layer == .base
                     ? "What each key types normally. Every layout needs one Fn and one Anne key; they're copied to the Fn layer automatically."
                     : "What each key types while Fn is held. Locked keys are used by the keyboard itself (Bluetooth and the Fn/Anne keys).")
                    .foregroundStyle(.secondary)
                Text("Sending saves the layout on the keyboard and switches it to the Custom layout. You can switch back from the menu bar at any time.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusBar()
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 500)
        .toolbar {
            ToolbarItemGroup {
                Button { model.undoLayout() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndoLayout)
                Button { model.importLayout() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { model.exportLayout() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Button { model.readLayout() } label: { Label("Read from Keyboard", systemImage: "arrow.down.circle") }
                    .disabled(!model.isConnected || model.isBusy)
                    .help("Load the custom layout stored on the keyboard")
                Button { model.sendLayout() } label: { Label("Send to Keyboard", systemImage: "paperplane.fill") }
                    .disabled(!model.isConnected || model.isBusy || !model.layout.issues.isEmpty)
                    .keyboardShortcut(.return)
                    .help("Save this layout on the keyboard and switch to it")
            }
        }
        .navigationTitle("Custom Layout")
    }

    private func lockReason(for key: PhysicalKey) -> String {
        KeyLayout.reservedFnKeyIDs.contains(key.id)
            ? "Reserved by the keyboard's firmware"
            : "Fn and Anne stay on the same key in both layers — change them in the base layer"
    }
}

/// Searchable list of key codes, grouped by category.
struct KeyCodePicker: View {
    let current: UInt8
    let allowSpecial: Bool
    let choose: (UInt8) -> Void
    @StateObject private var searchState = LocalState("")
    private var search: String { searchState.value }

    private var groups: [(KeyCode.Category, [KeyCode])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return KeyCode.Category.allCases.compactMap { category in
            guard allowSpecial || category != .special else { return nil }
            let codes = KeyCode.all.filter { code in
                code.category == category && (query.isEmpty || code.name.lowercased().contains(query) || code.legend.lowercased() == query)
            }
            return codes.isEmpty ? nil : (category, codes)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search keys", text: $searchState.value)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(groups, id: \.0) { category, codes in
                        Section(category.rawValue) {
                            ForEach(codes) { code in
                                Button { choose(code.code) } label: {
                                    HStack {
                                        Text(code.name)
                                        Spacer()
                                        if code.code == current {
                                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(code.code)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onAppear { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .frame(width: 260, height: 360)
    }
}
