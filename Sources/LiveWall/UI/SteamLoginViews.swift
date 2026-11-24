import SwiftUI
import WebKit

/// Карточка аккаунта Steam в разделе «Мастерская».
struct SteamAccountCard: View {
    @ObservedObject var account = AppState.shared.steamAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.panelHi).frame(width: 46, height: 46)
                    Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.scarlet)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                Spacer()
                actions
            }
            syncStatus
        }
        .panel(radius: 14, padding: 14)
        .onAppear { if account.session == .unknown { account.checkSession() } }
        .sheet(isPresented: $account.showLogin) { SteamLoginSheet() }
        .sheet(isPresented: $account.showWebLogin) { SteamWebLoginSheet() }
    }

    private var icon: String {
        if !account.installed { return "arrow.down.app" }
        switch account.session {
        case .signedIn: return "person.crop.circle.badge.checkmark"
        case .checking, .unknown: return "hourglass"
        case .signedOut: return "person.crop.circle.badge.questionmark"
        }
    }

    private var title: String {
        if !account.installed { return tr("Нужен steamcmd") }
        switch account.session {
        case .signedIn(let u): return tr("Вход выполнен: %@", u)
        case .checking, .unknown: return tr("Проверяем вход…")
        case .signedOut: return tr("Вход в Steam не выполнен")
        }
    }

    private var subtitle: String {
        if !account.installed { return tr("Официальная утилита Valve для загрузки из мастерской. Установится в папку LiveWall.") }
        switch account.session {
        case .signedIn: return tr("Синхронизация скачает новые подписки Wallpaper Engine и добавит их в плейлист.")
        default: return tr("Войдите один раз — пароль уходит только в официальный steamcmd и не сохраняется.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if !account.installed {
            Button { account.installSteamCMD() } label: {
                if account.sync == .installing { ProgressView().controlSize(.small).frame(width: 80) }
                else { Label(tr("Установить"), systemImage: "arrow.down.circle.fill") }
            }
            .buttonStyle(CrimsonButtonStyle())
            .disabled(account.sync == .installing)
        } else {
            switch account.session {
            case .signedIn:
                HStack(spacing: 8) {
                    Button(tr("Выйти")) { account.signOut() }.buttonStyle(GhostButtonStyle(compact: true))
                    Button { account.startSync() } label: { Label(tr("Синхронизировать мастерскую"), systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(CrimsonButtonStyle())
                        .disabled(isSyncing)
                }
            case .signedOut:
                Button { account.showLogin = true } label: { Label(tr("Войти в Steam"), systemImage: "person.fill") }
                    .buttonStyle(CrimsonButtonStyle())
            default:
                ProgressView().controlSize(.small)
            }
        }
    }

    private var isSyncing: Bool {
        switch account.sync { case .fetching, .downloading, .importing, .installing: return true; default: return false }
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch account.sync {
        case .idle: EmptyView()
        case .installing: progress(tr("Устанавливаем steamcmd…"), nil)
        case .fetching: progress(tr("Получаем список подписок…"), nil)
        case .downloading(let d, let t): progress(tr("Скачиваем: %@ из %@", d, t), t > 0 ? Double(d) / Double(t) : nil)
        case .importing: progress(tr("Конвертируем и добавляем в библиотеку…"), nil)
        case .done(let n):
            Label(n > 0 ? tr("Готово: добавлено %@", n) : tr("Всё синхронизировано — новых подписок нет"), systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(Theme.text2)
        case .failed(let e):
            Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.scarlet)
        }
    }

    private func progress(_ text: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.callout).foregroundStyle(Theme.text2)
            if let value { ProgressView(value: value).tint(Theme.crimson) } else { ProgressView().progressViewStyle(.linear).tint(Theme.crimson) }
        }
    }
}

