import AudioKit
import AVFoundation
import SwiftUI

@main
struct ToeJamApp: App {
    
    init() {
        #if os(iOS)
            do {
                // Settings.sampleRate default is 44_100
                if #available(iOS 18.0, *) {
                    if !ProcessInfo.processInfo.isMacCatalystApp && !ProcessInfo.processInfo.isiOSAppOnMac {
                        // Set samplerRate for iOS 18 and newer
                        Settings.sampleRate = 48_000
                    }
                }
                try AVAudioSession.sharedInstance().setCategory(.playback,
                                                                options: [.mixWithOthers, .allowBluetoothA2DP])
                try AVAudioSession.sharedInstance().setActive(true)
            } catch let err {
                print(err)
            }
        #endif
    }

    
    var body: some Scene {
        WindowGroup {
            //Main version
            ContentView()
                .preferredColorScheme(.dark)
                .onAppear {
                    // Configure accessibility settings
                    UIAccessibility.post(notification: .screenChanged, argument: "Travis Picking Practice App launched")
                }
            
            //Easier version for tutorial
//            SimpleContentView()
        }
    }
}
