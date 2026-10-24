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

@Test func eventsRead() {
    let ready = Event.decode(
        Data(#"{"event":"ready","version":"0.3.1","build":"b","index":"/i","meaning":"unloaded"}"#.utf8))
    #expect(ready == .ready(Ready(version: "0.3.1", build: "b", index: "/i", meaning: .unloaded)))
    #expect(Event.decode(Data(#"{"event":"meaning","state":"loading"}"#.utf8)) == .meaning(.loading, error: nil))
    let indexer = Event.decode(
        Data(#"{"event":"indexer","pid":7,"state":"indexing","detail":null,"done":3,"total":4,"updated":1}"#.utf8))
    guard case .indexer(let status)? = indexer else {
        Issue.record("not an indexer event")
        return
    }
    #expect(status.progress == 0.75)
    #expect(status.isWorking)
    #expect(Event.decode(Data(#"{"id":1,"ok":true}"#.utf8)) == nil)
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
