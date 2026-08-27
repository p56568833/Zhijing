import Foundation
import Testing
@testable import Zhijing

private func makeDocument(
    _ path: String,
    modifiedAt: Date = Date(timeIntervalSinceReferenceDate: 1000),
    size: Int = 100
) -> NoteDocument {
    NoteDocument(
        url: URL(filePath: path),
        relativePath: path,
        modifiedAt: modifiedAt,
        size: size
    )
}

@Test func matchesMoveByTitleSizeAndTime() {
    let original = makeDocument("/lib/notes/草案.md", size: 320)
    let moved = makeDocument("/lib/archive/草案.md", size: 320)
    let unrelated = makeDocument("/lib/其他.md", size: 320)

    let matches = ExternalMoveMatcher.match(
        vanished: [original],
        appeared: [moved, unrelated]
    )

    #expect(matches == [ExternalMoveMatch(
        vanished: original,
        destination: moved
    )])
}

@Test func fallsBackToUniqueTitleWhenTimestampsDrift() {
    let original = makeDocument("/lib/notes/草案.md", size: 320)
    let moved = makeDocument(
        "/lib/草案.md",
        modifiedAt: Date(timeIntervalSinceReferenceDate: 1004),
        size: 320
    )
    let unrelated = makeDocument("/lib/其他.md", size: 320)

    let matches = ExternalMoveMatcher.match(
        vanished: [original],
        appeared: [moved, unrelated]
    )

    #expect(matches.count == 1)
    #expect(matches.first?.destination == moved)
}

@Test func picksExactMatchAmongEditedDuplicates() {
    let original = makeDocument("/lib/notes/草案.md", size: 320)
    let exact = makeDocument("/lib/草案.md", size: 320)
    let editedCopy = makeDocument(
        "/lib/backup/草案.md",
        modifiedAt: Date(timeIntervalSinceReferenceDate: 9999),
        size: 555
    )

    let matches = ExternalMoveMatcher.match(
        vanished: [original],
        appeared: [editedCopy, exact]
    )

    #expect(matches.count == 1)
    #expect(matches.first?.destination == exact)
}

@Test func skipsGenuinelyAmbiguousIdenticalCandidates() {
    let original = makeDocument("/lib/notes/草案.md", size: 320)
    let firstCopy = makeDocument("/lib/a/草案.md", size: 320)
    let secondCopy = makeDocument("/lib/b/草案.md", size: 320)

    let matches = ExternalMoveMatcher.match(
        vanished: [original],
        appeared: [firstCopy, secondCopy]
    )

    #expect(matches.isEmpty)
}

@Test func eachAppearedDocumentIsConsumedOnce() {
    let first = makeDocument("/lib/a/草案.md", size: 320)
    let second = makeDocument("/lib/b/草案.md", size: 320)
    let destination = makeDocument("/lib/草案.md", size: 320)

    let matches = ExternalMoveMatcher.match(
        vanished: [first, second],
        appeared: [destination]
    )

    #expect(matches.count == 1)
    #expect(matches.first?.vanished == first)
}

@Test func ignoresDifferentTitles() {
    let original = makeDocument("/lib/草案.md", size: 320)
    let renamed = makeDocument("/lib/新草案.md", size: 320)

    let matches = ExternalMoveMatcher.match(
        vanished: [original],
        appeared: [renamed]
    )

    #expect(matches.isEmpty)
}
