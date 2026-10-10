import Metal

/// この Mac で LLM 整形が実用になるかの判定材料。
public enum Machine {
    /// GPU に使えるメモリの上限（GB）。Apple Silicon は統合メモリなので、Metal が推奨する作業集合の上限を使う。
    /// 48 GB の Mac で 37.4 GB、24 GB で 18 GB 前後、8 GB で 5 GB 前後。
    public static let gpuMemoryGB: Double? = MTLCreateSystemDefaultDevice().map { Double($0.recommendedMaxWorkingSetSize) / 1_073_741_824 }

    /// LLM 整形を使える下限。「載る」ではなく「余裕を持って動く」で引く。
    /// 8 GB の Mac（約 5 GB）は 4B（常駐 3.5 GB）でもスワップに入り、速さが快適さの理由なので使えないことにする。
    /// 16 GB（約 11 GB）以上を可とする。16 GB は未計測で、予算に入らなければ温めの後の計測が知らせる。
    public static let formatterMinimumGPUMemoryGB = 10.0

    public static var supportsFormatter: Bool { supportsFormatter(gpuMemoryGB: gpuMemoryGB) }

    public static func supportsFormatter(gpuMemoryGB: Double?) -> Bool {
        (gpuMemoryGB ?? 0) >= formatterMinimumGPUMemoryGB
    }
}
