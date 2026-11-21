// P-106 bench harness: drives the EngineCore RibbonEngine (Swift MPM, shipping
// config window 1024 / hop 256) over a 16 kHz mono PCM16 fixture and dumps one
// tab-separated frame per line: t_s (window END — the contract RibbonFrame
// timestamp), hz, clarity. 40 ms (640-sample) pushes — the P-104 pipeline
// chunk size, same as the RTF bench in P-102/P-105.
//
// Build (any machine with swiftc — Linux dev box / macOS CI):
//   swiftc -O main.swift \
//     <repo>/Engine/Sources/EngineCore/Pitch/RibbonMPM.swift \
//     <repo>/Engine/Sources/EngineCore/Pitch/PCMWaveReader.swift \
//     -o ribbon_swift_bench
// Run: ./ribbon_swift_bench <fixture.wav> [out.tsv]
//
// Truth pairing (Tests/Spikes/bench_f1.py): frame k covers the window ending
// at t = (k·256 + 1024)/16000; its window CENTER is t − 32 ms — the same
// physical convention as the vendored C++ runner (which emits window START
// and centers at +32 ms). bench_f1.py folds both onto the shared grid.

import Foundation

let args = CommandLine.arguments
guard args.count == 2 || args.count == 3 else {
    FileHandle.standardError.write("usage: ribbon_swift_bench <fixture.wav> [out.tsv]\n".data(using: .utf8)!)
    exit(2)
}

let content: PCMWaveReader.Content
do {
    content = try PCMWaveReader.read(url: URL(fileURLWithPath: args[1]))
} catch {
    FileHandle.standardError.write("cannot read fixture: \(error)\n".data(using: .utf8)!)
    exit(1)
}
guard content.sampleRate == RibbonSpec.sampleRate, content.channels == 1 else {
    FileHandle.standardError.write("fixture must be 16 kHz mono (got \(content.sampleRate) Hz, \(content.channels) ch)\n".data(using: .utf8)!)
    exit(1)
}

let engine = RibbonEngine() // window 1024 (64 ms), hop 256 (16 ms) — shipping config
var lines: [String] = []
let chunk = 640 // 40 ms pushes — P-104 pipeline chunk size
var i = 0
while i < content.samples.count {
    let end = min(i + chunk, content.samples.count)
    for f in engine.push(Array(content.samples[i..<end])) {
        lines.append("\(f.t)\t\(f.hz)\t\(f.clarity)")
    }
    i = end
}
let out = lines.joined(separator: "\n") + "\n"
if args.count == 3 {
    try out.write(toFile: args[2], atomically: true, encoding: .utf8)
} else {
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}
