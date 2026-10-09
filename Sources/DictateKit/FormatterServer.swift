import Foundation

/// 整形サーバの子プロセス。アプリが起動したものだけを持ち、止めるのもそれだけ。
/// 出力はログに残し、起動の失敗はログで確かめられるようにする。
@MainActor
public final class FormatterServer {
    public enum State: Sendable, Equatable {
        case stopped
        case starting(since: Date)
        case running
        /// 自分から終わった、または待ち受けが開かなかった。文は「サーバの起動に失敗（終了コード 1）」のように、メニューにそのまま出せる形。
        case failed(String)
    }

    public private(set) var state = State.stopped
    public let logURL: URL
    /// 子が自分から終わったときに呼ぶ。引数は新しい状態（`.failed`）。
    public var onExit: ((State) -> Void)?
    private var process: Process?

    public init(logURL: URL) {
        self.logURL = logURL
    }

    /// 監視シェルの pid。サーバ本体はその子になる。
    public var processIdentifier: Int32? { process?.processIdentifier }

    /// ログインシェル（.zprofile の PATH）で起動する。ログは起動のたびに作り直す。
    /// 起動中か動作中なら何もせず false を返す。
    ///
    /// シェルはコマンドを背景で動かし、アプリ（親）の pid が消えたら自分のプロセスグループごと止まる。
    /// `applicationWillTerminate` はシグナルで落ちたときには呼ばれず、サーバだけが残るため。
    /// `stop()` の方は Foundation がプロセスグループ全体に TERM を送るので、シェル側の処理は要らない。
    @discardableResult
    public func start(command: String) throws -> Bool {
        if process != nil { return false }
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: logURL.path, contents: Data("$ \(command)\n".utf8)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logURL.path])
        }
        let log = try FileHandle(forWritingTo: logURL)
        log.seekToEndOfFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // コマンドはスクリプトに埋め込まず環境変数で渡す（末尾のコメントや引用符でスクリプトが壊れない）
        var environment = ProcessInfo.processInfo.environment
        environment["DICTATE_START_COMMAND"] = command
        process.environment = environment
        process.arguments = ["-lc", """
            eval "$DICTATE_START_COMMAND" &
            child=$!
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 0.2; done
            if kill -0 $child 2>/dev/null; then kill -TERM -- -$$; fi
            wait $child
            """]
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] process in
            let pid = process.processIdentifier
            let status = process.terminationStatus
            Task { @MainActor in self?.exited(pid: pid, status: status) }
        }
        try process.run()
        self.process = process
        state = .starting(since: Date())
        return true
    }

    private func exited(pid: Int32, status: Int32) {
        guard process?.processIdentifier == pid else { return }  // stop() で止めたものは失敗にしない
        process = nil
        let code = status >= 128 ? "シグナル \(status - 128)" : "終了コード \(status)"
        state = .failed(state == .running ? "サーバが動作中に終了（\(code)）" : "サーバの起動に失敗（\(code)）")
        onExit?(state)
    }

    /// 接続できたことを呼び手が確かめてから呼ぶ。
    public func markRunning() {
        if case .starting = state { state = .running }
    }

    /// 待ち受けが開かないまま諦めるときに呼ぶ。止めてから失敗として残す。
    public func fail(_ reason: String) {
        stop()
        state = .failed(reason)
    }

    /// プロセスグループごと終了を求める。
    public func stop() {
        state = .stopped
        guard let process else { return }
        self.process = nil
        process.terminate()
    }
}
