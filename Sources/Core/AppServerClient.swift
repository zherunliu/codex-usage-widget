import Foundation

actor AppServerClient {
    enum ClientError: LocalizedError {
        case notRunning
        case requestTimedOut(String)
        case processExited(Int32)
        case invalidResponse
        case remote(code: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notRunning:
                return "Codex App Server is not running."
            case .requestTimedOut(let method):
                return "Codex request timed out: \(method)"
            case .processExited(let status):
                return "Codex App Server exited with status \(status)."
            case .invalidResponse:
                return "Codex returned an unrecognized response."
            case .remote(_, let message):
                return message
            }
        }
    }

    struct InitializeResult: Decodable {
        let userAgent: String?
    }

    private struct InitializeParams: Encodable {
        struct ClientInfo: Encodable {
            let name: String
            let title: String
            let version: String
        }

        let clientInfo: ClientInfo
    }

    private struct EmptyParams: Encodable {}

    private struct RPCErrorPayload: Decodable {
        let code: Int
        let message: String
    }

    private struct RPCResponse<Result: Decodable>: Decodable {
        let id: Int
        let result: Result?
        let error: RPCErrorPayload?
    }

    private struct RPCRequest<Params: Encodable>: Encodable {
        let method: String
        let id: Int
        let params: Params?
    }

    private struct RPCNotification<Params: Encodable>: Encodable {
        let method: String
        let params: Params
    }

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var notificationHandler: (@Sendable (String) -> Void)?
    private var recentOutputLines: [String] = []
    private var recentInputLines: [String] = []
    private var isStoppingIntentionally = false

    let executableURL: URL
    private(set) var lastStandardError = ""

    init(executableURL: URL) {
        self.executableURL = executableURL
    }

    func setNotificationHandler(_ handler: (@Sendable (String) -> Void)?) {
        notificationHandler = handler
    }

    func diagnostics() -> String {
        let input = recentInputLines.suffix(12).joined(separator: "\n")
        let stdout = recentOutputLines.suffix(12).joined(separator: "\n")
        return "stdin:\n\(input)\n\nstdout:\n\(stdout)\n\nstderr:\n\(lastStandardError)"
    }

    func start() async throws {
        if process?.isRunning == true { return }
        isStoppingIntentionally = false

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task {
                await self?.consumeOutput(data)
            }
        }

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task {
                await self?.appendStandardError(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task {
                await self?.handleTermination(status: process.terminationStatus)
            }
        }

        try process.run()
        self.process = process
        inputPipe = input
        outputPipe = output
        errorPipe = error

        let params = InitializeParams(
            clientInfo: .init(
                name: "codex_usage_widget",
                title: "Codex Usage Widget",
                version: "0.1.0"
            )
        )
        let _: InitializeResult = try await request(
            method: "initialize",
            params: params,
            as: InitializeResult.self
        )
        try sendNotification(method: "initialized", params: EmptyParams())
    }

    func stop() {
        isStoppingIntentionally = true
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
        outputBuffer.removeAll(keepingCapacity: false)

        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        inputPipe = nil
        failPending(with: ClientError.notRunning)
    }

    func request<Result: Decodable>(
        method: String,
        as resultType: Result.Type
    ) async throws -> Result {
        try await request(
            method: method,
            params: Optional<EmptyParams>.none,
            as: resultType
        )
    }

    func request<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params?,
        as resultType: Result.Type
    ) async throws -> Result {
        guard process?.isRunning == true, let inputPipe else {
            throw ClientError.notRunning
        }

        let id = nextRequestID
        nextRequestID += 1
        let request = RPCRequest(method: method, id: id, params: params)
        var requestData = try JSONEncoder().encode(request)
        rememberInput(requestData)
        requestData.append(0x0A)

        let responseData: Data = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                await self?.timeoutRequest(id: id, method: method)
            }

            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: requestData)
            } catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }

        let response = try JSONDecoder().decode(RPCResponse<Result>.self, from: responseData)
        if let error = response.error {
            throw ClientError.remote(code: error.code, message: error.message)
        }
        guard let result = response.result else {
            throw ClientError.invalidResponse
        }
        return result
    }

    private func sendNotification<Params: Encodable>(
        method: String,
        params: Params
    ) throws {
        guard process?.isRunning == true, let inputPipe else {
            throw ClientError.notRunning
        }

        var data = try JSONEncoder().encode(
            RPCNotification(method: method, params: params)
        )
        rememberInput(data)
        data.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func rememberInput(_ data: Data) {
        guard let line = String(data: data, encoding: .utf8) else { return }
        recentInputLines.append(line)
        if recentInputLines.count > 20 {
            recentInputLines.removeFirst(recentInputLines.count - 20)
        }
    }

    private func handleOutputLine(_ line: String) {
        recentOutputLines.append(line)
        if recentOutputLines.count > 20 {
            recentOutputLines.removeFirst(recentOutputLines.count - 20)
        }

        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        if let id = object["id"] as? Int {
            pending.removeValue(forKey: id)?.resume(returning: data)
            return
        }

        if let method = object["method"] as? String {
            notificationHandler?(method)
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)

        while let newlineIndex = outputBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(outputBuffer[..<newlineIndex])
            outputBuffer.removeSubrange(...newlineIndex)

            guard !lineData.isEmpty,
                  let line = String(data: lineData, encoding: .utf8)
            else {
                continue
            }
            handleOutputLine(line)
        }
    }

    private func timeoutRequest(id: Int, method: String) {
        pending.removeValue(forKey: id)?.resume(
            throwing: ClientError.requestTimedOut(method)
        )
    }

    private func handleTermination(status: Int32) {
        let shouldNotify = !isStoppingIntentionally
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        failPending(with: ClientError.processExited(status))
        if shouldNotify {
            notificationHandler?("internal/processExited")
        }
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        continuations.forEach { $0.resume(throwing: error) }
    }

    private func appendStandardError(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lastStandardError += text
        if lastStandardError.count > 8_192 {
            lastStandardError = String(lastStandardError.suffix(8_192))
        }
    }
}
