import SwiftUI
import AudioKit
import AudioKitEX
import SoundpipeAudioKit
import DunneAudioKit

class SimpleConductor: ObservableObject, HasAudioEngine {
    let engine = AudioEngine()
    var instrument = Sampler()
    var sequencer: SequencerTrack!
    var midiCallback: CallbackInstrument!
    
    @Published var isPlaying = false
    @Published var currentChord: Chord = .g
    
    private var step = 0
    
    // Simple chord notes (MIDI numbers)
    private let gNotes = [55, 59, 62, 67] // G-B-D-G (low to high)
    private let cNotes = [48, 52, 55, 60] // C-E-G-C (low to high)
    
    init() {
        setupAudio()
        setupSequencer()
    }
    
    private func setupAudio() {
        // When sequencer triggers, play the next note
        midiCallback = CallbackInstrument { [weak self] status, note, velocity in
            if status == 144 { // Note on
                self?.playNextNote()
            }
        }
        
        engine.output = Mixer(instrument, midiCallback)
        
        // Load guitar sound (optional)
        if let fileURL = Bundle.main.url(forResource: "guitar", withExtension: "SFZ") {
            instrument.loadSFZ(url: fileURL)
        }
        instrument.masterVolume = 0.8
    }
    
    private func setupSequencer() {
        sequencer = SequencerTrack(targetNode: midiCallback)
        sequencer.tempo = BPM(80) // Slow tempo for learning
        sequencer.length = 2.0     // 2 seconds = one full pattern
        sequencer.loopEnabled = true
        
        // Create 4 triggers (quarter notes)
        for i in 0..<4 {
            let position = Double(i) * 0.5 // Every half second
            sequencer.add(noteNumber: 60, position: position, duration: 0.1)
        }
    }
    
    private func playNextNote() {
        let notes = (currentChord == .g) ? gNotes : cNotes
        
        // Simple Travis pattern: Bass-High-Bass-High
        let noteToPlay = switch step {
        case 0: notes[0] // Low bass note
        case 1: notes[3] // High note
        case 2: notes[1] // Middle bass note
        case 3: notes[2] // Middle high note
        default: notes[0]
        }
        
        // Play the note
        instrument.play(noteNumber: MIDINoteNumber(noteToPlay),
                       velocity: 90,
                       channel: 0)
        
        // Move to next step (0,1,2,3,0,1,2,3...)
        step = (step + 1) % 4
    }
    
    func selectChord(_ chord: Chord) {
        currentChord = chord
        step = 0 // Start pattern over
    }
    
    func togglePlayback() {
        if isPlaying {
            sequencer.stop()
            isPlaying = false
        } else {
            step = 0
            sequencer.playFromStart()
            isPlaying = true
        }
    }
    
    func start() {
        do {
            try engine.start()
        } catch {
            print("AudioKit error: \(error)")
        }
    }
    
    func stop() {
        sequencer?.stop()
        engine.stop()
    }
}


struct SimpleContentView: View {
    @StateObject private var conductor = SimpleConductor()
    
    var body: some View {
        VStack(spacing: 50) {
            Text("Travis Picking Tutorial")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            // Play/Stop Button
            Button(action: { conductor.togglePlayback() }) {
                Text(conductor.isPlaying ? "STOP" : "PLAY")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 200, height: 100)
                    .background(conductor.isPlaying ? Color.red : Color.green)
                    .cornerRadius(20)
            }
            
            // Chord Selection
            HStack(spacing: 40) {
                Button("G Chord") {
                    conductor.selectChord(.g)
                }
                .font(.title)
                .foregroundColor(.white)
                .frame(width: 120, height: 80)
                .background(conductor.currentChord == .g ? Color.blue : Color.gray)
                .cornerRadius(15)
                
                Button("C Chord") {
                    conductor.selectChord(.c)
                }
                .font(.title)
                .foregroundColor(.white)
                .frame(width: 120, height: 80)
                .background(conductor.currentChord == .c ? Color.blue : Color.gray)
                .cornerRadius(15)
            }
        }
        .onAppear {
            conductor.start()
        }
        .onDisappear {
            conductor.stop()
        }
    }
}

// Two chords only
enum Chord {
    case g, c
}
