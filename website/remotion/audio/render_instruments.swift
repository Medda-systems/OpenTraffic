// Offline sample-instrument renderer. No speaker output; requires macOS.
// swift render_instruments.swift <soundfont> <events.json> <output-directory>
import AVFoundation
import Foundation

struct Note: Decodable {
    let time: Double
    let duration: Double
    let note: UInt8
    let velocity: UInt8
}
struct Part: Decodable {
    let name: String
    let program: UInt8
    let percussion: Bool
    let notes: [Note]
}
struct Score: Decodable {
    let seconds: Double
    let parts: [Part]
}
struct Event {
    let frame: Int64
    let note: UInt8
    let velocity: UInt8
    let on: Bool
}
let args = CommandLine.arguments
guard args.count == 4 else { fatalError("Expected soundfont, score, output-directory") }
let score = try JSONDecoder().decode(Score.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let sr = 48000.0
let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
let frames = Int64((score.seconds * sr).rounded())
for part in score.parts {
    let engine = AVAudioEngine()
    let sampler = AVAudioUnitSampler()
    engine.attach(sampler)
    engine.connect(sampler, to: engine.mainMixerNode, format: format)
    try sampler.loadSoundBankInstrument(at: URL(fileURLWithPath: args[1]), program: part.program,
                                        bankMSB: part.percussion ? 120 : 121, bankLSB: 0)
    sampler.sendController(91, withValue: 0, onChannel: 0)
    sampler.sendController(93, withValue: 0, onChannel: 0)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    try engine.start()
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    let out = URL(fileURLWithPath: args[3]).appendingPathComponent(part.name + ".wav")
    var settings = format.settings
    settings[AVLinearPCMIsNonInterleaved] = false
    let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    var events = part.notes.flatMap { note in
        [Event(frame: Int64((note.time * sr).rounded()), note: note.note, velocity: note.velocity, on: true),
         Event(frame: Int64(((note.time + note.duration) * sr).rounded()), note: note.note, velocity: 0, on: false)]
    }.sorted { a, b in a.frame == b.frame ? (!a.on && b.on) : a.frame < b.frame }
    events.append(Event(frame: frames, note: 0, velocity: 0, on: false))
    var cursor: Int64 = 0
    var retries = 0
    for event in events {
        let target = min(event.frame, frames)
        while cursor < target {
            let count = AVAudioFrameCount(min(4096, target - cursor))
            let status = try engine.renderOffline(count, to: buffer)
            if status == .success {
                try file.write(from: buffer)
                cursor += Int64(buffer.frameLength)
                retries = 0
            } else {
                retries += 1
                guard retries < 100 else { fatalError("Offline rendering stalled: \(status)") }
            }
        }
        if event.frame >= frames { break }
        if event.on {
            sampler.startNote(event.note, withVelocity: event.velocity, onChannel: 0)
        } else {
            sampler.stopNote(event.note, onChannel: 0)
        }
    }
    engine.stop()
    print("Rendered \(part.name)")
}