/// Окно входа: логин/пароль → подтверждение в Steam Mobile или код Steam Guard.
struct SteamLoginSheet: View {
    @ObservedObject var account = AppState.shared.steamAccount
    @Environment(\.dismiss) private var dismiss
    @State private var user = AppState.shared.settings.steamUser
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 26)).foregroundStyle(Theme.redGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Вход в Steam")).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text)
                    Text(tr("Нужен аккаунт, на котором куплен Wallpaper Engine")).font(.caption).foregroundStyle(Theme.text2)
                }
                Spacer()
            }

            switch account.login {
            case .waitingMobile:
                VStack(spacing: 12) {
                    Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 46)).foregroundStyle(Theme.scarlet)
                        .symbolEffect(.pulse)
                    Text(tr("Подтвердите вход в приложении Steam Mobile на телефоне")).font(.headline).foregroundStyle(Theme.text)
                        .multilineTextAlignment(.center)
                    ProgressView().controlSize(.small)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            case .needsCode(let kind):
                VStack(alignment: .leading, spacing: 8) {
                    Text(kind).foregroundStyle(Theme.text)
                    TextField("XXXXX", text: $code).textFieldStyle(.roundedBorder).font(.system(size: 20, design: .monospaced))
                        .onSubmit { account.submitCode(code) }
                    Button(tr("Подтвердить")) { account.submitCode(code) }.buttonStyle(CrimsonButtonStyle()).disabled(code.count < 4)
                }
            case .success:
                Label(tr("Вход выполнен"), systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Theme.scarlet)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
            default:
                VStack(spacing: 10) {
                    TextField(tr("Имя аккаунта Steam (не e-mail)"), text: $user).textFieldStyle(.roundedBorder)
                    SecureField(tr("Пароль"), text: $password).textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }
                    if case .failed(let e) = account.login {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.scarlet)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(tr("Пароль передаётся только официальной утилите Valve steamcmd и нигде не сохраняется. Вход запоминает сам steamcmd."))
                        .font(.caption).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Button(tr("Отмена")) { account.cancelLogin(); dismiss() }.buttonStyle(GhostButtonStyle())
                Spacer()
                if account.login == .connecting {
                    ProgressView().controlSize(.small)
                } else if case .needsCode = account.login {
                } else if account.login != .waitingMobile && account.login != .success {
                    Button(tr("Войти")) { submit() }
                        .buttonStyle(CrimsonButtonStyle(large: true))
                        .disabled(user.isEmpty || password.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .animation(Theme.spring, value: account.login)
    }

    private func submit() {
        guard !user.isEmpty, !password.isEmpty else { return }
        account.signIn(user: user, password: password)
        password = ""
    }
}

/// Встроенное окно steamcommunity.com: вход по QR или паролем, чтобы читать список подписок.
struct SteamWebLoginSheet: View {
    @ObservedObject var account = AppState.shared.steamAccount
    @Environment(\.dismiss) private var dismiss
    @State private var loggedIn = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("Вход на steamcommunity.com")).font(.headline).foregroundStyle(Theme.text)
                    Text(tr("Нужен один раз, чтобы видеть ваши подписки. Можно войти по QR-коду из Steam Mobile."))
                        .font(.caption).foregroundStyle(Theme.text2)
                }
                Spacer()
                Button(tr("Закрыть")) { dismiss() }.buttonStyle(GhostButtonStyle(compact: true))
            }
            .padding(14)
            SteamWebView(web: account.web) { onSubs in
                if onSubs && !loggedIn {
                    loggedIn = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        dismiss()
                        account.startSync()
                    }
                }
            }
        }
        .frame(width: 900, height: 700)
        .background(Theme.bg)
    }
}

struct SteamWebView: NSViewRepresentable {
    let web: SteamWeb
    let onNavigate: (Bool) -> Void

    final class Coordinator: NSObject {
        var obs: NSKeyValueObservation?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = web.webView
        wv.load(URLRequest(url: SteamWeb.loginURL))
        context.coordinator.obs = wv.observe(\.url, options: [.new]) { v, _ in
            let onSubs = v.url?.absoluteString.contains("myworkshopfiles") ?? false
            DispatchQueue.main.async { onNavigate(onSubs) }
        }
        return wv
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
