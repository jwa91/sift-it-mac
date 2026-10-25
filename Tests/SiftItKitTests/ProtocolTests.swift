import Foundation
import Testing

@testable import SiftItKit

/// A hit as the engine sends it (sift-it 0.3.1).
let videoHit = """
    {"path":"/Users/me/Videos/VID_3011.mp4","name":"VID_3011.mp4","kind":"video","segment":"speech",
     "segment_id":19664,"loc":50.72,"loc_end":78.56,"score":0.18,"lift":0.19,"cosine":0.74,"meaning":true,
     "words":false,"strong":true,"excerpt":"And then the dog runs into the water.","modified":1792572554.66,
     "size":4115376,"info":{"duration":230.41,"frames":89,"height":360,"speech":8,"tags":{},"width":640}}
    """

@Test func hitsReadAsTheEngineSendsThem() throws {
    let hit = try JSONDecoder().decode(Hit.self, from: Data(videoHit.utf8))
    #expect(hit.kind == .video)
    #expect(hit.segment == .speech)
    #expect(hit.segmentId == 19664)
    #expect(hit.loc == 50.72)
    #expect(hit.locEnd == 78.56)
    #expect(hit.info.duration == 230.41)
    #expect(hit.info.width == 640)
    #expect(hit.id == hit.path)
}

@Test func unknownNamesAndOddInfoDoNotBreakAHit() throws {
    let line = """
        {"path":"/a.xyz","name":"a.xyz","kind":"hologram","segment":"voxel","segment_id":1,"loc":null,
         "loc_end":null,"score":0.1,"meaning":false,"words":true,"strong":false,"excerpt":null,"modified":0,
         "size":1,"info":{"duration":"long","tags":{"title":"A"}}}
        """
    let hit = try JSONDecoder().decode(Hit.self, from: Data(line.utf8))
    #expect(hit.kind.rawValue == "hologram")
    #expect(hit.info.duration == nil)
    #expect(hit.info.tags["title"] == "A")
}

/// A conversation's hit as the engine sends it (sift-it with conversations, its tests' Codex log).
let conversationHit = """
    {"path":"/Users/me/.codex/sessions/2026/06/02/rollout.jsonl","name":"How long should sourdough proof?",
     "kind":"conversation","segment":"exchange","segment_id":1,"loc":1780408801.0,"loc_end":1780408809.0,
     "score":0.4,"meaning":true,"words":true,"strong":true,"excerpt":"User: How long should sourdough proof?",
     "modified":1780408809.0,"size":3400,"info":{"agent":"codex","cwd":"/Users/someone/projects/bakery",
     "resume":["codex","resume","019a3f2e-7c41-7d20-b8e5-5f0c9d1a2b3c"],
     "session":"019a3f2e-7c41-7d20-b8e5-5f0c9d1a2b3c","tags":{"title":"How long should sourdough proof?"}}}
    """

@Test func aConversationIsSaidByWhenAndWhereItRan() throws {
    let hit = try JSONDecoder().decode(Hit.self, from: Data(conversationHit.utf8))
    #expect(hit.kind == .conversation)
    #expect(hit.segment == .exchange)
    #expect(hit.name == "How long should sourdough proof?")
    #expect(hit.info.session == "019a3f2e-7c41-7d20-b8e5-5f0c9d1a2b3c")
    #expect(Format.agent(of: hit.info) == "Codex")
    #expect(Format.kindName(hit.kind) == "Conversation")
    // When it was said, to the minute, not a line.
    let utc = TimeZone(identifier: "UTC")!
    #expect(Format.when(1_780_408_801, locale: Locale(identifier: "en_GB"), timeZone: utc) == "2 Jun at 14:00")
    #expect(Format.location(of: hit) == Format.when(1_780_408_801))
    #expect(Format.when(1_780_408_801, time: false, locale: Locale(identifier: "en_GB"), timeZone: utc) == "2 Jun")
    #expect(Format.shortLocation(of: hit) == Format.when(1_780_408_801, time: false))
    #expect(
        Format.resumeCommand(of: hit.info)
            == "cd /Users/someone/projects/bakery && codex resume 019a3f2e-7c41-7d20-b8e5-5f0c9d1a2b3c")
    var odd = hit.info
    odd.cwd = "/Users/me/Ali's projects"
    odd.resume = ["claude", "--resume", "a b"]
    #expect(Format.resumeCommand(of: odd) == #"cd '/Users/me/Ali'\''s projects' && claude --resume 'a b'"#)
    #expect(Format.resumeCommand(of: Info()) == nil)
}

