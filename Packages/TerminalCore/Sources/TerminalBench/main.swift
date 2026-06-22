// Parser + screen-model throughput over synthetic VT workloads, in the
// spirit of vtebench's suites but in-process (no cargo dependency).
// Run: Scripts/bench.sh   Record results in PERF.md.
import Foundation
import TerminalCore

func benchmark(_ name: String, columns: Int = 120, rows: Int = 40, megabytes: Int = 32, chunk: [UInt8]) {
    var terminal = Terminal(columns: columns, rows: rows)
    let targetBytes = megabytes * 1_000_000
    var fed = 0
    let clock = ContinuousClock()
    let start = clock.now
    chunk.withUnsafeBufferPointer { buffer in
        while fed < targetBytes {
            terminal.feed(buffer)
            fed += buffer.count
        }
    }
    let elapsed = clock.now - start
    let seconds = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    let mbPerSecond = Double(fed) / 1_000_000 / seconds
    // Consume some state so the work can't be optimized away.
    let sink = terminal.state.generation
    print("\(name): \(Int(mbPerSecond)) MB/s  (\(fed / 1_000_000) MB in \(String(format: "%.2f", seconds))s, gen \(sink))")
}

func repeated(_ text: String, until bytes: Int) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes + text.utf8.count)
    while out.count < bytes {
        out.append(contentsOf: text.utf8)
    }
    return out
}

// Plain ASCII lines that scroll (the `cat large-file` shape).
benchmark(
    "scrolling-plain-ascii",
    chunk: repeated(
        "The quick brown fox jumps over the lazy dog 0123456789 abcdefghijklmnop\r\n",
        until: 1 << 20))

// One enormous wrapped line (stresses the wrap path).
benchmark(
    "wrapped-long-line",
    chunk: repeated("abcdefghijklmnopqrstuvwxyz0123456789", until: 1 << 20))

// SGR-heavy colored output (the `ls -la --color` / build-log shape).
benchmark(
    "colored-text",
    chunk: repeated(
        "\u{1B}[31;1mred\u{1B}[0m \u{1B}[38;5;42mgreen\u{1B}[0m \u{1B}[38;2;10;20;30mtrue\u{1B}[0m plain text here\r\n",
        until: 1 << 20))

// Cursor-addressed writes on the alternate screen (the htop/vim shape).
var editorChunk: [UInt8] = Array("\u{1B}[?1049h".utf8)
var row = 1
while editorChunk.count < 1 << 20 {
    editorChunk.append(contentsOf: "\u{1B}[\(row);1H\u{1B}[Ksome refreshed status line content \(row)".utf8)
    row = row % 40 + 1
}
benchmark("alt-screen-cursor-addressing", chunk: editorChunk)

// Mixed UTF-8 with wide characters.
benchmark(
    "utf8-mixed-wide",
    chunk: repeated("héllo wörld 中文字符 and ascii tail here\r\n", until: 1 << 20))

// Scroll-region churn (the tmux shape).
benchmark(
    "scroll-region",
    chunk: Array("\u{1B}[5;35r".utf8) + repeated(
        "\u{1B}[35;1Hnew line entering a pinned scroll region, text text text\n",
        until: 1 << 20))

// Search-as-you-type: allMatches over a full scrollback, the cost paid on
// every find-bar keystroke (the live counter + match highlighting).
func benchmarkSearch(_ name: String, query: String, options: SearchOptions = .default) {
    var terminal = Terminal(columns: 120, rows: 40)
    terminal.scrollbackLimit = 10_000
    let line = "The quick brown fox jumps over the lazy dog 0123456789 abcdefghijk\r\n"
    let bytes = line.utf8
    // Fill the scrollback to its limit.
    for _ in 0..<11_000 { terminal.feed(Array(bytes)) }
    let state = terminal.state
    let clock = ContinuousClock()
    var hits = 0
    let iterations = 50
    let start = clock.now
    for _ in 0..<iterations {
        hits = state.allMatches(for: query, options: options).count
    }
    let elapsed = clock.now - start
    let ms = (Double(elapsed.components.seconds) * 1000
        + Double(elapsed.components.attoseconds) / 1e15) / Double(iterations)
    print("\(name): \(String(format: "%.2f", ms)) ms/scan  (\(hits) hits over \(state.scrollback.count) lines)")
}

benchmarkSearch("search-literal-common", query: "o")
benchmarkSearch("search-literal-word", query: "fox")
benchmarkSearch("search-regex", query: "[0-9]+", options: SearchOptions(regex: true))
