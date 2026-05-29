import Foundation

struct ProgressBar {
    let total: Int
    private(set) var current: Int = 0
    private let barWidth = 30
    let isTTY: Bool

    init(total: Int, label: String) {
        self.total = total
        self.isTTY = isatty(STDOUT_FILENO) != 0
        if isTTY {
            render()
        } else {
            print(label)
        }
    }

    mutating func advance() {
        current = min(current + 1, total)
        if isTTY { render() }
    }

    func finish(summary: String) {
        if isTTY {
            print("\r\(String(repeating: " ", count: barWidth + 20))\r\(summary)")
        } else {
            print(summary)
        }
    }

    private func render() {
        let filled = total > 0 ? (current * barWidth) / total : 0
        let empty = barWidth - filled
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        print("\r[\(bar)] \(current)/\(total)", terminator: "")
        fflush(stdout)
    }
}