@Test func requestsWriteTheDocumentedLines() throws {
    let search = Request.search(Search(q: "dog", mode: .words, kinds: [.video], prefixLast: true))
    #expect(
        String(decoding: search.line(id: 3), as: UTF8.self)
            == #"{"id":3,"kinds":["video"],"limit":40,"mode":"words","op":"search","prefix_last":true,"q":"dog"}"#)
    #expect(String(decoding: Request.status.line(id: 1), as: UTF8.self) == #"{"id":1,"op":"status"}"#)
    #expect(
        String(decoding: Request.segmentText(12).line(id: 2), as: UTF8.self)
            == #"{"id":2,"op":"text","segment_id":12}"#)
    #expect(
        String(decoding: Request.folders(.add, paths: ["/a/b"]).line(id: 4), as: UTF8.self)
            == #"{"action":"add","id":4,"op":"folders","paths":["/a/b"]}"#)
    #expect(String(decoding: Request.stop.line(id: 5), as: UTF8.self) == #"{"id":5,"op":"stop"}"#)
    #expect(String(decoding: Request.unload.line(id: 6), as: UTF8.self) == #"{"id":6,"op":"unload"}"#)
}

/// The indexer's progress as the engine says it, in status.json, the `status` reply and the `indexer` event: words done,
/// documents by meaning running, speech waiting for a charger.
let indexerLine = """
    {"event":"indexer","pid":7,"state":"indexing","detail":"Waiting for a charger","rounds":[
     {"round":"words","state":"done","done":1234.0,"total":1234.0,"files":0,"seconds_left":null},
     {"round":"text","state":"running","done":12000.0,"total":20000.0,"files":310,"seconds_left":720.5},
     {"round":"pictures","state":"queued","done":0.0,"total":900.0,"files":900,"seconds_left":null},
     {"round":"speech","state":"waiting","done":14400.0,"total":36000.0,"files":12,"seconds_left":null}],
     "current":"/Users/me/Documents/notes.md","updated":1792572554.66,"last_error":null}
    """

