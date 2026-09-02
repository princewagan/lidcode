import Foundation
import Testing
@testable import WarpMonitor

// MARK: - FolderResolutionTests
//
// Guards the placement half of the "one row per session" model.
//
// Placement decides which GROUP a session's row is drawn under. It must never
// decide the session's status — that comes only from the session's own event
// stream. These tests exist because the previous implementation conflated the
// two: it located a session by sort position within a folder and then took its
// status from whatever it landed on, so statuses appeared on the wrong rows and
// spread across a folder as the ordering shifted.

@Suite("Folder resolution")
struct FolderResolutionTests {

    // MARK: - resolveFolder

    @Test("Exact cwd match wins")
    func testExactMatch() {
        let m = StateManager()
        let folders = ["/Users/p/television": "TELEVISION",
                       "/Users/p/advoroads": "ADVO ROADS"]
        let hit = m.resolveFolder(for: "/Users/p/television", in: folders)
        #expect(hit?.value == "TELEVISION")
        #expect(hit?.key == "/Users/p/television")
    }

    @Test("A session in a subdirectory resolves to its parent folder")
    func testAncestorMatch() {
        // Real case: Claude started in television/mac-app while the open tab is
        // at television. That work belongs on screen next to its folder, not in
        // a separate orphan list.
        let m = StateManager()
        let folders = ["/Users/p/television": "TELEVISION"]
        let hit = m.resolveFolder(for: "/Users/p/television/mac-app", in: folders)
        #expect(hit?.value == "TELEVISION")
    }

    @Test("The deepest matching ancestor wins, not the shallowest")
    func testDeepestAncestorWins() {
        let m = StateManager()
        let folders = ["/Users/p": "HOME",
                       "/Users/p/advoroads": "ADVO ROADS"]
        let hit = m.resolveFolder(for: "/Users/p/advoroads/process/features/mmda-pitch",
                                  in: folders)
        #expect(hit?.value == "ADVO ROADS",
            "mmda-pitch is inside advoroads; resolving to HOME would be a worse answer")
    }

    @Test("Ancestor matching respects path boundaries")
    func testNoSubstringFalsePositive() {
        // "/Users/p/fourlinq-management" must NOT be treated as living inside
        // "/Users/p/fourlinq", even though one is a string prefix of the other.
        // A raw hasPrefix check here would merge two unrelated projects.
        let m = StateManager()
        let folders = ["/Users/p/fourlinq": "FOURLINQ"]
        let hit = m.resolveFolder(for: "/Users/p/fourlinq-management", in: folders)
        #expect(hit == nil, "fourlinq-management is a sibling of fourlinq, not a child")
    }

    @Test("A cwd outside every open folder resolves to nothing")
    func testNoMatchIsNil() {
        let m = StateManager()
        let folders = ["/Users/p/television": "TELEVISION"]
        #expect(m.resolveFolder(for: "/tmp/somewhere-else", in: folders) == nil,
            "An unmatched cwd must fall through to the orphan list, not be guessed into a folder")
    }

    // MARK: - namesMatch

    @Test("Group names match folder names across casing and separators")
    func testNamesMatch() {
        let m = StateManager()
        // Two tabs can share a cwd while sitting in different groups. There is no
        // fact about which group owns the folder, so we prefer the group whose
        // name is the folder's name rather than whichever was enumerated first.
        #expect(m.namesMatch("TELEVISION", "television"))
        #expect(m.namesMatch("ADVO ROADS", "advoroads"))
        #expect(m.namesMatch("Advo-Roads", "advoroads"))
        #expect(!m.namesMatch("LIDDY", "television"))
        #expect(!m.namesMatch("", "television"), "An empty group name must not match everything")
    }

    // MARK: - Status independence

    @Test("Hysteresis is keyed per session, never per position")
    func testHysteresisIsPerSession() {
        // activityStatus extends the running window only for a session that was
        // already running. Feeding it a *different* session's previous status is
        // exactly how a tab used to inherit a neighbour's state, so the caller
        // must key this on session id. Here we prove the two inputs genuinely
        // produce different answers, which is why the key matters.
        let m = StateManager()
        let justPastWindow = Date().addingTimeInterval(-(StateManager.activityWindow + 5))

        let wasRunning = m.activityStatus(transcriptMtime: justPastWindow,
                                          currentStatus: .running,
                                          logStatus: .running)
        let wasFinished = m.activityStatus(transcriptMtime: justPastWindow,
                                           currentStatus: .finished,
                                           logStatus: .running)

        #expect(wasRunning == .running, "Grace period applies to a session already running")
        #expect(wasFinished == .finished, "No grace for a session that was not running")
    }

    @Test("Blocked and error are returned untouched regardless of transcript age")
    func testStickyStatesSurviveQuietTranscripts() {
        // A blocked session waiting overnight must still read as blocked in the
        // morning. Time must never silently downgrade a state that needs a human.
        let m = StateManager()
        let ancient = Date().addingTimeInterval(-72 * 3600)

        #expect(m.activityStatus(transcriptMtime: ancient,
                                 currentStatus: .finished,
                                 logStatus: .blocked) == .blocked)
        #expect(m.activityStatus(transcriptMtime: ancient,
                                 currentStatus: .finished,
                                 logStatus: .error) == .error)
    }
}
