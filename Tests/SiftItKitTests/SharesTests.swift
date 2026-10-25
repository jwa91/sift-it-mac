import Testing

@testable import SiftItKit

@Test func theCellsAddUpToTheGrid() {
    #expect(Shares.cells([1200, 300], of: 100) == [80, 20])
    // 33.3 each: the one left over goes to the first of the largest remainders.
    #expect(Shares.cells([1, 1, 1], of: 100) == [34, 33, 33])
    #expect(Shares.cells([996, 3, 1], of: 100) == [100, 0, 0])
    #expect(Shares.cells([5, 5], of: 60) == [30, 30])
    #expect(Shares.cells([0, 0], of: 100) == [0, 0])
    #expect(Shares.cells([7, 2], of: 0) == [0, 0])
}

@Test func aShareIsSaidInWholePercents() {
    #expect(Shares.percent(450, of: 1000) == "45%")
    #expect(Shares.percent(1, of: 1000) == "<1%")
    #expect(Shares.percent(0, of: 1000) == "0%")
    #expect(Shares.percent(3, of: 0) == "0%")
}