@Test func eventsRead() throws {
    let ready = Event.decode(
        Data(#"{"event":"ready","version":"0.3.1","build":"b","index":"/i","meaning":"unloaded"}"#.utf8))
    #expect(ready == .ready(Ready(version: "0.3.1", build: "b", index: "/i", meaning: .unloaded)))
    #expect(Event.decode(Data(#"{"event":"meaning","state":"loading"}"#.utf8)) == .meaning(.loading, error: nil))
    guard case .indexer(let status)? = Event.decode(Data(indexerLine.utf8)) else {
        Issue.record("not an indexer event")
        return
    }
    #expect(status.isWorking)
    #expect(status.detail == "Waiting for a charger")
    #expect(status.rounds.map(\.round) == [.words, .text, .pictures, .speech])
    let text = try #require(status.rounds.dropFirst().first)
    #expect(text.state == .running)
    #expect(text.progress == 0.6)
    #expect(text.files == 310)
    #expect(text.secondsLeft == 720.5)
    #expect(status.rounds[0].secondsLeft == nil)
    #expect(Event.decode(Data(#"{"id":1,"ok":true}"#.utf8)) == nil)
}

@Test func theStatusReplyCarriesTheRounds() throws {
    let reply = """
        {"id":4,"meaning":"ready","error":null,"vectors":6500,"scan":"exact-f32","resident":21000000,
         "stats":{"files":3,"done":3,"pending":0,"failed":0,"segments":40,"vectors":6500,"by_kind":{"document":3},
         "vectors_by_kind":{"document":6500},"bytes":81920},
         "indexer":{"pid":7,"state":"waiting","detail":"Waiting: config.json can't be read: reading.depth",
         "rounds":[],"current":null,"updated":1,"last_error":null}}
        """
    let status = try JSONDecoder().decode(Status.self, from: Data(reply.utf8))
    #expect(status.indexer?.state == .waiting)
    #expect(status.indexer?.detail == "Waiting: config.json can't be read: reading.depth")
    #expect(status.indexer?.rounds == [])
    #expect(status.indexer?.isWorking == false)
}

@Test func estimatesSayWhatEachRoundTakes() throws {
    let line = """
        [{"folder":"/Users/me/Movies","files":1234,
          "rounds":[{"round":"words","total":1234,"unit":"files","seconds":40},
                    {"round":"text","total":20000,"unit":"passages","seconds":330},
                    {"round":"pictures","total":900,"unit":"pictures","seconds":110},
                    {"round":"sound","total":36000,"unit":"seconds","seconds":370},
                    {"round":"speech","total":36000,"unit":"seconds","seconds":165}],
          "seconds":850,"bytes":123456789,"by_kind":{"video":900,"audio":334},"unreadable":false}]
        """
    let estimate = try #require(try JSONDecoder().decode([Estimate].self, from: Data(line.utf8)).first)
    #expect(estimate.folder == "/Users/me/Movies")
    #expect(estimate.rounds.count == 5)
    #expect(estimate.rounds[1] == RoundEstimate(round: .text, total: 20000, unit: "passages", seconds: 330))
    #expect(estimate.byKind["video"] == 900)
    #expect(estimate.seconds(of: .exact) == 40)
    #expect(estimate.seconds(of: .embeddings) == 440)
    // The sound round listens after speech, so it finishes with Transcribed.
    #expect(estimate.seconds(of: .transcribed) == 535)
}

@Test func placesAreSaidAsInRaycast() throws {
    let hit = try JSONDecoder().decode(Hit.self, from: Data(videoHit.utf8))
    #expect(Format.location(of: hit) == "0:50")
    #expect(Format.span(of: hit) == "0:50–1:18")
    #expect(Format.timestamp(3723) == "1:02:03")
    #expect(Format.shortPath("/Users/me/Videos/a.mp4", home: "/Users/me") == "~/Videos/a.mp4")
    #expect(Format.folder(of: "/Users/me/Videos/a.mp4", home: "/Users/me") == "~/Videos")
    #expect(Format.kindCount(.init(rawValue: "document"), 900) == "900 documents")
    #expect(Format.kindCount(.init(rawValue: "audio"), 1) == "1 audio file")
    #expect(
        Kind.all.map(Format.kindsName) == [
            "Documents", "Text", "Pictures", "Screenshots", "Audio", "Videos", "Code", "Data", "Conversations",
        ])
    #expect(
        Format.leaving(.audio, indexed: ["audio": 85, "document": 3])
            == "85 audio files leave the index, transcripts included. Turning Audio on again indexes them again, "
            + "which can take a long time.")
    #expect(
        Format.leaving(.image, indexed: ["image": 240, "screenshot": 1])
            == "240 pictures and 1 screenshot leave the index. Turning Pictures on again indexes them again, "
            + "which can take a long time.")
    #expect(
        Format.leaving(.document, indexed: ["document": 1])
            == "1 document leaves the index. Turning Documents on again indexes it again, which can take a long time.")
    #expect(Format.leaving(.video, indexed: ["audio": 85, "video": 0]) == nil)
    #expect(Format.shortPath("/Users/meg/a", home: "/Users/me") == "/Users/meg/a")
    #expect(Format.bytes(4_115_376) == "3.9 MB")
    #expect(Format.duration(42) == "under a minute")
    #expect(Format.duration(720) == "about 12 min")
    #expect(Format.duration(7300) == "about 2 h")
    #expect(Format.words(of: "Hond, die het water-in rent!") == ["hond", "die", "het", "water", "in", "rent"])
}

@Test func aDeepDataFolderIsReachedThroughALink() throws {
    let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "deep/", count: 25))
    let address = try Places.socketAddress(dataFolder: deep)
    #expect(address.utf8.count < Places.sunPath)
    #expect(address.hasSuffix("/engine.sock"))
    let shallow = try Places.socketAddress(dataFolder: URL(fileURLWithPath: "/tmp/shallow"))
    #expect(shallow == "/tmp/shallow/engine.sock")
}
