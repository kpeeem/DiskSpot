import Foundation

let usage = """
diskspotmcp — an MCP server over stdio that measures what fills this Mac's disks.
It is the scanner of DiskSpot without the window.

USAGE: diskspotmcp [--status] [--version] [--help]

  --status    Print whether this binary can read every folder and which folders
              Spotlight does not index, then exit.
  --version   Print the version.

Without arguments it speaks the Model Context Protocol on stdin and stdout, so
an MCP client (Claude Code, another agent) can ask for exact folder sizes, the
biggest files, what was written lately and what grew since a snapshot.
"""

let instructions = """
Disk space on this Mac: how much every folder takes, which files are the \
biggest, what has been written lately and what grew since last time.

disk_volumes shows every volume with used, free and purgeable space, and the \
APFS volumes of the boot container (sealed system, VM swap) that no file walk \
can see. disk_status says whether every folder can be read and which folders \
Spotlight does not index.

Exact numbers come from a walk: disk_tree for a folder tree, disk_top for the \
heaviest folders and files under a path. Both count like du (allocated blocks, \
hard links once) and never download anything from iCloud; a scan is kept in \
memory, so a second question about the same path answers at once.

The Spotlight index answers without a walk: disk_big_files for big files \
anywhere in a scope, disk_recent for what changed in the last days, summed per \
folder — the fastest answer to "what filled the disk recently".

To watch growth over time: disk_snapshot stores an exact measurement, disk_diff \
says what grew, appeared, shrank or went away since it, and \
disk_snapshot_forget deletes one.

Cleanup with the user: when asked what to clean, measure first, then call \
disk_advise with every candidate, a verdict and a reason in the user's language. \
The DiskSpot app shows it on its cleanup tab and the user removes what they \
agree with; disk_advice reports what was trashed or kept. Never delete files \
yourself.
"""

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--version") {
    print("diskspotmcp \(MCPInfo.version)")
    exit(0)
}

if arguments.contains("-h") || arguments.contains("--help") {
    print(usage)
    exit(0)
}

if arguments.contains("--status") {
    let status: [String: Any] = [
        "full_disk_access": Permissions.hasFullDiskAccess(),
        "boot_volume": Volumes.space(at: "/").map { spaceJSON($0) } as Any,
        "spotlight_exclusions": Spotlight.exclusions(),
        "snapshot_directory": SnapshotStore.directory.path,
        "snapshots": SnapshotStore.headers().map(\.json),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: JSONSafe.clean(status), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
        print(String(decoding: data, as: UTF8.self))
    }
    exit(0)
}

if let unknown = arguments.first {
    FileHandle.standardError.write(Data("Unknown option \(unknown)\n\n\(usage)\n".utf8))
    exit(64)
}

signal(SIGPIPE, SIG_IGN)
ExactScanner.disableDatalessMaterialization()

let store = ScanStore()
let server = MCPServer(
    tools: makeDiskTools(store),
    queue: DispatchQueue(label: "diskspotmcp.server"),
    instructions: instructions
)

let reader = Thread { server.run() }
reader.name = "diskspotmcp.stdin"
reader.stackSize = 1 << 20
reader.start()

dispatchMain()
