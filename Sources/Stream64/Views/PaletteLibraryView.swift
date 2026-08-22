import SwiftUI

/// Picker used where both the grouped built-in list and named custom entries
/// must be selectable (the settings pane and compact controls).
struct PaletteSelectionMenu: View {
    @Binding var choice: PaletteChoice
    @Binding var customPaletteID: UUID?
    @ObservedObject private var library = PaletteLibrary.shared

    var body: some View {
        Menu {
            Section("Built-in") {
                ForEach(PaletteChoice.builtInCases) { palette in
                    Button {
                        choice = palette
                    } label: {
                        Label(palette.rawValue,
                              systemImage: choice == palette ? "checkmark" : "")
                    }
                }
            }
            Section("Custom") {
                if library.palettes.isEmpty {
                    Text("No custom palettes")
                } else {
                    ForEach(library.palettes) { palette in
                        Button {
                            choice = .custom
                            customPaletteID = palette.id
                        } label: {
                            Label(palette.name, systemImage:
                                choice == .custom && customPaletteID == palette.id
                                ? "checkmark" : "")
                        }
                    }
                }
            }
        } label: {
            Text(selectionName)
        }
    }

    private var selectionName: String {
        if choice == .custom {
            return library.palette(id: customPaletteID)?.name ?? "Custom (Pepto PAL fallback)"
        }
        return choice.rawValue
    }
}

struct PaletteLibraryEditor: View {
    @ObservedObject private var library = PaletteLibrary.shared
    @State private var selectedID: UUID?

    var body: some View {
        Section {
            HStack {
                Picker("Custom palette", selection: $selectedID) {
                    Text("Select a palette").tag(UUID?.none)
                    ForEach(library.palettes) { palette in
                        Text(palette.name).tag(Optional(palette.id))
                    }
                }
                Button("Add") {
                    library.add()
                    selectedID = library.palettes.last?.id
                }
                Button("Delete", role: .destructive) {
                    if let selectedID {
                        library.remove(id: selectedID)
                        self.selectedID = library.palettes.first?.id
                    }
                }
                .disabled(selectedID == nil)
            }
            if let palette = library.palette(id: selectedID) {
                PaletteEditor(palette: palette)
            } else {
                Text("Create a named palette to edit its 16 C64 colors.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Palette Library")
        } footer: {
            Text("Custom palettes are shared by all devices. Deleted selections use Pepto PAL until another custom palette is chosen.")
                .foregroundStyle(.secondary)
        }
        .onAppear { selectedID = selectedID ?? library.palettes.first?.id }
    }
}

private struct PaletteEditor: View {
    let palette: CustomC64Palette
    @ObservedObject private var library = PaletteLibrary.shared

    var body: some View {
        TextField("Name", text: Binding(
            get: { palette.name },
            set: { rename($0) }))
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4)) {
            ForEach(0..<16, id: \.self) { index in
                ColorPicker("Color \(index)", selection: Binding(
                    get: { palette.colors[index].swiftUIColor },
                    set: { setColor($0, at: index) }),
                    supportsOpacity: true)
                    .labelsHidden()
                    .help("C64 color \(index)")
            }
        }
    }

    private func rename(_ name: String) {
        var edited = palette
        edited.name = name
        library.update(edited)
    }

    private func setColor(_ color: Color, at index: Int) {
        var edited = palette
        edited.colors[index] = C64RGBAColor(color)
        library.update(edited)
    }
}
