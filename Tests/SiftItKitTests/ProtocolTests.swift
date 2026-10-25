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
         "bytes":81920},
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
    #expect(estimate.seconds(at: .speech) == 850)
    // Speech runs beside the rest, on its own chip: leaving it out saves nothing here.
    #expect(estimate.seconds(at: .meaning) == 850)
    #expect(estimate.seconds(at: .words) == 40)
}

@Test func aFolderReadLessDeeplyHasARuleOfItsOwn() throws {
    let rules = try JSONDecoder().decode(
        [JSON].self,
        from: Data(
            """
            [{"path":"*.psd","depth":"words"},{"path":"~/Movies/**","depth":"meaning"},
             {"path":"~/Movies/**","video":{"keep_every_s":10}}]
            """.utf8))
    let movies = "/Users/me/Movies"
    let music = "/Users/me/Music"
    let lower = Depth.rules(rules, reading: [movies: .words, music: .meaning], home: "/Users/me")
    #expect(
        JSON.array(lower).text
            == #"[{"depth":"words","path":"*.psd"},{"path":"~/Movies/**","video":{"keep_every_s":10}},"#
            + #"{"depth":"words","path":"~/Movies/**"},{"depth":"meaning","path":"~/Music/**"}]"#)
    // Read in full again, each loses its rule; the rules it didn't make stay.
    let full = Depth.rules(lower, reading: [movies: .speech, music: .speech], home: "/Users/me")
    #expect(full == [rules[0], rules[2]])
}

@Test func milestonesSayWhatCanBeFoundAlready() throws {
    guard case .indexer(let status)? = Event.decode(Data(indexerLine.utf8)) else {
        Issue.record("not an indexer event")
        return
    }
    #expect(Milestones.next(status) == "Searchable by words · documents by meaning 60% · about 12 min")
    #expect(
        Milestones.notYet(status)
            == "Documents: 60% by meaning · Photos: 0% looked at · Recordings: 40% written down")
    let states = status.rounds.map { Milestones.state(of: $0, in: status) }
    #expect(states == [nil, "60% · about 12 min", "Waiting for its turn", "40% · waiting for a charger"])

    let starting = IndexerStatus(
        pid: 7, state: .indexing,
        rounds: [
            RoundStatus(round: .words, state: .running, done: 0, total: 40),
            RoundStatus(round: .speech, state: .queued),
        ])
    #expect(Milestones.next(starting) == "Every file by its name and words 0%")
    #expect(Milestones.state(of: starting.rounds[0], in: starting) == "Starting…")
    let done = IndexerStatus(pid: 7, state: .idle, rounds: [RoundStatus(round: .words, state: .done)])
    #expect(Milestones.next(done) == nil)
    #expect(Milestones.notYet(done) == nil)
}

@Test func placesAreSaidAsInRaycast() throws {
    let hit = try JSONDecoder().decode(Hit.self, from: Data(videoHit.utf8))
    #expect(Format.location(of: hit) == "0:50")
    #expect(Format.span(of: hit) == "0:50–1:18")
    #expect(Format.timestamp(3723) == "1:02:03")
    #expect(Format.shortPath("/Users/me/Videos/a.mp4", home: "/Users/me") == "~/Videos/a.mp4")
    #expect(Format.folder(of: "/Users/me/Videos/a.mp4", home: "/Users/me") == "~/Videos")
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
