import AppKit
import WebKit

@MainActor
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

@MainActor
enum WebViewFactory {
    static func make(handler: WKScriptMessageHandler) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let uc = WKUserContentController()
        uc.addUserScript(WKUserScript(source: RuntimeFiles.bridge.replacingOccurrences(of: "__LANG__", with: Loc.lang),
                                      injectionTime: .atDocumentStart, forMainFrameOnly: false))
        uc.add(WeakScriptHandler(handler), name: "lw")
        cfg.userContentController = uc
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 450), configuration: cfg)
        // Непрозрачный WebView: WindowServer не смешивает слой с тем, что под ним.
        wv.setValue(true, forKey: "drawsBackground")
        wv.underPageBackgroundColor = .black
        wv.wantsLayer = true
        wv.layer?.isOpaque = true
        wv.layer?.backgroundColor = NSColor.black.cgColor
        wv.allowsBackForwardNavigationGestures = false
        wv.allowsMagnification = false
        if #available(macOS 13.3, *) { wv.isInspectable = true }
        return wv
    }
}

/// Рендерер на WKWebView: веб-обои (совместимые с Wallpaper Engine), GLSL-шейдеры, сцены и медиа (webm/gif).
@MainActor
final class WebRenderer: NSObject, WallpaperRenderer, WKNavigationDelegate, WKScriptMessageHandler {
    enum Mode { case web, shader, scene, media(String) }

    private(set) var webView: WKWebView!
    var view: NSView { webView }
    var onError: ((String) -> Void)?

    private let item: WallpaperItem
    private let mode: Mode
    private var loaded = false
    private var pending: [String] = []
    private var paused = false
    private var stopped = false

    init(item: WallpaperItem, mode: Mode) {
        self.item = item
        self.mode = mode
        super.init()
        webView = WebViewFactory.make(handler: self)
        webView.navigationDelegate = self
    }

    private var rootAccess: URL { URL(fileURLWithPath: "/", isDirectory: true) }

    func start() {
        loaded = false
        switch mode {
        case .web:
            // Доступ на чтение шире папки проекта: пресеты WE ссылаются на файлы в соседних папках мастерской
            webView.loadFileURL(item.entryURL, allowingReadAccessTo: item.source == .steam ? item.folderURL.deletingLastPathComponent() : item.folderURL)
        case .shader:
            webView.loadFileURL(Paths.runtime.appendingPathComponent("shader.html"), allowingReadAccessTo: rootAccess)
        case .scene:
            webView.loadFileURL(Paths.runtime.appendingPathComponent("scene.html"), allowingReadAccessTo: rootAccess)
        case .media:
            webView.loadFileURL(Paths.runtime.appendingPathComponent("media.html"), allowingReadAccessTo: rootAccess)
        }
    }

    private var initScript: String? {
        switch mode {
        case .web:
            return nil
        case .shader:
            let src = (try? String(contentsOf: item.entryURL, encoding: .utf8)) ?? ""
            return "__lwSetShader(\(jsString(src)))"
        case .scene:
            let json = (try? String(contentsOf: item.entryURL, encoding: .utf8)) ?? "{}"
            return "__lwLoadScene(\(json), \(jsString(item.folderURL.absoluteString)), false)"
        case .media(let kind):
            let fill = item.properties.value("fill")?.string ?? "fill"
            let fit = ["fill": "cover", "fit": "contain", "stretch": "fill"][fill] ?? "cover"
            return "__lwSetMedia({kind:\(jsString(kind)),url:\(jsString(item.entryURL.absoluteString)),fit:\(jsString(fit))})"
        }
    }

    func js(_ s: String) {
        guard !stopped else { return }
        if loaded { webView.evaluateJavaScript(s, completionHandler: nil) } else { pending.append(s) }
    }

    func stop() {
        stopped = true
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.loadHTMLString("", baseURL: nil)
    }

    func setPaused(_ p: Bool) {
        paused = p
        js("__lwPause(\(p))")
    }

    func setVolume(_ v: Float) { js("__lwVolume(\(v))") }
    func setFPS(_ fps: Int) { js("__lwFPS(\(fps))") }
    func applyProperties(_ props: [WallpaperProperty]) { js("__lwProps(\(props.jsonForJS))") }
    func setInfo(_ json: String) { js("__lwInfo(\(json))") }
    func setAmbient(_ json: String) { js("__lwAmbient(\(json))") }

    func updateAudio(_ s: [Float]) {
        guard loaded, !paused, !stopped else { return }
        let arr = s.map { String(format: "%.3f", $0) }.joined(separator: ",")
        webView.evaluateJavaScript("__lwAudio([\(arr)])", completionHandler: nil)
    }

    func mouse(_ kind: MouseKind, _ p: CGPoint) {
        guard loaded else { return }
        let t: String
        switch kind {
        case .move: t = "mousemove"
        case .down: t = "mousedown"
        case .up: t = "mouseup"
        }
        webView.evaluateJavaScript("__lwMouse('\(t)',\(Int(p.x)),\(Int(p.y)))", completionHandler: nil)
    }

    func snapshot(_ done: @escaping (NSImage?) -> Void) {
        switch mode {
        case .shader, .scene:
            canvasSnapshot(webView, done)
        default: webView.takeSnapshot(with: nil) { img, _ in done(img) }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !stopped, !loaded else { return }
        loaded = true
        if let s = initScript { webView.evaluateJavaScript(s, completionHandler: nil) }
        let p = pending
        pending.removeAll()
        for s in p { webView.evaluateJavaScript(s, completionHandler: nil) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onError?(tr("Ошибка загрузки: %@", error.localizedDescription))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onError?(tr("Ошибка загрузки: %@", error.localizedDescription))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !stopped else { return }
        start()
        js("__lwPause(\(paused))")
    }

    // MARK: Сообщения из JS

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        if type == "error", let msg = body["message"] as? String { onError?(msg) }
    }
}

/// Снимок WebGL-canvas (takeSnapshot у WKWebView не захватывает WebGL).
@MainActor
func canvasSnapshot(_ webView: WKWebView, _ done: @escaping (NSImage?) -> Void) {
    webView.evaluateJavaScript("(function(){if(window.__lwSnapshot)return __lwSnapshot();var c=document.getElementById('c');return c?c.toDataURL('image/jpeg',0.85):null})()") { res, _ in
        MainActor.assumeIsolated {
            if let s = res as? String, let comma = s.firstIndex(of: ","),
               let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
               let img = NSImage(data: data), img.size.width > 1 {
                done(img)
            } else {
                webView.takeSnapshot(with: nil) { img, _ in done(img) }
            }
        }
    }
}
