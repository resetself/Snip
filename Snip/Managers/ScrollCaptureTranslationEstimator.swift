import CoreGraphics

/// Estimates the vertical movement between two scroll-capture viewports.
///
/// The matcher deliberately uses several spatial regions. A fixed line-number gutter,
/// minimap, tab bar, or status bar can therefore be rejected as an outlier instead of
/// dominating one whole-image registration result.
nonisolated struct ScrollCaptureTranslationEstimator: Sendable {
    enum Status: Equatable, Sendable {
        case accepted
        case duplicate
        case ambiguous
        case invalid
    }

    struct Result: Sendable {
        let status: Status
        let verticalOffsetInPixels: Int
        let confidence: Double
        let ambiguity: Double
        let supportingRegions: Int
        let bestScore: Double
        let secondBestScore: Double?
    }

    struct Configuration: Sendable {
        var maximumAnalysisWidth = 400
        var minimumOffset = 1
        var maximumOffsetFraction = 0.82
        var sampleStepX = 2
        var sampleStepY = 2
        var minimumRegionEdgeSamples = 3
        var maximumAcceptedScore = 32.0
        var minimumSupportingRegions = 3
        var ambiguityScoreGap = 1.8
        var ambiguityRatio = 1.08
        var duplicateScore = 2.0
    }

    private struct GrayImage {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private struct Candidate {
        let offset: Int
        let score: Double
        let supportingRegions: Int
    }

    private let configuration: Configuration

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    func estimate(
        previous: CGImage,
        current: CGImage,
        expectedDirection: Int = 0
    ) -> Result {
        guard previous.width == current.width,
              previous.height == current.height,
              let previousGray = makeGrayImage(previous),
              let currentGray = makeGrayImage(current),
              previousGray.width == currentGray.width,
              previousGray.height == currentGray.height else {
            return invalidResult()
        }

        let duplicateScore = samePositionScore(previous: previousGray, current: currentGray)
        // A one-pixel code scroll can look nearly identical under sparse sampling.
        // With a known pending scroll direction, only an effectively exact frame is a
        // duplicate; otherwise continue into integer-offset registration.
        if duplicateScore <= configuration.duplicateScore,
           expectedDirection == 0 || duplicateScore <= 0.05 {
            return Result(
                status: .duplicate,
                verticalOffsetInPixels: 0,
                confidence: 1,
                ambiguity: 0,
                supportingRegions: 25,
                bestScore: duplicateScore,
                secondBestScore: nil
            )
        }

        let maximumOffset = max(
            configuration.minimumOffset,
            Int(Double(previousGray.height) * configuration.maximumOffsetFraction)
        )
        let sparseCandidates = sparsePixelCandidates(
            previous: previousGray,
            current: currentGray,
            maximumOffset: maximumOffset
        )
        var offsetsToValidate = Set<Int>()
        for candidate in sparseCandidates {
            for offset in max(-maximumOffset, candidate - 2)...min(maximumOffset, candidate + 2)
                where abs(offset) >= configuration.minimumOffset {
                offsetsToValidate.insert(offset)
            }
        }
        let candidates = offsetsToValidate.map {
            score(previous: previousGray, current: currentGray, offset: $0)
        }

        let ranked = candidates
            .filter { $0.supportingRegions >= configuration.minimumSupportingRegions }
            .sorted { $0.score < $1.score }
        guard let best = ranked.first,
              best.score <= configuration.maximumAcceptedScore else {
            return invalidResult(best: ranked.first)
        }

        // Adjacent offsets describe the same sub-pixel minimum. The competing candidate
        // must be spatially separate before it can make the result ambiguous.
        let exclusionRadius = max(2, configuration.minimumOffset / 2)
        let second = ranked.first { abs($0.offset - best.offset) > exclusionRadius }
        let scoreGap = (second?.score ?? configuration.maximumAcceptedScore) - best.score
        let scoreRatio = (second?.score ?? configuration.maximumAcceptedScore) / max(best.score, 0.001)
        let isAmbiguous = second != nil
            && scoreGap < configuration.ambiguityScoreGap
            && scoreRatio < configuration.ambiguityRatio

        // Wheel events are asynchronous with screenshot delivery. They may constrain a
        // result but must never force the matcher to search only the wrong direction.
        if expectedDirection != 0,
           best.offset.signum() != expectedDirection.signum() {
            return invalidResult(best: best)
        }

        let confidence = max(0, min(1, 1 - best.score / configuration.maximumAcceptedScore))
        let ambiguity = second.map { _ in
            max(0, min(1, 1 - scoreGap / configuration.ambiguityScoreGap))
        } ?? 0
        let originalPixelOffset = Int(
            (Double(best.offset) * Double(previous.height) / Double(previousGray.height)).rounded()
        )
        return Result(
            status: isAmbiguous ? .ambiguous : .accepted,
            verticalOffsetInPixels: originalPixelOffset,
            confidence: confidence,
            ambiguity: ambiguity,
            supportingRegions: best.supportingRegions,
            bestScore: best.score,
            secondBestScore: second?.score
        )
    }

    private func samePositionScore(previous: GrayImage, current: GrayImage) -> Double {
        var difference = 0.0
        var count = 0
        for y in stride(from: 0, to: previous.height, by: configuration.sampleStepY) {
            for x in stride(from: 0, to: previous.width, by: configuration.sampleStepX) {
                difference += Double(abs(
                    Int(previous.bytes[y * previous.width + x])
                        - Int(current.bytes[y * current.width + x])
                ))
                count += 1
            }
        }
        return count > 0 ? difference / Double(count) : .infinity
    }

    private func score(
        previous: GrayImage,
        current: GrayImage,
        offset: Int,
        sampleStepX: Int? = nil,
        sampleStepY: Int? = nil
    ) -> Candidate {
        let stepX = sampleStepX ?? configuration.sampleStepX
        let stepY = sampleStepY ?? configuration.sampleStepY
        let overlapHeight = previous.height - abs(offset)
        guard overlapHeight >= max(24, previous.height / 8) else {
            return Candidate(offset: offset, score: .infinity, supportingRegions: 0)
        }

        // Fine-grained voting separates code text from a gutter, minimap, header, and
        // status bar. Regions unchanged at the same screen coordinates are fixed chrome
        // and must never vote for a non-zero document translation.
        let gridSize = 5
        var regionScores: [(score: Double, row: Int)] = []
        let columnBounds = (0...gridSize).map { $0 * previous.width / gridSize }
        let rowBounds = (0...gridSize).map { $0 * overlapHeight / gridSize }

        for row in 0..<gridSize {
            for column in 0..<gridSize {
                let x0 = columnBounds[column]
                let x1 = columnBounds[column + 1]
                let y0 = rowBounds[row]
                let y1 = rowBounds[row + 1]
                var difference = 0.0
                var samePositionDifference = 0.0
                var edgeSamples = 0
                var count = 0
                var previousSample: Int?

                for overlapY in stride(from: y0, to: y1, by: stepY) {
                    let previousY = offset >= 0 ? overlapY + offset : overlapY
                    let currentY = offset >= 0 ? overlapY : overlapY - offset
                    for x in stride(from: x0, to: x1, by: stepX) {
                        let lhs = Int(previous.bytes[previousY * previous.width + x])
                        let rhs = Int(current.bytes[currentY * current.width + x])
                        difference += Double(abs(lhs - rhs))

                        // Fixed chrome stays equal at the same viewport coordinate even
                        // while the document behind it scrolls.
                        let screenY = min(overlapY, previous.height - 1)
                        let previousAtScreenPosition = Int(previous.bytes[screenY * previous.width + x])
                        let currentAtScreenPosition = Int(current.bytes[screenY * current.width + x])
                        samePositionDifference += Double(
                            abs(previousAtScreenPosition - currentAtScreenPosition)
                        )

                        if let previousSample, abs(lhs - previousSample) >= 12 {
                            edgeSamples += 1
                        }
                        previousSample = lhs
                        count += 1
                    }
                }

                guard count > 0 else { continue }
                let meanSamePositionDifference = samePositionDifference / Double(count)
                guard edgeSamples >= configuration.minimumRegionEdgeSamples,
                      meanSamePositionDifference > configuration.duplicateScore else { continue }
                regionScores.append((difference / Double(count), row))
            }
        }

        guard regionScores.count >= configuration.minimumSupportingRegions else {
            return Candidate(offset: offset, score: .infinity, supportingRegions: regionScores.count)
        }

        regionScores.sort { $0.score < $1.score }
        // The moving document can be only the center column when a code editor has a
        // gutter, minimap, header, and status bar. Find the smallest low-error consensus
        // that spans the viewport vertically instead of requiring five of nine regions.
        var selectedScore = Double.infinity
        var selectedSupport = 0
        for anchor in regionScores {
            let tolerance = max(3, anchor.score * 0.25)
            let supporters = regionScores.filter { abs($0.score - anchor.score) <= tolerance }
            let representedRows = Set(supporters.map(\.row)).count
            guard supporters.count >= configuration.minimumSupportingRegions,
                  representedRows >= 2 else { continue }
            let consensusScore = supporters.map(\.score).reduce(0, +) / Double(supporters.count)
            if consensusScore < selectedScore {
                selectedScore = consensusScore
                selectedSupport = supporters.count
            }
        }
        return Candidate(
            offset: offset,
            score: selectedScore,
            supportingRegions: selectedSupport
        )
    }

    private func sparsePixelCandidates(
        previous: GrayImage,
        current: GrayImage,
        maximumOffset: Int
    ) -> [Int] {
        var candidatesByPhase: [[Candidate]] = [[], []]
        let samplingPhases = [(x: 11, y: 5), (x: 13, y: 7)]
        for offset in -maximumOffset...maximumOffset where abs(offset) >= configuration.minimumOffset {
            for (index, phase) in samplingPhases.enumerated() {
                candidatesByPhase[index].append(score(
                    previous: previous,
                    current: current,
                    offset: offset,
                    sampleStepX: phase.x,
                    sampleStepY: phase.y
                ))
            }
        }

        var selected: [Int] = []
        for candidates in candidatesByPhase {
            let ranked = candidates
                .filter { $0.score.isFinite }
                .sorted { $0.score < $1.score }
            var added = 0
            for candidate in ranked {
                guard added < 8 else { break }
                if !selected.contains(where: { abs($0 - candidate.offset) <= 3 }) {
                    selected.append(candidate.offset)
                    added += 1
                }
            }
        }
        return selected
    }

    private func makeGrayImage(_ image: CGImage) -> GrayImage? {
        // Horizontal downscaling is safe for a vertical translation estimate. Preserve
        // vertical source pixels whenever practical: fractional Y scaling destroys code
        // line periodicity and can move the best match by one or more text rows.
        let horizontalScale = min(
            1,
            CGFloat(configuration.maximumAnalysisWidth) / CGFloat(image.width)
        )
        let width = max(1, Int((CGFloat(image.width) * horizontalScale).rounded()))
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let created = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return created ? GrayImage(width: width, height: height, bytes: bytes) : nil
    }

    private func invalidResult(best: Candidate? = nil) -> Result {
        Result(
            status: .invalid,
            verticalOffsetInPixels: 0,
            confidence: 0,
            ambiguity: 1,
            supportingRegions: best?.supportingRegions ?? 0,
            bestScore: best?.score ?? .infinity,
            secondBestScore: nil
        )
    }
}
