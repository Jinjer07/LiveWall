import SwiftUI

struct WorkshopView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var steam: SteamService
    @EnvironmentObject var library: LibraryStore
    @State private var input = ""
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Мастерская", subtitle: "Wallpaper Engine из Steam") {
                Button { steam.scan() } label: { Label("Сканировать", systemImage: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle())
            }
            form
        }
        .onAppear { if steam.projects.isEmpty { steam.scan() } }
    }

    private var form: some View {
        Form {
            Section {
                Text("Обои из мастерской Wallpaper Engine (нужен купленный Wallpaper Engine на вашем аккаунте Steam). Поддерживаются типы **video** и **web** — вместе с их настройками. Тип **scene** использует закрытый формат и не поддерживается.")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("Папки мастерской") {
                    VStack(alignment: .trailing, spacing: 2) {
                        if steam.existingDirs.isEmpty { Text("не найдены").foregroundStyle(.secondary) }
                        ForEach(steam.existingDirs, id: \.self) { d in
                            Text(d.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                HStack {
                    Button("Указать папку вручную…") {
                        if let u = Panels.chooseFolder() { app.settings.steamWorkshopPath = u.path; steam.scan() }
                    }
                    Button("Сканировать") { steam.scan() }
                    Spacer()
                    if steam.projects.contains(where: { $0.supported && !steam.isImported($0) }) {
                        Button("Импортировать все поддерживаемые") { steam.importAllSupported() }
                            .buttonStyle(CrimsonButtonStyle())
                    }
                }
                if !steam.status.isEmpty {
                    Text(steam.status).font(.callout)
                }
            } header: { Text("Wallpaper Engine из Steam") }

            if !steam.projects.isEmpty {
                Section {
                    Toggle("Показывать неподдерживаемые", isOn: $showAll)
                    ForEach(steam.projects.filter { showAll || $0.supported }) { p in
                        HStack(spacing: 12) {
                            preview(p)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.title).lineLimit(1)
                                Text("\(p.type) · #\(p.workshopID)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if steam.isImported(p) {
                                Label("В библиотеке", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                            } else if p.supported {
                                Button("Импорт") { steam.importProject(p) }
                            } else {
                                Text("Не поддерживается").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Найдено в мастерской (\(steam.projects.count))") }
            }

            Section {
                TextField("Логин Steam", text: Binding(get: { app.settings.steamUser }, set: { app.settings.steamUser = $0 }))
                TextField("Путь к steamcmd (необязательно)",
                          text: Binding(get: { app.settings.steamcmdPath }, set: { app.settings.steamcmdPath = $0 }),
                          prompt: Text(steam.steamcmdPath() ?? "/opt/homebrew/bin/steamcmd"))
                LabeledContent("steamcmd") {
                    if let p = steam.steamcmdPath() { Text(p).foregroundStyle(.green).font(.caption) }
                    else { Text("не найден").foregroundStyle(.orange) }
                }
                HStack {
                    TextField("ID или ссылка на предмет мастерской", text: $input)
                        .onSubmit { steam.download(input) }
                    Button(steam.busy ? "Загрузка…" : "Скачать") { steam.download(input) }
                        .disabled(steam.busy || input.isEmpty)
                        .buttonStyle(CrimsonButtonStyle())
                }
                Button("Войти в steamcmd (откроется Терминал)") { steam.openLoginTerminal() }
                    .disabled(steam.steamcmdPath() == nil || app.settings.steamUser.isEmpty)
                if !steam.log.isEmpty {
                    ScrollView {
                        Text(steam.log)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 160)
                }
            } header: {
                Text("Скачать через steamcmd")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Установите steamcmd: `brew install --cask steamcmd` (или вручную с сайта Valve).")
                    Text("2. Укажите логин и нажмите «Войти в steamcmd» — в Терминале введите пароль и код Steam Guard. LiveWall пароль не видит и не хранит.")
                    Text("3. Вставьте ссылку вида steamcommunity.com/sharedfiles/filedetails/?id=… и нажмите «Скачать».")
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func preview(_ p: WEProjectInfo) -> some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let img = ThumbCache.image(for: p.preview) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 45)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
