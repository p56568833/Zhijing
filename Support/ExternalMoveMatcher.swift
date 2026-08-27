import Foundation

struct ExternalMoveMatch: Equatable {
    let vanished: NoteDocument
    let destination: NoteDocument
}

/// 在知识库重新扫描后，把"旧路径消失的文稿"和"新出现的同内容文稿"配对，
/// 用于识别用户在 Finder 中移动（或重命名）文件的操作。
enum ExternalMoveMatcher {
    static func match(
        vanished: [NoteDocument],
        appeared: [NoteDocument]
    ) -> [ExternalMoveMatch] {
        var unused = appeared
        var matches: [ExternalMoveMatch] = []

        for document in vanished {
            let sameTitle = unused.filter { $0.title == document.title }
            let exact = sameTitle.filter {
                $0.size == document.size &&
                    abs($0.modifiedAt.timeIntervalSince(document.modifiedAt)) < 1
            }

            let destination: NoteDocument?
            if exact.count == 1 {
                destination = exact.first
            } else if sameTitle.count == 1 {
                destination = sameTitle.first
            } else {
                destination = nil
            }

            guard let destination else { continue }
            matches.append(
                ExternalMoveMatch(
                    vanished: document,
                    destination: destination
                )
            )
            unused.removeAll { $0.id == destination.id }
        }

        return matches
    }
}
