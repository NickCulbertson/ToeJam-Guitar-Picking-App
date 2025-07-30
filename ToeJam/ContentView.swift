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
    
    // Accessibility announcements
    @Published var accessibilityAnnouncement: String = ""
    
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
                self.instrument.loopThruRelease = 1.0
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
            
            // Accessibility announcement for tempo changes
            self.accessibilityAnnouncement = "Tempo: \(Int(newTempo)) beats per minute"
        }
    }
    
    func adjustSwing(_ change: Float) {
        DispatchQueue.main.async {
            let newSwing = max(0, min(1, self.pendingSwingAmount + change))
            self.pendingSwingAmount = newSwing
            
            // Accessibility announcement for swing changes
            self.accessibilityAnnouncement = "Swing: \(Int(newSwing * 100)) percent"
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
        stopScrub()
        scrubDirection = direction
        scrubCount = 0
        isScrubbing = true
        
        // Accessibility feedback for scrubbing start
        accessibilityAnnouncement = direction > 0 ? "Increasing tempo continuously" : "Decreasing tempo continuously"
        
        scrubTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.scrubCount += 1
            
            let multiplier: Float = {
                if self.scrubCount < 10 { return 1 }
                else if self.scrubCount < 30 { return 2 }
                else { return 5 }
            }()
            
            self.adjustTempo(direction * multiplier)
        }
    }
    
    func startSwingScrub(_ direction: Float) {
        stopSwingScrub()
        scrubDirection = direction
        scrubCount = 0
        isScrubbing = true
        
        // Accessibility feedback for swing scrubbing start
        accessibilityAnnouncement = direction > 0 ? "Increasing swing continuously" : "Decreasing swing continuously"
        
        swingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            self.scrubCount += 1
            
            let multiplier: Float = {
                if self.scrubCount < 10 { return 1 }
                else if self.scrubCount < 30 { return 2 }
                else { return 4 }
            }()
            
            self.adjustSwing(direction * multiplier)
        }
    }
    
    func stopSwingScrub() {
        swingTimer?.invalidate()
        swingTimer = nil
        if isScrubbing {
            applySwingChange()
            accessibilityAnnouncement = "Swing adjustment stopped"
        }
        isScrubbing = false
        scrubCount = 0
        scrubDirection = 0
    }
    
    func stopScrub() {
        scrubTimer?.invalidate()
        scrubTimer = nil
        if isScrubbing {
            accessibilityAnnouncement = "Tempo adjustment stopped"
        }
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
            
            if chordChanged {
                for note in currentlyPlayingNotes {
                    instrument.stop(noteNumber: MIDINoteNumber(note), channel: 0)
                }
                currentlyPlayingNotes.removeAll()
            }
        }
        
        let notesToPlay = currentNotes[patternStep]
        
        for note in notesToPlay {
            let velocity: MIDIVelocity = {
                switch patternStep {
                case 0: return 110
                case 4: return 100
                default: return 75
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
                self.accessibilityAnnouncement = "\(chord.accessibleName) chord will change at next measure"
            } else {
                self.currentChord = chord
                self.currentChordUI = chord
                self.updateCurrentNotes()
                self.patternStep = 0
                self.accessibilityAnnouncement = "\(chord.accessibleName) chord selected"
            }
        }
    }
    
    func selectPattern(_ pattern: PickingPattern) {
        DispatchQueue.main.async {
            if pattern == self.currentPatternUI { return }
            
            if self.isPlaying {
                self.pendingPatternChange = pattern
                self.accessibilityAnnouncement = "\(pattern.accessibleName) pattern will change at next measure"
            } else {
                self.currentPattern = pattern
                self.currentPatternUI = pattern
                self.updateCurrentNotes()
                self.patternStep = 0
                self.accessibilityAnnouncement = "\(pattern.accessibleName) pattern selected"
            }
        }
    }
    
    func togglePlayback() {
        DispatchQueue.main.async {
            if self.isPlaying {
                self.sequencer.stop()
                self.isPlaying = false
                self.patternStep = 0
                self.accessibilityAnnouncement = "Playback stopped"
                
                DispatchQueue.global(qos: .userInteractive).async {
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
                self.accessibilityAnnouncement = "Playback started with \(self.currentChordUI.accessibleName) chord and \(self.currentPatternUI.accessibleName) pattern"
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
        stopScrub()
        stopSwingScrub()
        sequencer?.stop()
        engine.stop()
        
        DispatchQueue.global(qos: .userInteractive).async {
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
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor
    
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
                // Main Play/Stop Button
                Button(action: { conductor.togglePlayback() }) {
                    Text(conductor.isPlaying ? "STOP" : "PLAY")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(maxWidth: 280, maxHeight: 120)
                .buttonStyle(FootControlButtonStyle(isActive: conductor.isPlaying))
                .accessibilityLabel(conductor.isPlaying ? "Stop playback" : "Start playback")
                .accessibilityHint("Double tap to \(conductor.isPlaying ? "stop" : "start") the guitar pattern playback")
                .accessibilityAction(named: "Toggle Playback") {
                    conductor.togglePlayback()
                }
                
                // Tempo Controls
                VStack(spacing: 20) {
                    Text("Tempo Controls")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityAddTraits(.isHeader)
                    
                    HStack(spacing: 40) {
                        Button("SLOWER") {
                            conductor.adjustTempo(-5)
                        }
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 140, maxHeight: 80)
                        .buttonStyle(FootControlButtonStyle(isActive: false))
                        .accessibilityLabel("Decrease tempo")
                        .accessibilityHint("Tap to decrease tempo by 5 BPM, or hold to continuously decrease")
                        .accessibilityValue("Current tempo: \(Int(conductor.tempo)) beats per minute")
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: .infinity, perform: {}) { isPressing in
                            if isPressing {
                                conductor.startTempoScrub(-1)
                            } else {
                                conductor.stopScrub()
                            }
                        }
                        
                        VStack(spacing: 4) {
                            Text("\(Int(conductor.tempo))")
                                .font(.system(size: 32, weight: .bold))
                                .foregroundColor(.white)
                            Text("BPM")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current tempo: \(Int(conductor.tempo)) beats per minute")
                        
                        Button("FASTER") {
                            conductor.adjustTempo(5)
                        }
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 140, maxHeight: 80)
                        .buttonStyle(FootControlButtonStyle(isActive: false))
                        .accessibilityLabel("Increase tempo")
                        .accessibilityHint("Tap to increase tempo by 5 BPM, or hold to continuously increase")
                        .accessibilityValue("Current tempo: \(Int(conductor.tempo)) beats per minute")
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: .infinity, perform: {}) { isPressing in
                            if isPressing {
                                conductor.startTempoScrub(1)
                            } else {
                                conductor.stopScrub()
                            }
                        }
                    }
                }
                
                // Swing Controls
                VStack(spacing: 20) {
                    Text("Swing Controls")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityAddTraits(.isHeader)
                    
                    HStack(spacing: 40) {
                        Button("LESS SWING") {
                            conductor.adjustSwing(-0.05)
                        }
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 140, maxHeight: 70)
                        .buttonStyle(FootControlButtonStyle(isActive: false))
                        .accessibilityLabel("Decrease swing")
                        .accessibilityHint("Tap to decrease swing by 5%, or hold to continuously decrease")
                        .accessibilityValue("Current swing: \(Int(conductor.pendingSwingAmount * 100)) percent")
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: .infinity, perform: {}) { isPressing in
                            if isPressing {
                                conductor.startSwingScrub(-0.05)
                            } else {
                                conductor.stopSwingScrub()
                            }
                        }
                        
                        VStack(spacing: 4) {
                            Text("\(Int(conductor.pendingSwingAmount * 100))%")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(.white)
                            Text("Swing")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Current swing: \(Int(conductor.pendingSwingAmount * 100)) percent")
                        
                        Button("MORE SWING") {
                            conductor.adjustSwing(0.05)
                        }
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: 140, maxHeight: 70)
                        .buttonStyle(FootControlButtonStyle(isActive: false))
                        .accessibilityLabel("Increase swing")
                        .accessibilityHint("Tap to increase swing by 5%, or hold to continuously increase")
                        .accessibilityValue("Current swing: \(Int(conductor.pendingSwingAmount * 100)) percent")
                        .onLongPressGesture(minimumDuration: 0.3, maximumDistance: .infinity, perform: {}) { isPressing in
                            if isPressing {
                                conductor.startSwingScrub(0.05)
                            } else {
                                conductor.stopSwingScrub()
                            }
                        }
                    }
                }
                
                // Chord Selection
                VStack(spacing: 20) {
                    Text("Chords (Key of G)")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityAddTraits(.isHeader)
                    
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
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Chord selection. Currently selected: \(conductor.currentChordUI.accessibleName)")
                
                // Pattern Selection
                VStack(spacing: 20) {
                    Text("Picking Patterns")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white)
                        .accessibilityAddTraits(.isHeader)
                    
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
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Pattern selection. Currently selected: \(conductor.currentPatternUI.accessibleName)")
                
                Spacer()
            }
        }
        .onAppear {
            conductor.start()
        }
        .onDisappear {
            conductor.stop()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAnnouncement(conductor.accessibilityAnnouncement)
        .onChange(of: conductor.accessibilityAnnouncement) { announcement in
            if !announcement.isEmpty {
                // Clear the announcement after a delay to prevent repetition
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    conductor.accessibilityAnnouncement = ""
                }
            }
        }
    }
}

