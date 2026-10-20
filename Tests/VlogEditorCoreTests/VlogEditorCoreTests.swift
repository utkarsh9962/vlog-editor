import XCTest
@testable import VlogEditorCore

final class EditBriefParserTests: XCTestCase {
    func testReadsLengthPacingTitleAndTransitions() {
        let style = EditBriefParser.parse("A fast, upbeat 60 second travel vlog titled 'Lisbon Weekend' with smooth transitions")
        XCTAssertEqual(style.targetDuration, 60)
        XCTAssertEqual(style.pacing, .fast)
        XCTAssertEqual(style.title, "Lisbon Weekend")
        XCTAssertTrue(style.crossDissolves)
    }

    func testMinutesAndClockFormat() {
        XCTAssertEqual(EditBriefParser.parse("make it 2 minutes long").targetDuration, 120)
        XCTAssertEqual(EditBriefParser.parse("around 1:30, calm").targetDuration, 90)
        XCTAssertEqual(EditBriefParser.parse("around 1:30, calm").pacing, .relaxed)
    }

    func testKeepEverythingAndOrder() {
        let style = EditBriefParser.parse("just stitch them together in the same order, hard cuts")
        XCTAssertFalse(style.trimToHighlights)
        XCTAssertEqual(style.order, .asImported)
        XCTAssertFalse(style.crossDissolves)
    }

    func testTitleWordsDoNotTriggerKeywords() {
        let style = EditBriefParser.parse(#"vlog called "Fast Times""#)
        XCTAssertEqual(style.title, "Fast Times")
        XCTAssertEqual(style.pacing, .balanced)
    }
}

final class EditPlannerTests: XCTestCase {
    func clip(_ seconds: Double, daysAgo: Double = 0) -> MediaClip {
        MediaClip(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mov"), duration: seconds,
                  creationDate: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400))
    }

    func testHitsTargetDuration() {
        let clips = [clip(120), clip(60), clip(90)]
        let plan = EditPlanner.plan(clips: clips, style: EditStyle(targetDuration: 60, pacing: .fast))
        XCTAssertEqual(plan.duration, 60, accuracy: 6)
        XCTAssertTrue(plan.segments.allSatisfy { $0.duration >= EditPlanner.minimumShot })
        for seg in plan.segments {
            let source = clips.first { $0.id == seg.clipID }!
            XCTAssertGreaterThanOrEqual(seg.sourceStart, 0)
            XCTAssertLessThanOrEqual(seg.sourceEnd, source.duration)
        }
    }

    func testChronologicalOrder() {
        let late = clip(30, daysAgo: 0), early = clip(30, daysAgo: 2)
        let plan = EditPlanner.plan(clips: [late, early], style: EditStyle(trimToHighlights: false))
        XCTAssertEqual(plan.segments.map(\.clipID), [early.id, late.id])
    }

    func testPrefersLoudMoments() {
        let c = clip(20)
        var values = [Float](repeating: 0.01, count: 40)
        for i in 30..<36 { values[i] = 0.9 } // 15s to 18s is loud
        let plan = EditPlanner.plan(clips: [c], style: EditStyle(targetDuration: 3, pacing: .balanced),
                                    energy: [c.id: AudioEnergy(windowSeconds: 0.5, values: values)])
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertEqual(plan.segments[0].sourceStart, 15, accuracy: 0.5)
    }

    func testAudioFilesBecomeMusic() {
        let song = MediaClip(url: URL(fileURLWithPath: "/tmp/song.m4a"), duration: 200, hasVideo: false)
        let plan = EditPlanner.plan(clips: [clip(30), song], style: EditStyle())
        XCTAssertEqual(plan.music.map(\.id), [song.id])
        XCTAssertFalse(plan.segments.contains { $0.clipID == song.id })
    }
}

final class FCPXMLTests: XCTestCase {
    func testFrameRateTimes() {
        let ntsc = FrameRate.nearest(to: 29.98)
        XCTAssertEqual(ntsc.frameDuration, "1001/30000s")
        XCTAssertEqual(ntsc.time(frames: 30), "1001/1000s")
        XCTAssertEqual(FrameRate.nearest(to: 25).time(frames: 50), "2s")
        XCTAssertEqual(FrameRate.nearest(to: 24).time(frames: 0), "0s")
    }

    func testBuildsWellFormedProject() throws {
        let a = MediaClip(url: URL(fileURLWithPath: "/Users/me/Movies/Day One & Two.mov"), duration: 40, frameRate: 30)
        let b = MediaClip(url: URL(fileURLWithPath: "/Users/me/Movies/b.mp4"), duration: 30, frameRate: 30, width: 1080, height: 1920)
        let song = MediaClip(url: URL(fileURLWithPath: "/Users/me/Music/song.mp3"), duration: 300, hasVideo: false)
        let style = EditStyle(targetDuration: 30, crossDissolves: true, title: "Weekend <3")
        let plan = EditPlanner.plan(clips: [a, b, song], style: style)
        let doc = FCPXMLBuilder(projectName: "Test", eventName: "Vlog Editor", canvasWidth: 1080, canvasHeight: 1920)
            .build(plan: plan, clips: [a, b, song])

        let parsed = try XMLDocument(xmlString: doc, options: [])
        XCTAssertEqual(parsed.rootElement()?.attribute(forName: "version")?.stringValue, "1.10")
        XCTAssertEqual(try parsed.nodes(forXPath: "//asset").count, 3)
        XCTAssertEqual(try parsed.nodes(forXPath: "//spine/asset-clip").count, plan.segments.count)
        XCTAssertEqual(try parsed.nodes(forXPath: "//title").count, 1)
        XCTAssertEqual(try parsed.nodes(forXPath: "//asset-clip[@lane='-1']").count, 1)
        XCTAssertGreaterThan(try parsed.nodes(forXPath: "//spine/transition").count, 0)
        XCTAssertTrue(doc.contains("Day%20One%20&amp;%20Two.mov"))
        XCTAssertTrue(doc.contains(#"width="1080" height="1920" colorSpace"#))
    }
}
