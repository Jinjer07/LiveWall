import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var library: LibraryStore
    @State private var selectedID: String?
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Плейлисты", subtitle: "Смена обоев по таймеру или по времени суток") {
                Button {
                    let pl = Playlist(name: "Плейлист \(app.playlists.count + 1)")
                    withAnimation(Theme.spring) { app.playlists.append(pl); selectedID = pl.id }
                } label: { Label("Новый плейлист", systemImage: "plus") }
                .buttonStyle(CrimsonButtonStyle())
            }
            split
        }
        .onAppear { if selectedID == nil { selectedID = app.playlists.first?.id } }
    }

    private var split: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(app.playlists) { pl in
                        HStack {
                            Image(systemName: pl.mode == .timer ? "timer" : "clock")
                            Text(pl.name)
                            Spacer()
                            if app.activePlaylistID == pl.id { Image(systemName: "play.fill").foregroundStyle(.green) }
                        }
                        .tag(pl.id)
                    }
                }
                Divider()
                HStack {
                    Button {
                        let pl = Playlist(name: "Плейлист \(app.playlists.count + 1)")
                        app.playlists.append(pl)
                        selectedID = pl.id
                    } label: { Image(systemName: "plus") }
                    Button {
                        guard let id = selectedID else { return }
                        if app.activePlaylistID == id { app.activatePlaylist(nil) }
                        app.playlists.removeAll { $0.id == id }
                        selectedID = app.playlists.first?.id
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            Group {
                if let idx = app.playlists.firstIndex(where: { $0.id == selectedID }) {
                    editor(idx)
                } else {
                    ContentUnavailableView("Нет плейлиста", systemImage: "list.bullet.rectangle",
                                           description: Text("Создайте плейлист кнопкой «+»: обои будут меняться по таймеру или по времени суток."))
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }

    }

    @ViewBuilder
    private func editor(_ idx: Int) -> some View {
        let pl = $app.playlists[idx]
        let active = app.activePlaylistID == pl.wrappedValue.id
        Form {
            Section {
                TextField("Название", text: pl.name)
                Picker("Режим", selection: pl.mode) {
                    Text("По таймеру").tag(PlaylistMode.timer)
                    Text("По времени суток").tag(PlaylistMode.timeOfDay)
                }
                .pickerStyle(.segmented)
                HStack {
                    Button(active ? "Остановить" : "Запустить плейлист") {
                        app.activatePlaylist(active ? nil : pl.wrappedValue.id)
                    }
                    .buttonStyle(CrimsonButtonStyle())
                    if active && pl.wrappedValue.mode == .timer {
                        Button("Следующие") { app.nextInPlaylist() }
                    }
                }
            }

            if pl.wrappedValue.mode == .timer {
                Section("Смена обоев") {
                    Picker("Интервал", selection: pl.intervalMinutes) {
                        ForEach([1.0, 5, 10, 15, 30, 60, 120, 240, 480, 1440], id: \.self) { m in
                            Text(m < 60 ? "\(Int(m)) мин" : "\(Int(m / 60)) ч").tag(m)
                        }
                    }
                    Toggle("Случайный порядок", isOn: pl.shuffle)
                }
                Section {
                    ForEach(Array(pl.wrappedValue.items.enumerated()), id: \.offset) { i, id in
                        HStack {
                            if let it = library.item(id) {
                                Thumbnail(item: it, version: library.thumbVersion).frame(width: 64)
                                Text(it.title)
                            } else {
                                Text("Удалённые обои").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { move(idx, i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                            Button { move(idx, i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == pl.wrappedValue.items.count - 1)
                            Button { app.playlists[idx].items.remove(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                        }
                        .buttonStyle(.borderless)
                    }
                    Button("Добавить обои…") { showPicker = true }
                } header: { Text("Обои (\(pl.wrappedValue.items.count))") }
            } else {
                Section {
                    ForEach(pl.slots) { $slot in
                        HStack {
                            DatePicker("", selection: Binding(get: { date(slot) }, set: { d in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                slot.hour = c.hour ?? 0; slot.minute = c.minute ?? 0
                            }), displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .frame(width: 90)
                            Picker("", selection: $slot.wallpaperID) {
                                Text("—").tag(String?.none)
                                ForEach(library.items) { it in Text(it.title).tag(String?.some(it.id)) }
                            }
                            .labelsHidden()
                            Button {
                                app.playlists[idx].slots.removeAll { $0.id == slot.id }
                            } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("Добавить время") {
                        let last = app.playlists[idx].slots.map(\.hour).max() ?? 6
                        app.playlists[idx].slots.append(TimeSlot(hour: min(23, last + 6), minute: 0, wallpaperID: library.items.first?.id))
                        app.playlists[idx].slots.sort { $0.minutesOfDay < $1.minutesOfDay }
                    }
                } header: {
                    Text("Расписание")
                } footer: {
                    Text("С указанного времени и до следующего пункта стоят выбранные обои. Например: 07:00 — утро, 19:00 — вечер, 23:00 — ночь.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(CrimsonToggleStyle())
        .sheet(isPresented: $showPicker) {
            ItemPickerSheet(selected: Set(app.playlists[idx].items)) { ids in
                let existing = app.playlists[idx].items
                app.playlists[idx].items = existing.filter { ids.contains($0) } + ids.filter { !existing.contains($0) }
            }
        }
    }

    private func date(_ s: TimeSlot) -> Date {
        Calendar.current.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: Date()) ?? Date()
    }

    private func move(_ idx: Int, _ i: Int, _ d: Int) {
        let j = i + d
        guard j >= 0, j < app.playlists[idx].items.count else { return }
        app.playlists[idx].items.swapAt(i, j)
    }
}

struct ItemPickerSheet: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State var selected: Set<String>
    let onDone: ([String]) -> Void
    @State private var search = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Выберите обои").font(.headline)
                Spacer()
                TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(library.items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { it in
                        VStack(alignment: .leading) {
                            Thumbnail(item: it, version: library.thumbVersion)
                                .overlay(alignment: .topTrailing) {
                                    Image(systemName: selected.contains(it.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2).foregroundStyle(selected.contains(it.id) ? Color.accentColor : .white)
                                        .padding(6)
                                }
                            Text(it.title).font(.caption).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if selected.contains(it.id) { selected.remove(it.id) } else { selected.insert(it.id) } }
                    }
                }
            }
            HStack {
                Text("Выбрано: \(selected.count)").foregroundStyle(.secondary)
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Готово") {
                    onDone(library.items.map(\.id).filter { selected.contains($0) })
                    dismiss()
                }
                .buttonStyle(CrimsonButtonStyle())
            }
        }
        .padding(16)
        .frame(width: 720, height: 540)
    }
}
