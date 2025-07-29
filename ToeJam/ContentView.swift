import SwiftUI
import AudioKit
import AudioKitEX
import AudioKitUI
import AVFoundation
import SoundpipeAudioKit
import DunneAudioKit
import Tonic

// MARK: - Main Conductor

class TravisPickingConductor: ObservableObject, HasAudioEngine {
    let engine = AudioEngine()
    var instrument = Sampler()
    var sequencer: SequencerTrack!
    var midiCallback: CallbackInstrument!
    
    @Published var isPlaying = false
    private var currentChord: GChord = .g
    private var currentPattern: PickingPattern = .travis
    @Published var currentChordUI: GChord = .g
    @Published var currentPatternUI: PickingPattern = .travis
    @Published var tempo: Float = 120.0 {
        didSet {
            sequencer?.tempo = BPM(tempo)
        }
    }
    
    @Published var swingAmount: Float = 0.0
    @Published var pendingSwingAmount: Float = 0.0
    
    private var pendingChordChange: GChord?
    private var pendingPatternChange: PickingPattern?
    private var patternStep = 0
    private var currentNotes: [[Int]] = []
    private var currentlyPlayingNotes: Set<Int> = []
    private var scrubTimer: Timer?
    private var swingTimer: Timer?
    private var scrubDirection: Float = 0
    private var scrubCount: Int = 0
    private var isScrubbing = false
    
    init() {
        setupAudio()
        setupSequencer()
        updateCurrentNotes()
    }
    
