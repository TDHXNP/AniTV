//
//  BangumiLANOAuthServer.swift
//  AniTV
//
//  Created by Codex on 2026/5/3.
//

import Foundation
import Network

final class BangumiLANOAuthServer: NSObject {
    struct Config {
        let clientID: String
        let clientSecret: String
        let redirectURI: String
        let localEndpoint: String
        let port: UInt16
    }

    private let config: Config
    private let queue = DispatchQueue(label: "xyz.moyuwang.AniTV.lan-oauth")
    private let onStatusChange: @Sendable (String) -> Void
    private let onAuthorizationCode: @Sendable (String, String) -> Void

    private var listener: NWListener?
    private var pendingSessions: [String: PendingSession] = [:]
    private let stateLock = NSLock()
    private var _isRunning = false

    private static let pendingSessionTTL: TimeInterval = 15 * 60
    private static let maxPendingSessions = 20

    private struct PendingSession {
        let sessionID: String
        let nonce: String
        let state: String
        let createdAt: Date
    }

    var isRunning: Bool {
        stateLock.withLock { _isRunning }
    }

    var localEndpoint: String {
        config.localEndpoint
    }

    var redirectURI: String {
        config.redirectURI
    }

    init(
        config: Config,
        onStatusChange: @escaping @Sendable (String) -> Void,
        onAuthorizationCode: @escaping @Sendable (String, String) -> Void
    ) {
        self.config = config
        self.onStatusChange = onStatusChange
        self.onAuthorizationCode = onAuthorizationCode
        super.init()
    }

    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.stateUpdateHandler = nil
            self.listener?.newConnectionHandler = nil
            self.listener?.cancel()
            self.listener = nil
            self.setRunning(false)
        }
    }

    private func setRunning(_ running: Bool) {
        stateLock.withLock { _isRunning = running }
    }

    private func startOnQueue() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: config.port))
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.setRunning(true)
                    self.onStatusChange("局域网登录服务已启动：\(self.config.localEndpoint)")
                case .failed(let error):
                    self.setRunning(false)
                    self.onStatusChange("局域网登录服务启动失败：\(error.localizedDescription)")
                case .cancelled:
                    self.setRunning(false)
                    self.onStatusChange("局域网登录服务已停止。")
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }

            listener.start(queue: queue)
        } catch {
            setRunning(false)
            onStatusChange("局域网登录服务启动失败：\(error.localizedDescription)")
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let response = self.makeResponse(for: data)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func makeResponse(for data: Data?) -> Data {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let firstLine = request.split(separator: "\r\n").first else {
            return httpResponse(status: "400 Bad Request", body: "Bad Request")
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            return httpResponse(status: "400 Bad Request", body: "Bad Request")
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        guard let components = URLComponents(string: "http://localhost\(target)") else {
            return httpResponse(status: "400 Bad Request", body: "Bad Request")
        }

        switch (method, components.path) {
        case ("OPTIONS", _):
            return optionsResponse()
        case ("GET", "/oauth/bangumi/start"):
            return handleStart()
        case ("GET", "/oauth/bangumi/code"):
            return handleCodeRelay(components: components)
        case ("GET", "/oauth/bangumi"):
            return handleLocalCallbackFallback(components: components)
        default:
            if method != "GET" {
                return httpResponse(status: "405 Method Not Allowed", body: "Method Not Allowed")
            }
            return htmlResponse(
                status: "200 OK",
                body: """
                <html><body style="font-family:-apple-system;padding:24px;background:#111;color:#fff;">
                <h1>AniTV 局域网登录服务</h1>
                <p>Bangumi 回调地址：\(config.redirectURI)</p>
                <p>电视本地入口：\(config.localEndpoint)/oauth/bangumi/start</p>
                </body></html>
                """
            )
        }
    }

    private func pruneExpiredPendingSessions(now: Date = Date()) {
        pendingSessions = pendingSessions.filter { _, session in
            now.timeIntervalSince(session.createdAt) <= Self.pendingSessionTTL
        }
        if pendingSessions.count > Self.maxPendingSessions {
            let sortedKeys = pendingSessions
                .sorted { $0.value.createdAt < $1.value.createdAt }
                .prefix(pendingSessions.count - Self.maxPendingSessions)
                .map(\.key)
            for key in sortedKeys {
                pendingSessions.removeValue(forKey: key)
            }
        }
    }

    private func handleStart() -> Data {
        guard !config.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !config.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return htmlResponse(
                status: "500 Internal Server Error",
                body: "<html><body style=\"font-family:-apple-system;padding:24px;background:#111;color:#fff;\"><h1>Bangumi 配置缺失</h1><p>当前应用未配置 Bangumi OAuth client_id 或 client_secret。</p></body></html>"
            )
        }

        let sessionID = UUID().uuidString
        let nonce = UUID().uuidString

        guard let state = BangumiOAuthManager.makeLANState(
            tvEndpoint: config.localEndpoint,
            sessionID: sessionID,
            nonce: nonce
        ) else {
            return htmlResponse(
                status: "500 Internal Server Error",
                body: "<html><body>Failed to encode AniTV LAN OAuth state.</body></html>"
            )
        }

        let now = Date()
        pruneExpiredPendingSessions(now: now)
        pendingSessions[state] = PendingSession(
            sessionID: sessionID,
            nonce: nonce,
            state: state,
            createdAt: now
        )

        guard !config.redirectURI.isEmpty else {
            return htmlResponse(
                status: "500 Internal Server Error",
                body: "<html><body>电视当前未生成可用的 Bangumi 回调地址。</body></html>"
            )
        }

        guard let authorizationURL = BangumiOAuthManager.makeAuthorizationURL(
            clientID: config.clientID,
            redirectURI: config.redirectURI,
            state: state
        ) else {
            return htmlResponse(
                status: "500 Internal Server Error",
                body: "<html><body>Failed to build Bangumi authorization URL.</body></html>"
            )
        }

        let escapedAuthURL = authorizationURL.absoluteString.replacingOccurrences(of: "&", with: "&amp;")

        return htmlResponse(
            status: "200 OK",
            body: """
            <html>
            <head>
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px; background: #111827; color: #f9fafb; }
            .card { max-width: 560px; margin: 0 auto; background: #1f2937; border-radius: 20px; padding: 28px; }
            a.button { display: inline-block; margin-top: 20px; padding: 14px 18px; border-radius: 12px; background: #2563eb; color: #fff; text-decoration: none; font-weight: 600; }
            code { color: #93c5fd; word-break: break-all; }
            </style>
            </head>
            <body>
            <div class="card">
            <h1>连接 Bangumi 到 AniTV</h1>
            <p>点击下面的按钮后，会跳转到 Bangumi 官方授权页；如果授权后电视没有响应，请扫码重试或使用Apple设备登录按钮登录。</p>
            <p>建议使用原生相机App扫码打开或在默认浏览器中打开</p>
            <a class="button" href="\(escapedAuthURL)">继续前往 Bangumi 登录</a>
            </div>
            </body>
            </html>
            """
        )
    }

    private func handleLocalCallbackFallback(components: URLComponents) -> Data {
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value

        guard let code, !code.isEmpty else {
            return htmlResponse(
                status: "400 Bad Request",
                body: "<html><body>Bangumi callback missing code.</body></html>"
            )
        }

        pruneExpiredPendingSessions()
        guard let returnedState,
              pendingSessions.removeValue(forKey: returnedState) != nil else {
            return htmlResponse(
                status: "400 Bad Request",
                body: "<html><body>Bangumi callback state mismatch.</body></html>"
            )
        }

        let stableCode = String(code)
        let stableRedirectURI = String(config.redirectURI)

        onAuthorizationCode(stableCode, stableRedirectURI)

        return htmlResponse(
            status: "200 OK",
            body: """
            <html>
            <body style="font-family:-apple-system;padding:24px;background:#111;color:#fff;">
            <h1>Bangumi 授权已完成</h1>
            <p>你可以回到 AniTV 查看登录结果。</p>
            </body>
            </html>
            """
        )
    }

    private func handleCodeRelay(components: URLComponents) -> Data {
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        let sessionID = components.queryItems?.first(where: { $0.name == "sessionId" })?.value
        let nonce = components.queryItems?.first(where: { $0.name == "nonce" })?.value

        guard let code, !code.isEmpty,
              let state, !state.isEmpty else {
            return htmlResponse(
                status: "400 Bad Request",
                body: """
                <html><body style="font-family:-apple-system;padding:24px;background:#111;color:#fff;">
                <h1>AniTV 登录失败</h1>
                <p>缺少 code 或 state。</p>
                </body></html>
                """
            )
        }

        pruneExpiredPendingSessions()
        guard !pendingSessions.isEmpty else {
            return htmlResponse(
                status: "409 Conflict",
                body: """
                <html><body style="font-family:-apple-system;padding:24px;background:#111;color:#fff;">
                <h1>AniTV 登录失败</h1>
                <p>电视端当前没有待处理的登录会话。</p>
                </body></html>
                """
            )
        }

        guard let pendingSession = pendingSessions[state],
              sessionID == pendingSession.sessionID,
              nonce == pendingSession.nonce else {
            return htmlResponse(
                status: "400 Bad Request",
                body: """
                <html><body style="font-family:-apple-system;padding:24px;background:#111;color:#fff;">
                <h1>AniTV 登录失败</h1>
                <p>登录会话校验失败。</p>
                </body></html>
                """
            )
        }

        pendingSessions.removeValue(forKey: state)
        let stableCode = String(code)
        let stableRedirectURI = String(config.redirectURI)

        onAuthorizationCode(stableCode, stableRedirectURI)

        return htmlResponse(
            status: "200 OK",
            body: """
            <html><body style="font-family:-apple-system;padding:24px;background:#111;color:#fff;">
            <h1>授权结果已发送到 AniTV</h1>
            <p>电视已收到 Bangumi code，正在交换 access token。</p>
            <p>现在可以回到电视继续。</p>
            </body></html>
            """
        )
    }

    private func htmlResponse(status: String, body: String) -> Data {
        httpResponse(
            status: status,
            headers: [
                "Content-Type: text/html; charset=utf-8",
                "Content-Length: \(body.utf8.count)"
            ],
            body: body
        )
    }

    private func optionsResponse() -> Data {
        httpResponse(
            status: "204 No Content",
            headers: [
                "Access-Control-Allow-Origin: *",
                "Access-Control-Allow-Methods: GET, OPTIONS",
                "Access-Control-Allow-Headers: Content-Type",
                "Content-Length: 0"
            ],
            body: ""
        )
    }

    private func httpResponse(status: String, headers: [String] = [], body: String) -> Data {
        let response = ([
            "HTTP/1.1 \(status)",
            "Connection: close"
        ] + headers + ["", body]).joined(separator: "\r\n")
        return Data(response.utf8)
    }
}
