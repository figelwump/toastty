import CoreGraphics
import Foundation
import Testing
@testable import ToasttyApp

struct RemotePushMacPresenceTests {
    @Test func lockAndIdleDetermineWhetherToSend() {
        for idle in [0.0, 119.999, 120, 300] {
            #expect(RemotePushMacPresence(screenIsLocked: true, idleSeconds: idle).allowsPush)
            #expect(RemotePushMacPresence(screenIsLocked: false, idleSeconds: idle).allowsPush == (idle >= 120))
        }
        for idle: TimeInterval? in [nil, -1, .nan, .infinity, -.infinity] {
            #expect(RemotePushMacPresence(screenIsLocked: false, idleSeconds: idle).allowsPush)
        }
    }

    @Test func unavailableSessionFailsOpenAndMissingLockFallsBackToIdle() {
        #expect(RemotePushMacPresence.from(session: nil, idleSeconds: 0).allowsPush)
        #expect(RemotePushMacPresence.from(session: [kCGSessionOnConsoleKey as String: NSNumber(value: false)], idleSeconds: 0).allowsPush)
        for session: [String: Any] in [[:], ["CGSSessionScreenIsLocked": "invalid"], ["CGSSessionScreenIsLocked": false]] {
            #expect(!RemotePushMacPresence.from(session: session, idleSeconds: 0).allowsPush)
            #expect(RemotePushMacPresence.from(session: session, idleSeconds: 120).allowsPush)
        }
        for locked in [NSNumber(value: true), NSNumber(value: 1)] {
            #expect(RemotePushMacPresence.from(session: [kCGSessionOnConsoleKey as String: NSNumber(value: true),
                "CGSSessionScreenIsLocked": locked], idleSeconds: 0).allowsPush)
        }
        for idle in [0.0, 120] {
            #expect(RemotePushMacPresence.from(session: [kCGSessionOnConsoleKey as String: true], idleSeconds: idle).allowsPush == (idle >= 120))
        }
    }
}