    private func setupAudio() {
        midiCallback = CallbackInstrument { [weak self] status, note, velocity in
            guard let self = self else { return }
            
            if status == 144 { // Note On
                DispatchQueue.global(qos: .userInteractive).async {
                    self.playNextNote()
                }
            }
        }
        
        engine.output = PeakLimiter(Mixer(instrument, midiCallback),
                                   attackTime: 0.001,
                                   decayTime: 0.001,
                                   preGain: 0)
        
        DispatchQueue.main.async {
            if let fileURL = Bundle.main.url(forResource: "guitar", withExtension: "SFZ") {
                self.instrument.loadSFZ(url: fileURL)
            } else {
                print("Could not find SFZ file - using default")
            }
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 1.0) {
                self.instrument.releaseDuration = 1.1
                self.instrument.loopThruRelease = 1.0 //true
            }
        }
    }
    
    private func setupSequencer() {
        sequencer = SequencerTrack(targetNode: midiCallback)
        sequencer.tempo = BPM(tempo)
        sequencer.length = 2.0
        sequencer.loopEnabled = true
        
        updateSequencerTiming()
    }
    
    private func updateCurrentNotes() {
        let voicing = ChordVoicings.getVoicing(for: currentChord)
        currentNotes = PatternGenerator.generatePattern(currentPattern, for: voicing)
    }
    
    func updateSwing(_ newValue: Float, isEditing: Bool) {
        pendingSwingAmount = newValue
        
        if !isEditing {
            applySwingChange()
        }
    }
    
    func adjustTempo(_ change: Float) {
        DispatchQueue.main.async {
            let newTempo = max(60, min(180, self.tempo + change))
            self.tempo = newTempo
        }
    }
    
    func adjustSwing(_ change: Float) {
        DispatchQueue.main.async {
            let newSwing = max(0, min(1, self.pendingSwingAmount + change))
            self.pendingSwingAmount = newSwing
            // Don't apply immediately - only update visual display
        }
    }
    
    private func applySwingChange() {
        DispatchQueue.main.async {
            self.swingAmount = self.pendingSwingAmount
            
            if self.isPlaying {
                self.sequencer.stop()
                self.updateSequencerTiming()
                self.sequencer.playFromStart()
            } else {
                self.updateSequencerTiming()
            }
        }
    }
    
    func startTempoScrub(_ direction: Float) {
        stopScrub() // Stop any existing scrub
        scrubDirection = direction
        scrubCount = 0
        isScrubbing = true
        
        scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.scrubCount += 1
            
            // Accelerate over time: starts slow, gets faster
            let multiplier: Float = {
                if self.scrubCount < 10 { return 1 }      // First second: 1x speed
                else if self.scrubCount < 30 { return 2 } // Next 2 seconds: 2x speed
                else { return 5 }                         // After 3 seconds: 5x speed
            }()
            
            self.adjustTempo(direction * multiplier)
        }
    }
    
    func startSwingScrub(_ direction: Float) {
        stopSwingScrub() // Stop any existing swing scrub
        scrubDirection = direction
        scrubCount = 0
        isScrubbing = true
        
        swingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.scrubCount += 1
            
            // Accelerate over time for swing (5% increments)
            let multiplier: Float = {
                if self.scrubCount < 10 { return 1 }      // First second: 1x speed (5%/tap)
                else if self.scrubCount < 30 { return 2 } // Next 2 seconds: 2x speed (10%/tap)
                else { return 4 }                         // After 3 seconds: 4x speed (20%/tap)
            }()
            
            self.adjustSwing(direction * multiplier)
        }
    }
    
    func stopSwingScrub() {
        swingTimer?.invalidate()
        swingTimer = nil
        // Apply the swing change when released
        if isScrubbing {
            applySwingChange()
        }
        isScrubbing = false
        scrubCount = 0
        scrubDirection = 0
    }
    
    func stopScrub() {
        scrubTimer?.invalidate()
        scrubTimer = nil
        isScrubbing = false
        scrubCount = 0
        scrubDirection = 0
    }
    
    private func updateSequencerTiming() {
        guard let sequencer = sequencer else { return }
        
        sequencer.clear()
        
        for i in 0..<8 {
            var position = Double(i) * 0.25
            
            if i % 2 == 1 {
                let swingOffset = Double(swingAmount) * 0.083
                position += swingOffset
            }
            
            sequencer.add(noteNumber: 60, position: position, duration: 0.1)
        }
    }
    
    private func playNextNote() {
        // Handle pending changes at start of cycle
        if patternStep == 0 {
            var shouldUpdateNotes = false
            var chordChanged = false
            
            if let pendingChord = pendingChordChange {
                currentChord = pendingChord
                
                DispatchQueue.main.async {
                    self.currentChordUI = pendingChord
                }

                pendingChordChange = nil
                shouldUpdateNotes = true
                chordChanged = true
            }
            
            if let pendingPattern = pendingPatternChange {
                currentPattern = pendingPattern
                DispatchQueue.main.async {
                    self.currentPatternUI = pendingPattern
                }
                pendingPatternChange = nil
                shouldUpdateNotes = true
            }
            
            if shouldUpdateNotes {
                updateCurrentNotes()
            }
            
            // Only stop all notes when chord changes
            if chordChanged {
                for note in currentlyPlayingNotes {
                    instrument.stop(noteNumber: MIDINoteNumber(note), channel: 0)
                }
                currentlyPlayingNotes.removeAll()
            }
        }
        
        let notesToPlay = currentNotes[patternStep]
        
        // Play new notes and add them to currently playing set
        for note in notesToPlay {
            let velocity: MIDIVelocity = {
                switch patternStep {
                case 0: return 110  // Strong start
                case 4: return 100  // Secondary accent
                default: return 75  // Regular notes
                }
            }()
            
            instrument.play(noteNumber: MIDINoteNumber(note),
                           velocity: velocity,
                           channel: 0)
            
            DispatchQueue.main.async {
                self.currentlyPlayingNotes.insert(note)
            }
        }
        
        patternStep = (patternStep + 1) % 8
    }
    
    func selectChord(_ chord: GChord) {
        DispatchQueue.main.async {
            if chord == self.currentChordUI { return }

            if self.isPlaying {
                self.pendingChordChange = chord
            } else {
                self.currentChord = chord
                self.currentChordUI = chord
                self.updateCurrentNotes()
                self.patternStep = 0
            }
        }
    }
    
    func selectPattern(_ pattern: PickingPattern) {
        DispatchQueue.main.async {
            if pattern == self.currentPatternUI { return }
            
            if self.isPlaying {
                self.pendingPatternChange = pattern
            } else {
                self.currentPattern = pattern
                self.currentPatternUI = pattern
                self.updateCurrentNotes()
                self.patternStep = 0
            }
        }
    }
    
    func togglePlayback() {
        DispatchQueue.main.async {
            if self.isPlaying {
                self.sequencer.stop()
                self.isPlaying = false
                self.patternStep = 0
                
                DispatchQueue.global(qos: .userInteractive).async {
                    // Stop all currently playing notes when stopping
                    for note in self.currentlyPlayingNotes {
                        self.instrument.stop(noteNumber: MIDINoteNumber(note), channel: 0)
                    }
                    self.currentlyPlayingNotes.removeAll()
                }
            } else {
                self.patternStep = 0
                self.currentlyPlayingNotes.removeAll()
                self.sequencer.playFromStart()
                self.isPlaying = true
            }
        }
    }
    
    func start() {
        do {
            try engine.start()
        } catch {
            print("Could not start engine: \(error)")
        }
    }
    
    func stop() {
        stopScrub() // Stop any active tempo scrubbing
        stopSwingScrub() // Stop any active swing scrubbing
        sequencer?.stop()
        engine.stop()
        
        DispatchQueue.global(qos: .userInteractive).async {
            // Stop only the notes we're tracking
            for note in self.currentlyPlayingNotes {
                self.instrument.stop(noteNumber: MIDINoteNumber(note), channel: 0)
            }
            self.currentlyPlayingNotes.removeAll()
        }
    }
}

