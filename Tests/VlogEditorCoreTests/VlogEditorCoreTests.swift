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

final class ClaudePlannerTests: XCTestCase {
    let beach = MediaClip(url: URL(fileURLWithPath: "/tmp/beach.mov"), duration: 30)
    let car = MediaClip(url: URL(fileURLWithPath: "/tmp/car.mov"), duration: 20, hasAudio: false)
    let song = MediaClip(url: URL(fileURLWithPath: "/tmp/song.m4a"), duration: 120, hasVideo: false)

    func response(_ answer: [String: Any], stopReason: String = "end_turn") throws -> Data {
        let text = String(data: try JSONSerialization.data(withJSONObject: answer), encoding: .utf8)!
        return try JSONSerialization.data(withJSONObject: [
            "stop_reason": stopReason,
            "content": [["type": "text", "text": text]],
        ])
    }

    func testRequestCarriesDescriptionClipsFramesAndSchema() throws {
        let energy = AudioEnergy(windowSeconds: 0.5, values: [0.1, 0.1, 0.9, 0.9])
        let frame = ClipFrame(clipID: car.id, time: 5, jpeg: Data([0xFF, 0xD8]))
        let data = try ClaudePlanner.requestBody(brief: "open on the beach", clips: [beach, car, song],
                                                 energy: [beach.id: energy], frames: [frame])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let config = try XCTUnwrap(body["output_config"] as? [String: Any])
        XCTAssertEqual((config["format"] as? [String: Any])?["type"] as? String, "json_schema")

        let content = try XCTUnwrap(((body["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        let intro = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(intro.contains("open on the beach"))
        XCTAssertTrue(intro.contains("Clip 1: beach, 30.0s"))
        XCTAssertTrue(intro.contains("loudness per second (0 quiet to 9 loud): 19"))
        XCTAssertTrue(intro.contains("Clip 2: car, 20.0s, horizontal\n  no sound"))
        XCTAssertTrue(intro.contains("Music bed"))
        XCTAssertEqual(content[1]["text"] as? String, "Clip 2 at 5.0s:")
        XCTAssertEqual(content[2]["type"] as? String, "image")
    }

    func testAnswerBecomesPlanWithBadShotsFixed() throws {
        let data = try response([
            "shots": [
                ["clip": 1, "start": 2.0, "end": 6.5],
                ["clip": 2, "start": 18.0, "end": 25.0], // runs past the clip's end: trimmed to 20
                ["clip": 3, "start": 0, "end": 4],      // no such clip: dropped
                ["clip": 1, "start": 9.0, "end": 9.2],  // too short: dropped
            ],
            "cross_dissolves": true,
            "title": "  Beach Day ",
            "music_volume_db": -40,
            "summary": "Opens on the beach.",
        ])
        let plan = try ClaudePlanner.plan(fromResponse: data, clips: [beach, car, song])
        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0], Segment(clipID: beach.id, sourceStart: 2, duration: 4.5))
        XCTAssertEqual(plan.segments[1].clipID, car.id)
        XCTAssertEqual(plan.segments[1].duration, 2, accuracy: 0.001)
        XCTAssertEqual(plan.style.title, "Beach Day")
        XCTAssertTrue(plan.style.crossDissolves)
        XCTAssertEqual(plan.style.musicVolumeDB, -30)
        XCTAssertEqual(plan.music.map(\.id), [song.id])
        XCTAssertEqual(plan.notes, "Opens on the beach.")
    }

    func testRefusalAndEmptyPlansThrow() throws {
        let declined = try response([:], stopReason: "refusal")
        XCTAssertThrowsError(try ClaudePlanner.plan(fromResponse: declined, clips: [beach])) {
            XCTAssertEqual($0 as? ClaudePlanner.PlannerError, .declined)
        }
        let empty = try response(["shots": [], "cross_dissolves": false, "title": "", "music_volume_db": -14, "summary": ""])
        XCTAssertThrowsError(try ClaudePlanner.plan(fromResponse: empty, clips: [beach])) {
            XCTAssertEqual($0 as? ClaudePlanner.PlannerError, .noUsableShots)
        }
    }
}

final class BeatTests: XCTestCase {
    func testFindsTempoOfClickTrack() throws {
        // 20 seconds at 100 hops per second, a click every 0.5s (120 BPM) starting at 0.2s.
        var envelope = [Float](repeating: 0.01, count: 2000)
        var t = 20
        while t < envelope.count { for k in 0..<5 where t + k < envelope.count { envelope[t + k] = 0.8 }; t += 50 }
        let grid = try XCTUnwrap(BeatDetector.detect(envelope: envelope, hop: 0.01))
        XCTAssertEqual(grid.bpm, 120, accuracy: 3)
        let nearFive = try XCTUnwrap(grid.beats.min { abs($0 - 5.2) < abs($1 - 5.2) })
        XCTAssertEqual(nearFive, 5.2, accuracy: 0.05)
    }

    func testSnapsCutsOntoBeatsWithinClips() {
        let a = MediaClip(url: URL(fileURLWithPath: "/tmp/a.mov"), duration: 10)
        let b = MediaClip(url: URL(fileURLWithPath: "/tmp/b.mov"), duration: 3.1)
        let segments = [
            Segment(clipID: a.id, sourceStart: 1, duration: 2.8),   // cut at 2.8 -> beat 3.0
            Segment(clipID: b.id, sourceStart: 0, duration: 3.0),   // cut at 6.0, but only 3.1s of clip b: beat 6.0 fits
            Segment(clipID: a.id, sourceStart: 5, duration: 2),
        ]
        let beats = stride(from: 0.0, to: 20, by: 1.5).map { $0 }
        let snapped = BeatSnapper.snap(segments, to: beats, clips: [a, b])
        XCTAssertEqual(snapped[0].duration, 3.0, accuracy: 0.001)
        XCTAssertEqual(snapped[0].duration + snapped[1].duration, 6.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(snapped[1].sourceEnd, b.duration)
        XCTAssertEqual(snapped[2].duration, 2)
    }
}

final class CaptionTests: XCTestCase {
    func testWordsFollowTheEditAndGroupAtPauses() {
        let clip = MediaClip(url: URL(fileURLWithPath: "/tmp/talk.mov"), duration: 60)
        let words = ["Hey", "everyone", "welcome", "back", "today", "we're", "in", "Lisbon"].enumerated().map {
            SpokenWord(text: $1, start: 10 + Double($0) * 0.4, duration: 0.3)
        } + [SpokenWord(text: "cut", start: 30, duration: 0.3)]
        let plan = EditPlan(segments: [
            Segment(clipID: clip.id, sourceStart: 50, duration: 2),   // no speech
            Segment(clipID: clip.id, sourceStart: 9.5, duration: 4),  // the first 8 words
        ], music: [], style: EditStyle())
        let captions = CaptionBuilder.captions(plan: plan, words: [clip.id: words])
        XCTAssertEqual(captions.map(\.text), ["Hey everyone welcome back today we're", "in Lisbon"])
        XCTAssertEqual(captions[0].start, 2.5, accuracy: 0.001)   // 2s of first shot + 0.5s in
        XCTAssertLessThanOrEqual(captions[0].end, captions[1].start)
        XCTAssertFalse(captions.contains { $0.text.contains("cut") })
    }

    func testParserTurnsOnCaptionsAndBeatOptOut() {
        XCTAssertTrue(EditBriefParser.parse("add subtitles please").captions)
        XCTAssertFalse(EditBriefParser.parse("no captions").captions)
        XCTAssertFalse(EditBriefParser.parse("ignore the beat").cutToBeat)
        XCTAssertTrue(EditBriefParser.parse("a fun vlog").cutToBeat)
    }

    func testCaptionsLandInTheFinalCutProject() throws {
        let clip = MediaClip(url: URL(fileURLWithPath: "/tmp/talk.mov"), duration: 20)
        var plan = EditPlan(segments: [Segment(clipID: clip.id, sourceStart: 2, duration: 5),
                                       Segment(clipID: clip.id, sourceStart: 10, duration: 5)],
                            music: [], style: EditStyle())
        plan.captions = [Caption(start: 1, duration: 2, text: "hello"), Caption(start: 6, duration: 1.5, text: "there & back")]
        let doc = FCPXMLBuilder(projectName: "C", eventName: "E", canvasWidth: 1080, canvasHeight: 1920).build(plan: plan, clips: [clip])
        let parsed = try XMLDocument(xmlString: doc, options: [])
        let titles = try parsed.nodes(forXPath: "//title[@lane='2']")
        XCTAssertEqual(titles.count, 2)
        // The second caption starts 1s into the second shot, whose source starts at 10s.
        let second = try XCTUnwrap(titles.last as? XMLElement)
        XCTAssertEqual(second.attribute(forName: "offset")?.stringValue, "11s")
        XCTAssertEqual(try parsed.nodes(forXPath: "//effect").count, 1)
        XCTAssertTrue(doc.contains("there &amp; back"))
    }
}

final class VisualPlannerTests: XCTestCase {
    func testPrefersSharpSteadyMomentsWithoutSound() {
        let clip = MediaClip(url: URL(fileURLWithPath: "/tmp/silent.mov"), duration: 20, hasAudio: false)
        let times = stride(from: 1.0, to: 20, by: 1.5).map { $0 }
        let scores = times.map { $0 > 12 && $0 < 16 ? Float(0.95) : Float(0.1) }
        let plan = EditPlanner.plan(clips: [clip], style: EditStyle(targetDuration: 3),
                                    visual: [clip.id: VisualProfile(times: times, scores: scores)])
        XCTAssertEqual(plan.segments.count, 1)
        XCTAssertGreaterThanOrEqual(plan.segments[0].sourceStart, 11)
        XCTAssertLessThanOrEqual(plan.segments[0].sourceEnd, 17)
    }
}
