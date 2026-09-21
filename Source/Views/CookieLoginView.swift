//
//  CookieLoginView.swift
//  ViviMusic
//
//  YouTube Music に Cookie でログインする画面。
//  ホーム / 検索 をアカウント付きで取得するために必要。
//
//  OAuth (GoogleAuthService) とは別物。あちらは再生用、こちらは閲覧用。
//
//  名乗り方 (User-Agent) と入口 (開始 URL) を画面から切り替えられる。
//  Google の埋め込みブラウザ判定は組み合わせ次第で通ったり通らなかったり
//  するため、ビルドし直さずに試せるようにしてある。
//

import SwiftUI
import WebKit

struct CookieLoginView: View {
    @EnvironmentObject private var auth: CookieAuthService
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable {
        case idle
        case browsing(String)
        case verifying
        case success(String)
        case failure(String)
    }

    /// 選択は次回も引き継ぐ。通った組み合わせを覚えておくため。
    @AppStorage("login.userAgent") private var userAgentRaw = LoginUserAgent.safariiPad.rawValue
    @AppStorage("login.entry") private var entryRaw = LoginEntry.musicHome.rawValue

    private var userAgent: LoginUserAgent {
        LoginUserAgent(rawValue: userAgentRaw) ?? .safariiPad
    }
    private var entry: LoginEntry {
        LoginEntry(rawValue: entryRaw) ?? .musicHome
    }

    @State private var phase: Phase = .idle
    @State private var showWebView = false
    /// WebView を作り直すための識別子。設定を変えたら作り直す。
    @State private var webViewToken = UUID()
    /// 手動で Cookie 取り込みを促すためのカウンタ。
    @State private var harvestRequest = 0