// MARK: - Main View

struct ContentView: View {
    @StateObject private var conductor = TravisPickingConductor()
    
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [Color.black, Color.blue.opacity(0.3), Color.black]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .background(.black)
            .ignoresSafeArea()
            
            VStack(spacing: 30) {
                Button(action: { conductor.togglePlayback() }) {
                    Text(conductor.isPlaying ? "STOP" : "PLAY")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: 280, maxHeight: 120)
                .buttonStyle(FootControlButtonStyle(isActive: conductor.isPlaying))
                
                // Tempo Controls - Large foot-friendly buttons
                VStack(spacing: 20) {
                    HStack(spacing: 40) {
                        Button("SLOWER") {
                            conductor.adjustTempo(-5)
                        }
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 140, maxHeight: 80)
                        .buttonStyle(FootControlButtonStyle(isActive: false))
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: .infinity, perform: {}) { isPressing in
                            if isPressing {
                                conductor.startTempoScrub(-1)
                            } else {
                                conductor.stopScrub()
                            }
                        }
                        Text("\(Int(conductor.tempo)) BPM")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                        
                        Button("FASTER") {
                            conductor.adjustTempo(5)
                        }
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 140, maxHeight: 80)
                        .buttonStyle(FootControlButtonStyle(isActive: false))
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: .infinity, perform: {}) { isPressing in
                            if isPressing {
                                conductor.startTempoScrub(1)
                            } else {
                                conductor.stopScrub()
                            }
                        }
                    }
                }
                
                // Swing Controls - Larger for feet
                VStack(spacing: 20) {
                    HStack(spacing: 40) {
                        Button("LESS SWING") {
                            conductor.adjustSwing(-0.05)
                        }
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 140, maxHeight: 70)
                        .buttonStyle(FootControlButtonStyle(isActive: false))
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: .infinity, perform: {}) { isPressing in
                            if isPressing {
                                conductor.startSwingScrub(-0.05)
                            } else {
                                conductor.stopSwingScrub()
                            }
                        }
                        Text("Swing: \(Int(conductor.pendingSwingAmount * 100))%")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                        
                        Button("MORE SWING") {
                            conductor.adjustSwing(0.05)
                        }
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 140, maxHeight: 70)
                        .buttonStyle(FootControlButtonStyle(isActive: false))
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: .infinity, perform: {}) { isPressing in
                            if isPressing {
                                conductor.startSwingScrub(0.05)
                            } else {
                                conductor.stopSwingScrub()
                            }
                        }
                    }
                }
                
                // Chord Selection - Large foot-friendly pads
                VStack(spacing: 20) {
                    Text("Chords (Key of G)")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 15), count: 4), spacing: 15) {
                        ForEach(GChord.allCases, id: \.self) { chord in
                            ChordButton(
                                chord: chord,
                                isActive: conductor.currentChordUI == chord,
                                action: {
                                    conductor.selectChord(chord)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                
                // Pattern Selection - Large foot-friendly pads
                VStack(spacing: 20) {
                    Text("Picking Patterns")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                    
                    HStack(spacing: 20) {
                        ForEach(PickingPattern.allCases, id: \.self) { pattern in
                            PatternButton(
                                pattern: pattern,
                                isActive: conductor.currentPatternUI == pattern,
                                action: {
                                    conductor.selectPattern(pattern)
                                }
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                
                Spacer()
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

struct FootControlButtonStyle: ButtonStyle {
    var isActive: Bool = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(
                        isActive ?
                        Color.blue.opacity(0.8) :
                        Color.blue.opacity(0.3)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(
                                isActive ? Color.blue : Color.blue.opacity(0.5),
                                lineWidth: isActive ? 3 : 2
                            )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .brightness(configuration.isPressed ? 0.2 : 0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

struct ChordButton: View {
    let chord: GChord
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(chord.symbol)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                Text(chord.numeral)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
            }
            .frame(minWidth: 80, idealWidth: 110, maxWidth: 140,
                   minHeight: 80, idealHeight: 110, maxHeight: 140)
        }
        .buttonStyle(FootControlButtonStyle(isActive: isActive))
    }
}

struct PatternButton: View {
    let pattern: PickingPattern
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Text(pattern.name)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: 120, maxHeight: 100)
            .frame(minHeight: 60)
        }
        .buttonStyle(FootControlButtonStyle(isActive: isActive))
    }
}

// MARK: - Chord Definitions

enum GChord: CaseIterable {
    case g, am, bm, c, d, em, fsharpDim, gOct
    
    var symbol: String {
        switch self {
        case .g: return "G"
        case .am: return "Am"
        case .bm: return "Bm"
        case .c: return "C"
        case .d: return "D"
        case .em: return "Em"
        case .fsharpDim: return "F#°"
        case .gOct: return "G/8"
        }
    }
    
    var numeral: String {
        switch self {
        case .g: return "I"
        case .am: return "ii"
        case .bm: return "iii"
        case .c: return "IV"
        case .d: return "V"
        case .em: return "vi"
        case .fsharpDim: return "vii°"
        case .gOct: return "I/8"
        }
    }
}

// MARK: - Pattern Definitions

enum PickingPattern: CaseIterable {
    case travis, alternate, rolling, arpeggio
    
    var name: String {
        switch self {
        case .travis: return "Travis"
        case .alternate: return "Alt Bass"
        case .rolling: return "Rolling"
        case .arpeggio: return "Arp"
        }
    }
}

// MARK: - Chord Voicings

class ChordVoicings {
    static func getVoicing(for chord: GChord) -> ChordVoicing {
        switch chord {
        case .g:
            return ChordVoicing(
                root: 55,      // G3
                third: 62,     // D3 (actually 5th)
                fifth: 67,     // G4 (actually octave)
                octave: 71     // B4 (actually 3rd)
            )
        case .am:
            return ChordVoicing(
                root: 57,      // A2
                third: 64,     // C3 (actually 5th)
                fifth: 69,     // E3 (actually octave)
                octave: 72     // A3 (actually 3rd)
            )
        case .bm:
            return ChordVoicing(
                root: 59,      // B2
                third: 62,     // D3
                fifth: 66,     // F#3
                octave: 71     // B3
            )
        case .c:
            return ChordVoicing(
                root: 60,      // C3
                third: 64,     // E3
                fifth: 67,     // G3
                octave: 72     // C4
            )
        case .d:
            return ChordVoicing(
                root: 62,      // D3
                third: 66,     // F#3
                fifth: 69,     // A3
                octave: 74     // D4
            )
        case .em:
            return ChordVoicing(
                root: 64,      // E3
                third: 67,     // G3
                fifth: 71,     // B3
                octave: 76     // E4
            )
        case .fsharpDim:
            return ChordVoicing(
                root: 66,      // F#3
                third: 69,     // A3
                fifth: 72,     // C4
                octave: 78     // F#4
            )
        case .gOct:
            return ChordVoicing(
                root: 67,      // G3 (higher voicing)
                third: 71,     // B3
                fifth: 74,     // D4
                octave: 79     // G4
            )
        }
    }
}

struct ChordVoicing {
    let root: Int
    let third: Int
    let fifth: Int
    let octave: Int
}

// MARK: - Pattern Generator

class PatternGenerator {
    static func generatePattern(_ pattern: PickingPattern, for voicing: ChordVoicing) -> [[Int]] {
        switch pattern {
        case .travis:
            return [
                [voicing.root, voicing.octave], // Root+octave pinch
                [],                             // Rest
                [voicing.third],                // Third
                [voicing.fifth],                // Fifth
                [voicing.root],                 // Root
                [voicing.octave],               // Octave
                [voicing.third],                // Third
                []                              // Rest
            ]
            
        case .alternate:
            return [
                [voicing.root],
                [],
                [voicing.fifth, voicing.octave],
                [],
                [voicing.root],
                [voicing.third],
                [voicing.fifth],
                [voicing.octave]
            ]
            
        case .rolling:
            return [
                [voicing.root],
                [voicing.third],
                [voicing.fifth],
                [voicing.third],
                [voicing.octave],
                [voicing.fifth],
                [voicing.third],
                [voicing.fifth]
            ]
            
        case .arpeggio:
            return [
                [voicing.root],
                [],
                [voicing.third],
                [],
                [voicing.fifth],
                [],
                [voicing.octave],
                []
            ]
        }
    }
}

