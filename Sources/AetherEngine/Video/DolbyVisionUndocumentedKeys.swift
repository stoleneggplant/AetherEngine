import Foundation

/// UNDOCUMENTED: CoreVideo attachment keys Apple does not publish. Every one the engine relies on lives
/// here, so a tvOS / iOS release that renames or drops one has a single place to look (AE#702).
///
/// VideoToolbox puts these on the pixel buffers it decodes from a Dolby Vision stream when
/// `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata` is on, and
/// `AVSampleBufferDisplayLayer` reads them to apply the frame's Dolby Vision display management.
/// Measured in AE#702 on an Apple TV 4K (2nd gen), tvOS 27, into an LG C1: composed frames carrying
/// both keys made the panel follow the per-frame RPU (the same pulse AVPlayer produces); the same
/// frames with both keys removed gave a flat response at every patch from 10 to 10000 nits.
///
/// `DolbyVisionFELDecoder` copies them from each decoded base-layer picture onto its composed
/// picture. It never builds the values itself: the base layer is decoded as Profile 8.1, so what
/// VideoToolbox attaches is already the identity-mapped RPU the composed picture needs.
enum DolbyVisionUndocumentedKeys {

    /// UNDOCUMENTED. The frame's RPU as VideoToolbox attaches it: per AE#702, the `unspec62` NAL unit
    /// without its two-byte header, emulation-prevention bytes kept.
    static let rpuData = "DolbyVisionRPUData"

    /// UNDOCUMENTED. The stream's base-layer signal compatibility, attached next to the RPU.
    static let compatibilityID = "DolbyCompatibilityID"

    /// Every key a composed Dolby Vision picture has to carry over from its base picture.
    static let perFrameMetadata: [String] = [rpuData, compatibilityID]
}
