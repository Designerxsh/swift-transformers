import Foundation

/// Top-P.
/// Select the smallest set of elements whose cumulative probability exceeds the probability `p`.
/// Based on https://gist.github.com/thomwolf/1a5a29f6962089e871b94cbd09daf317
public struct TopPLogitsWarper: LogitsWarper {
    public var p: Float

    public init(p: Float) {
        self.p = p
    }

    public func warp(_ arr: [Float]) -> (indexes: [Int], logits: [Float]) {
        guard !arr.isEmpty else {
            return (indexes: [], logits: [])
        }

        let arrSoftmax = Math.softmax(arr)
        var indexLogitProb = [(index: Int, logit: Float, prob: Float)]()
        indexLogitProb.reserveCapacity(arr.count)
        for (index, data) in zip(arr, arrSoftmax).enumerated() {
            indexLogitProb.append((index: index, logit: data.0, prob: data.1))
        }
        indexLogitProb.sort { $0.prob > $1.prob }

        let cumsum = Math.cumsum(indexLogitProb.map(\.prob))
        var sliceIndex = cumsum.count - 1
        for (index, element) in cumsum.enumerated() where element > p {
            sliceIndex = index
            break
        }

        let indexes = indexLogitProb[0 ... sliceIndex].map(\.index)
        let logits = indexLogitProb[0 ... sliceIndex].map(\.logit)
        return (indexes: indexes, logits: logits)
    }
}
