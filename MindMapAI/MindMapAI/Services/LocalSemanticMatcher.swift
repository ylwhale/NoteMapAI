import Foundation
import NaturalLanguage

/// A deliberately small seam around Apple's on-device sentence embeddings.
///
/// RetrievalEngine uses the protocol so deterministic tests can exercise the semantic admission
/// rules without depending on which Natural Language model revision is installed by the OS.
/// Production never sends text anywhere: `NLEmbedding` and the cosine calculation both run in the
/// current process.
nonisolated protocol LocalSemanticMatching: Sendable {
    /// Returns one cosine similarity per candidate. A nil entry means the local model could not
    /// embed that candidate. Values are clamped to 0...1; a higher value means greater similarity.
    func similarities(between query: String, and candidates: [String]) -> [Double?]
}

nonisolated struct AppleNaturalLanguageSemanticMatcher: LocalSemanticMatching {
    func similarities(between query: String, and candidates: [String]) -> [Double?] {
        guard !Task.isCancelled, !candidates.isEmpty else {
            return Array(repeating: nil, count: candidates.count)
        }

        let language = NLLanguageRecognizer.dominantLanguage(for: query) ?? .english
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language),
              let queryVector = embedding.vector(for: query),
              !queryVector.isEmpty else {
            return Array(repeating: nil, count: candidates.count)
        }

        var results: [Double?] = []
        results.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard !Task.isCancelled else {
                results.append(contentsOf: repeatElement(nil, count: candidates.count - results.count))
                break
            }
            guard let candidateVector = embedding.vector(for: candidate),
                  candidateVector.count == queryVector.count else {
                results.append(nil)
                continue
            }
            results.append(Self.cosineSimilarity(queryVector, candidateVector))
        }
        return results
    }

    private static func cosineSimilarity(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        var dotProduct = 0.0
        var lhsMagnitude = 0.0
        var rhsMagnitude = 0.0

        for index in lhs.indices {
            guard !Task.isCancelled else { return nil }
            let left = lhs[index]
            let right = rhs[index]
            dotProduct += left * right
            lhsMagnitude += left * left
            rhsMagnitude += right * right
        }

        let denominator = sqrt(lhsMagnitude) * sqrt(rhsMagnitude)
        guard denominator.isFinite, denominator > 0 else { return nil }
        let similarity = dotProduct / denominator
        guard similarity.isFinite else { return nil }
        return min(max(similarity, 0), 1)
    }
}
