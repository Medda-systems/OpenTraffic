import CoreServices
import Foundation

/// Watches a share's project folder for changes to its files (an agent's fix, or the user's own edits),
/// so pages in the session can catch up. Folders that aren't part of the page (version control,
/// dependencies, caches) don't count, and a burst of changes is reported once, when it has gone quiet
/// for `delay`. Thread-safe; stops when released.
public final class ProjectWatcher: @unchecked Sendable {
    /// Folders whose changes never change the page.
    public static let ignoredFolders: Set<String> = [".git", ".hg", ".svn", "node_modules", ".build", ".swiftpm", ".cache", "__pycache__", ".turbo", ".parcel-cache"]

    public let directory: URL
    private let delay: TimeInterval
    private let changed: @Sendable () -> Void
    private let queue = DispatchQueue(label: "OpenTraffic project watcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?

    public init(directory: URL, delay: TimeInterval = 0.4, changed: @escaping @Sendable () -> Void) {
        self.directory = directory.resolvingSymlinksInPath()
        self.delay = delay
        self.changed = changed
    }

    deinit { stop() }

    /// Starts watching; false if the folder can't be watched.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            if list.prefix(count).contains(where: { watcher.matters($0) }) { watcher.schedule() }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(nil, callback, &context, [directory.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        pending?.cancel()
        pending = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    /// Whether a change at `path` can change the page: inside the folder, not in an ignored folder, and
    /// not a hidden file (editors' swap files, .DS_Store).
    func matters(_ path: String) -> Bool {
        Self.matters(path, under: directory.path)
    }

    static func matters(_ path: String, under root: String) -> Bool {
        let base = root.hasSuffix("/") ? root : root + "/"
        // FSEvents reports /private/tmp for /tmp and the like.
        let candidates = [path, path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path]
        guard let inside = candidates.first(where: { $0.hasPrefix(base) }) else { return false }
        let parts = inside.dropFirst(base.count).split(separator: "/").map(String.init)
        guard let name = parts.last, !name.hasPrefix("."), !name.hasSuffix("~") else { return false }
        return !parts.dropLast().contains { ignoredFolders.contains($0) || $0.hasPrefix(".") }
    }

    private func schedule() {
        lock.lock()
        defer { lock.unlock() }
        guard stream != nil else { return }
        pending?.cancel()
        let item = DispatchWorkItem { [changed] in changed() }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
