import Darwin
import Foundation

/// `photobench-engine --stdio`: Photo Bench's rendering engine for NIHO
/// Desktop, which runs it as a child process and talks to it over standard
/// input and output (docs/ENGINE_PROTOCOL.md). `--version` prints the
/// engine version.
func runEngine(arguments: [String]) -> Never {
    switch arguments {
    case ["--version"]:
        print(EngineVersion.current)
        exit(0)
    case ["--stdio"]:
        break
    default:
        FileHandle.standardError.write(Data("使い方: photobench-engine --stdio | --version\n".utf8))
        exit(2)
    }

    // A reader that went away must not kill the engine with SIGPIPE; the
    // write fails with EPIPE instead and the closed standard input ends it.
    signal(SIGPIPE, SIG_IGN)

    // Responses get a private duplicate of the original standard output,
    // and file descriptor 1 is pointed at standard error, so a stray print()
    // from any library can never corrupt the response stream.
    let responseFileDescriptor = dup(STDOUT_FILENO)
    guard responseFileDescriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
        EngineLog.write("標準出力を準備できません: errno \(errno)")
        exit(1)
    }
    _ = fcntl(responseFileDescriptor, F_SETFD, FD_CLOEXEC)

    let session = EngineSession(
        backend: PhotoCoreBackend(),
        sink: FileDescriptorResponseSink(fileDescriptor: responseFileDescriptor),
        terminate: { status in exit(status) }
    )
    EngineLog.write("started \(EngineVersion.current) protocol \(EngineVersion.protocolVersion) pid \(getpid())")

    let reader = Thread {
        LineReader(fileDescriptor: STDIN_FILENO).run(
            onLine: { session.handle(line: $0) },
            onOversizedLine: { session.rejectOversizedLine() }
        )
        session.handleEndOfInput()
    }
    reader.name = "photobench-engine.stdin"
    reader.stackSize = 8 << 20
    reader.start()

    dispatchMain()
}

runEngine(arguments: Array(CommandLine.arguments.dropFirst()))
