import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var engine: WallpaperEngine
    @EnvironmentObject var library: LibraryStore

    private func b<T>(_ kp: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { app.settings[keyPath: kp] }, set: { app.settings[keyPath: kp] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Настройки", subtitle: "Производительность, звук, мониторы и система")
            form
        }
    }

    private var form: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    LogoMark(size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("LiveWall 1.0").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                        Text("Живые обои для macOS").font(.system(size: 12)).foregroundStyle(Theme.text2)
                    }
                    Spacer()
                    Button { app.overlay = .onboarding } label: { Label("Гайд", systemImage: "sparkles") }
                        .buttonStyle(GhostButtonStyle(compact: true))
                    Button { app.overlay = .tos } label: { Label("Условия", systemImage: "doc.text") }
                        .buttonStyle(GhostButtonStyle(compact: true))
                    Button { app.overlay = .credits } label: { Label("Титры", systemImage: "film.stack") }
                        .buttonStyle(CrimsonButtonStyle())
                }
                .padding(.vertical, 4)
                Toggle("Показывать заставку при запуске", isOn: b(\.showSplash))
            }

            Section("Производительность") {
                Picker("Ограничение FPS", selection: b(\.fpsLimit)) {
                    ForEach([10, 15, 24, 30, 60, 120], id: \.self) { Text($0 == 15 ? "15 кадров/с (экономно)" : "\($0) кадров/с").tag($0) }
                }
                Toggle("Пауза, когда приложение открыто на весь экран", isOn: b(\.pauseOnFullscreen))
                Toggle("Пауза, когда окно развёрнуто почти на весь экран", isOn: b(\.pauseOnMaximized))
                Toggle("Пауза, когда рабочий стол закрыт окнами (экономия CPU)", isOn: b(\.pauseWhenCovered))
                Toggle("Пауза при работе от батареи", isOn: b(\.pauseOnBattery))
                Toggle("Пауза при блокировке экрана и сне дисплея", isOn: b(\.pauseOnLock))
                Toggle("Пауза всех обоев", isOn: $engine.userPaused)
            }

            Section("Звук обоев") {
                Toggle("Без звука", isOn: b(\.muted))
                SliderRow(title: "Громкость", value: b(\.volume), range: 0...1, format: "%.2f")
                    .disabled(app.settings.muted)
                Text("Звук воспроизводится только с основного монитора.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Обои реагируют на системный звук", isOn: b(\.audioReactive))
                LabeledContent("Состояние") { Text(app.audioStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                Button("Открыть настройки конфиденциальности") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            } header: {
                Text("Аудио-визуализация")
            } footer: {
                Text("Для захвата системного звука macOS требует разрешение «Запись экрана и системного звука». Видео при этом не записывается. Спектр доступен веб-обоям (wallpaperRegisterAudioListener), шейдерам (iAudio, iSpectrum) и сценам.")
            }

            Section("Интерактивность") {
                Toggle("Обои реагируют на движение мыши (параллакс, эффекты)", isOn: b(\.mouseInteraction))
                Toggle("Передавать клики по рабочему столу в обои", isOn: b(\.clickInteraction))
            }

            Section("Мониторы") {
                Toggle("Растянуть одни обои на все мониторы", isOn: b(\.spanMode))
                ForEach(engine.screens) { s in
                    LabeledContent(s.name) {
                        Text(library.item(engine.desiredItem(for: s.key))?.title ?? "—").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Система") {
                Toggle("Запускать при входе в систему", isOn: b(\.launchAtLogin))
                if Bundle.main.bundlePath.hasSuffix(".app") == false {
                    Text("Автозапуск работает только для собранного LiveWall.app.").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("Открыть папку данных") { NSWorkspace.shared.open(Paths.root) }.buttonStyle(GhostButtonStyle(compact: true))
                    Button("Добавить примеры заново") { Samples.install(into: library) }.buttonStyle(GhostButtonStyle(compact: true))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .toggleStyle(CrimsonToggleStyle())
    }
}
