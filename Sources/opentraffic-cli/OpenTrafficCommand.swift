import Foundation

// opentraffic — OpenTraffic from the terminal. Bundled in the app as Contents/MacOS/opentraffic-cli and
// installed as `opentraffic` from Settings → General. Exit status: 0 done, 1 failed, 2 wrong usage,
// 3 OpenTraffic not reachable or not set up.
@main
struct OpenTrafficCommand {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        // Line by line even into a pipe or file, so `watch` and `logs -f` stream.
        setvbuf(stdout, nil, _IOLBF, 0)
        do {
            let invocation = try Invocation.parse(Array(CommandLine.arguments.dropFirst()))
            try await Commands.run(invocation)
            exit(0)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("opentraffic: \(error.message)\n".utf8))
            exit(error.status)
        } catch is CancellationError {
            exit(130)
        } catch {
            FileHandle.standardError.write(Data("opentraffic: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
