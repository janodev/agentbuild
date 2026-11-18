import Darwin
import Dispatch
import Synchronization

/// Dispatch sources and saved handlers are initialized once and never mutated.
/// The mutex serializes receipt and restoration; the stream continuation is Sendable.
public final class SignalRelay: @unchecked Sendable {
    enum RelayError: Error {
        case systemCall(operation: String, signal: Int32, errorNumber: Int32)
    }

    private struct State {
        var firstSignal: Int32?
        var restored = false
    }

    private let continuation: AsyncStream<Int32>.Continuation
    private let previousActions: [(Int32, sigaction)]
    private let sources: [DispatchSourceSignal]
    private let state = Mutex(State())
    private let stream: AsyncStream<Int32>

    public init(signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]) throws {
        let pair = AsyncStream.makeStream(of: Int32.self)
        stream = pair.stream
        continuation = pair.continuation

        var savedActions: [(Int32, sigaction)] = []
        do {
            for number in signals {
                var previous = sigaction()
                guard sigaction(number, nil, &previous) == 0 else {
                    throw RelayError.systemCall(operation: "sigaction(get)", signal: number, errorNumber: errno)
                }
                savedActions.append((number, previous))
                var ignored = sigaction()
                ignored.__sigaction_u.__sa_handler = SIG_IGN
                guard sigemptyset(&ignored.sa_mask) == 0,
                      sigaction(number, &ignored, nil) == 0 else {
                    throw RelayError.systemCall(operation: "sigaction(ignore)", signal: number, errorNumber: errno)
                }
            }
        } catch {
            for (number, var action) in savedActions.reversed() {
                _ = sigaction(number, &action, nil)
            }
            throw error
        }
        previousActions = savedActions

        // Install handlers only after every stored property is initialized.
        sources = signals.map {
            DispatchSource.makeSignalSource(signal: $0, queue: .global(qos: .userInitiated))
        }
        for (number, source) in zip(signals, sources) {
            source.setEventHandler { [weak self] in self?.receive(number) }
            source.resume()
        }
    }

    deinit { restore() }

    public var firstSignal: Int32? { state.withLock { $0.firstSignal } }

    public func nextSignal() async -> Int32? {
        await withTaskCancellationHandler {
            for await number in stream { return number }
            return nil
        } onCancel: {
            continuation.finish()
        }
    }

    public func restore() {
        let shouldRestore = state.withLock { state in
            guard !state.restored else { return false }
            state.restored = true
            return true
        }
        guard shouldRestore else { return }
        for source in sources { source.cancel() }
        for (number, var action) in previousActions {
            _ = sigaction(number, &action, nil)
        }
        continuation.finish()
    }

    private func receive(_ number: Int32) {
        let isFirst = state.withLock { state in
            guard state.firstSignal == nil, !state.restored else { return false }
            state.firstSignal = number
            return true
        }
        if isFirst {
            continuation.yield(number)
            continuation.finish()
        }
    }
}