struct FootControlButtonStyle: ButtonStyle {
    var isActive: Bool = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.accessibilityDifferentiateWithoutColor) var differentiateWithoutColor
    
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
                                lineWidth: differentiateWithoutColor ? (isActive ? 4 : 3) : (isActive ? 3 : 2)
                            )
                    )
                    .overlay(
                        // Additional visual indicator for active state when differentiateWithoutColor is enabled
                        differentiateWithoutColor && isActive ?
                        RoundedRectangle(cornerRadius: 15)
                            .strokeBorder(Color.white, lineWidth: 2)
                            .padding(2) : nil
                    )
            )
            .scaleEffect(reduceMotion ? 1.0 : (configuration.isPressed ? 0.95 : 1.0))
            .brightness(configuration.isPressed ? 0.2 : 0)
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.1), value: configuration.isPressed)
            .animation(reduceMotion ? .none : .easeInOut(duration: 0.2), value: isActive)
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
        .accessibilityLabel(chord.accessibleName)
        .accessibilityHint("Select \(chord.accessibleName) chord")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityValue(isActive ? "Selected" : "Not selected")
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
        .accessibilityLabel(pattern.accessibleName)
        .accessibilityHint("Select \(pattern.accessibleName) picking pattern")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityValue(isActive ? "Selected" : "Not selected")
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
    
    var accessibleName: String {
        switch self {
        case .g: return "G major chord, roman numeral 1"
        case .am: return "A minor chord, roman numeral 2"
        case .bm: return "B minor chord, roman numeral 3"
        case .c: return "C major chord, roman numeral 4"
        case .d: return "D major chord, roman numeral 5"
        case .em: return "E minor chord, roman numeral 6"
        case .fsharpDim: return "F sharp diminished chord, roman numeral 7"
        case .gOct: return "G major octave chord, roman numeral 1 octave"
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
    
    var accessibleName: String {
        switch self {
        case .travis: return "Travis picking pattern"
        case .alternate: return "Alternating bass pattern"
        case .rolling: return "Rolling pattern"
        case .arpeggio: return "Arpeggio pattern"
        }
    }
    
    var accessibleDescription: String {
        switch self {
        case .travis: return "Classic fingerpicking style with alternating bass and melody"
        case .alternate: return "Alternating bass notes with chord accompaniment"
        case .rolling: return "Continuous rolling through chord tones"
        case .arpeggio: return "Sequential notes of the chord, one at a time"
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

// MARK: - Accessibility Extensions

extension View {
    func accessibilityAnnouncement(_ announcement: String) -> some View {
        self.onChange(of: announcement) { newAnnouncement in
            if !newAnnouncement.isEmpty {
                // Use UIAccessibility.post to make VoiceOver announcements
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    UIAccessibility.post(notification: .announcement, argument: newAnnouncement)
                }
            }
        }
    }
}

// MARK: - Voice Control and Switch Control Support

struct AccessibleControlWrapper<Content: View>: View {
    let content: Content
    let identifier: String
    let label: String
    let action: () -> Void
    
    init(identifier: String, label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.identifier = identifier
        self.label = label
        self.action = action
        self.content = content()
    }
    
    var body: some View {
        content
            .accessibilityIdentifier(identifier)
            .accessibilityAction(named: "Activate") {
                action()
            }
            .accessibilityAction(named: label) {
                action()
            }
    }
}

// MARK: - Haptic Feedback Support

class HapticFeedbackManager {
    static let shared = HapticFeedbackManager()
    
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let notificationFeedback = UINotificationFeedbackGenerator()
    
    private init() {
        lightImpact.prepare()
        mediumImpact.prepare()
        heavyImpact.prepare()
        selectionFeedback.prepare()
        notificationFeedback.prepare()
    }
    
    func playSelection() {
        selectionFeedback.selectionChanged()
    }
    
    func playLight() {
        lightImpact.impactOccurred()
    }
    
    func playMedium() {
        mediumImpact.impactOccurred()
    }
    
    func playHeavy() {
        heavyImpact.impactOccurred()
    }
    
    func playSuccess() {
        notificationFeedback.notificationOccurred(.success)
    }
    
    func playError() {
        notificationFeedback.notificationOccurred(.error)
    }
    
    func playWarning() {
        notificationFeedback.notificationOccurred(.warning)
    }
}

// MARK: - Enhanced Button with Haptic Feedback

struct AccessibleButton<Content: View>: View {
    let action: () -> Void
    let content: Content
    let hapticType: HapticType
    let accessibilityLabel: String
    let accessibilityHint: String
    
    enum HapticType {
        case light, medium, heavy, selection, success, error, warning
    }
    
    init(
        accessibilityLabel: String,
        accessibilityHint: String = "",
        hapticType: HapticType = .light,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.hapticType = hapticType
        self.action = action
        self.content = content()
    }
    
    var body: some View {
        Button(action: {
            // Provide haptic feedback
            switch hapticType {
            case .light: HapticFeedbackManager.shared.playLight()
            case .medium: HapticFeedbackManager.shared.playMedium()
            case .heavy: HapticFeedbackManager.shared.playHeavy()
            case .selection: HapticFeedbackManager.shared.playSelection()
            case .success: HapticFeedbackManager.shared.playSuccess()
            case .error: HapticFeedbackManager.shared.playError()
            case .warning: HapticFeedbackManager.shared.playWarning()
            }
            
            action()
        }) {
            content
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}

// MARK: - Keyboard Navigation Support

struct KeyboardNavigationView: View {
    @StateObject private var conductor = TravisPickingConductor()
    @FocusState private var focusedField: FocusField?
    
    enum FocusField: Hashable, CaseIterable {
        case playButton
        case tempoDown, tempoUp
        case swingDown, swingUp
        case chordG, chordAm, chordBm, chordC, chordD, chordEm, chordFsharpDim, chordGOct
        case patternTravis, patternAlternate, patternRolling, patternArpeggio
        
        var next: FocusField {
            let allCases = FocusField.allCases
            let currentIndex = allCases.firstIndex(of: self) ?? 0
            let nextIndex = (currentIndex + 1) % allCases.count
            return allCases[nextIndex]
        }
        
        var previous: FocusField {
            let allCases = FocusField.allCases
            let currentIndex = allCases.firstIndex(of: self) ?? 0
            let previousIndex = currentIndex == 0 ? allCases.count - 1 : currentIndex - 1
            return allCases[previousIndex]
        }
    }
    
    var body: some View {
        ContentView()
            .environmentObject(conductor)
            .onKeyPress(.space) {
                conductor.togglePlayback()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                focusedField = focusedField?.previous ?? .playButton
                return .handled
            }
            .onKeyPress(.rightArrow) {
                focusedField = focusedField?.next ?? .playButton
                return .handled
            }
            .onKeyPress(.upArrow) {
                switch focusedField {
                case .tempoDown, .tempoUp:
                    conductor.adjustTempo(5)
                case .swingDown, .swingUp:
                    conductor.adjustSwing(0.05)
                default:
                    break
                }
                return .handled
            }
            .onKeyPress(.downArrow) {
                switch focusedField {
                case .tempoDown, .tempoUp:
                    conductor.adjustTempo(-5)
                case .swingDown, .swingUp:
                    conductor.adjustSwing(-0.05)
                default:
                    break
                }
                return .handled
            }
            .onKeyPress(.return) {
                handleReturnKey()
                return .handled
            }
    }
    
    private func handleReturnKey() {
        switch focusedField {
        case .playButton:
            conductor.togglePlayback()
        case .tempoDown:
            conductor.adjustTempo(-5)
        case .tempoUp:
            conductor.adjustTempo(5)
        case .swingDown:
            conductor.adjustSwing(-0.05)
        case .swingUp:
            conductor.adjustSwing(0.05)
        case .chordG:
            conductor.selectChord(.g)
        case .chordAm:
            conductor.selectChord(.am)
        case .chordBm:
            conductor.selectChord(.bm)
        case .chordC:
            conductor.selectChord(.c)
        case .chordD:
            conductor.selectChord(.d)
        case .chordEm:
            conductor.selectChord(.em)
        case .chordFsharpDim:
            conductor.selectChord(.fsharpDim)
        case .chordGOct:
            conductor.selectChord(.gOct)
        case .patternTravis:
            conductor.selectPattern(.travis)
        case .patternAlternate:
            conductor.selectPattern(.alternate)
        case .patternRolling:
            conductor.selectPattern(.rolling)
        case .patternArpeggio:
            conductor.selectPattern(.arpeggio)
        case .none:
            break
        }
    }
}