    var body: some View {
        NavigationStack {
            Group {
                if showWebView {
                    webViewArea
                } else {
                    setupArea
                }
            }
            .navigationTitle("YouTube Music にログイン")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
                if showWebView {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("中止") {
                            showWebView = false
                            phase = .idle
                        }
                    }
                }
            }
        }
    }

    // MARK: - WebView 表示中

    private var webViewArea: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if case .browsing(let host) = phase {
                    Text(host)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text("ログインが終わったら「取り込む」を押してください。"
                     + "自動で検出できた場合はそのまま進みます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    harvestRequest += 1
                } label: {
                    Label("取り込む", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            CookieLoginWebView(
                userAgent: userAgent.value,
                startURL: entry.url,
                harvestRequest: harvestRequest,
                onProgress: { host in
                    phase = .browsing(host)
                },
                onHarvest: { cookie, visitorData, dataSyncID in
                    Task { await complete(cookie: cookie,
                                          visitorData: visitorData,
                                          dataSyncID: dataSyncID) }
                }
            )
            .id(webViewToken)
        }
    }

    // MARK: - 開始前 / 結果表示

    private var setupArea: some View {
        Form {
            Section {
                resultRow
            }

            Section {
                Picker("入口", selection: $entryRaw) {
                    ForEach(LoginEntry.allCases) { item in
                        Text(item.title).tag(item.rawValue)
                    }
                }
                Text(entry.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("どこからログインするか")
            }

            Section {
                Picker("名乗り方", selection: $userAgentRaw) {
                    ForEach(LoginUserAgent.allCases) { item in
                        Text(item.title).tag(item.rawValue)
                    }
                }
                Text(userAgent.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("ブラウザの名乗り方 (User-Agent)")
            } footer: {
                Text("「ログインできませんでした / このブラウザまたはアプリは"
                     + "安全でない可能性があります」と出た場合は、"
                     + "リストの上から順に試してください。"
                     + "「既定」は Google のログインは通りますが、"
                     + "YouTube Music が「お使いのブラウザ向けに最適化されていません」"
                     + "を出して先へ進めません。")
            }

            Section {
                Button {
                    start()
                } label: {
                    Label(auth.isSignedIn ? "ログインし直す" : "ログインを開始",
                          systemImage: "arrow.right.circle")
                }

                if auth.isSignedIn {
                    Button(role: .destructive) {
                        auth.signOut()
                        phase = .idle
                    } label: {
                        Label("ログアウト",
                              systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultRow: some View {
        switch phase {
        case .verifying:
            HStack(spacing: 8) {
                ProgressView()
                Text("認証を確認しています…")
            }

        case .success(let name):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ログインしました").font(.headline)
                    Text(name).font(.subheadline).foregroundStyle(.secondary)
                    Text("設定を閉じるとホームが自動で読み直されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }

        case .failure(let message):
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("完了できませんでした").font(.headline)
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

        default:
            if auth.isSignedIn {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ログイン中").font(.headline)
                        if let name = auth.accountName {
                            Text(name).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Text("ホームや検索をアカウントに合わせて表示するには、"
                     + "YouTube Music にログインします。")
                    .font(.footnote)
            }
        }
    }

    // MARK: - 操作

    private func start() {
        webViewToken = UUID()
        harvestRequest = 0
        phase = .browsing("読み込み中…")
        showWebView = true
        EventLog.log(.auth,
                     message: "ログイン開始 (入口=\(entry.title) / UA=\(userAgent.title))")
    }

    @MainActor
    private func complete(cookie: String,
                          visitorData: String?,
                          dataSyncID: String?) async {
        showWebView = false
        phase = .verifying

        auth.apply(cookie: cookie, visitorData: visitorData, dataSyncID: dataSyncID)

        guard auth.isSignedIn else {
            phase = .failure("必要な Cookie (SAPISID) が取得できませんでした。"
                             + "ログインが最後まで完了していない可能性があります。")
            return
        }

        if let name = await auth.verify() {
            phase = .success(name)
        } else {
            phase = .failure("Cookie は取得できましたが、"
                             + "アカウント情報を確認できませんでした。"
                             + "診断ログを確認してください。")
        }
    }
}

// MARK: - WKWebView ラッパ

struct CookieLoginWebView: UIViewRepresentable {
    /// nil なら WKWebView 既定の UA をそのまま使う。
    var userAgent: String?
    var startURL: String
    /// 値が増えるたびに手動で Cookie 取り込みを試みる。
    var harvestRequest: Int

    var onProgress: (String) -> Void
    /// (cookie 文字列, visitorData, dataSyncID)
    var onHarvest: (String, String?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 永続ストアを使う。ここに入った Cookie を後で回収する。
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // nil のままにすると WKWebView 本来の UA が使われる。
        // 実際のエンジン (WebKit) と一致するので、偽装と判定されにくい。
        webView.customUserAgent = userAgent

        if let url = URL(string: startURL) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // 「取り込む」が押されたら手動で回収する。
        if harvestRequest != context.coordinator.lastHarvestRequest {
            context.coordinator.lastHarvestRequest = harvestRequest
            guard harvestRequest > 0 else { return }
            EventLog.log(.auth, message: "手動で Cookie の取り込みを実行")
            context.coordinator.attemptHarvest(webView: webView, requireSAPISID: false)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: CookieLoginWebView
        var lastHarvestRequest = 0
        /// 二重回収を防ぐ。
        private var finished = false

        init(_ parent: CookieLoginWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let host = webView.url?.host ?? "?"
            parent.onProgress(host)
            EventLog.log(.auth, message: "ログイン WebView: \(host) を表示")

            guard !finished else { return }
            guard webView.url?.host?.hasSuffix("youtube.com") == true else { return }

            // 自動判定。
            // SAPISID が入っていればログイン済みとみなして取り込む。
            //
            // 入口を music.youtube.com にした場合、最初の表示時点では
            // まだ未ログインなので、ここで取り込んでしまわないように
            // SAPISID の有無を条件にしている。
            attemptHarvest(webView: webView, requireSAPISID: true)
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            EventLog.logError(.auth, error: error, context: "ログイン WebView")
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            // 遷移のキャンセルは正常動作なので記録しない
            if (error as? URLError)?.code == .cancelled { return }
            EventLog.logError(.auth, error: error, context: "ログイン WebView (遷移)")
        }

        // MARK: - 回収

        /// Cookie を集め、条件を満たしていれば取り込む。
        /// - Parameter requireSAPISID: true なら SAPISID が無いときは何もしない
        ///   (自動判定用)。false なら取れたものをそのまま渡す (手動用)。
        func attemptHarvest(webView: WKWebView, requireSAPISID: Bool) {
            guard !finished else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                // youtube.com 向けの Cookie だけを対象にする。
                // (google.com 側の Cookie を混ぜると弾かれることがある)
                let relevant = cookies.filter { $0.domain.hasSuffix("youtube.com") }
                let names = Set(relevant.map(\.name))
                let hasSAPISID = names.contains("SAPISID")
                    || names.contains("__Secure-3PAPISID")
                    || names.contains("__Secure-1PAPISID")

                if requireSAPISID && !hasSAPISID {
                    // まだログインが終わっていない。黙って待つ。
                    return
                }

                EventLog.log(.auth,
                             message: "Cookie 候補 \(relevant.count) 個"
                                 + " (SAPISID \(hasSAPISID ? "あり" : "なし")): "
                                 + names.sorted().joined(separator: ", "))

                guard !relevant.isEmpty else {
                    EventLog.log(.auth, message: "youtube.com の Cookie が 1 つも無い")
                    return
                }

                self.finished = true
                let cookie = relevant.map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                self.readConfig(from: webView) { visitorData, dataSyncID in
                    self.parent.onHarvest(cookie, visitorData, dataSyncID)
                }
            }
        }

        /// `window.yt.config_` から VISITOR_DATA / DATASYNC_ID を読む。
        /// 本家は JavascriptInterface 経由で同じ値を取っている。
        /// 取れなくてもログイン自体は成立するので、失敗しても続行する。
        private func readConfig(from webView: WKWebView,
                                completion: @escaping (String?, String?) -> Void) {
            let js = """
            (function () {
              try {
                var c = (window.yt && window.yt.config_) ? window.yt.config_ : {};
                return JSON.stringify({
                  v: c.VISITOR_DATA || "",
                  d: c.DATASYNC_ID || ""
                });
              } catch (e) { return "{}"; }
            })();
            """
            webView.evaluateJavaScript(js) { result, error in
                if let error {
                    EventLog.log(.auth,
                                 message: "ytcfg の読み取りに失敗: \(error.localizedDescription)")
                    completion(nil, nil)
                    return
                }
                guard let text = result as? String,
                      let data = text.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data)
                        as? [String: String] else {
                    completion(nil, nil)
                    return
                }

                let visitorData = dict["v"].flatMap { $0.isEmpty ? nil : $0 }
                // "xxx||yyy" 形式で来ることがある。本家と同じく前半だけ使う。
                let dataSyncID = dict["d"]
                    .flatMap { $0.isEmpty ? nil : $0 }
                    .map { String($0.split(separator: "|").first ?? "") }
                    .flatMap { $0.isEmpty ? nil : $0 }

                EventLog.log(.auth,
                             message: "ytcfg: visitorData \(visitorData == nil ? "なし" : "あり")"
                                 + " / dataSyncId \(dataSyncID == nil ? "なし" : "あり")")
                completion(visitorData, dataSyncID)
            }
        }
    }
}
