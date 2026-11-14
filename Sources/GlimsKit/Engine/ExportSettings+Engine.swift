import CGlimsEngine
import Foundation

extension ExportSettings {
    func nativeValue() throws -> GlimsExportSettings {
        guard Self.validate(self), !(format == .psd && (psdColor == .bitmap || psdColor == .duotone)) else {
            throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                                            message: "The export settings contain an invalid value.")
        }
        var value = GlimsExportSettings()
        value.struct_size = UInt32(MemoryLayout<GlimsExportSettings>.size)
        switch format {
        case .png: value.format = GLIMS_EXPORT_PNG.rawValue
        case .jpeg: value.format = GLIMS_EXPORT_JPEG.rawValue
        case .tiff: value.format = GLIMS_EXPORT_TIFF.rawValue
        case .psd: value.format = GLIMS_EXPORT_PSD.rawValue
        case .gif: value.format = GLIMS_EXPORT_GIF.rawValue
        case .bmp: value.format = GLIMS_EXPORT_BMP.rawValue
        case .tga: value.format = GLIMS_EXPORT_TGA.rawValue
        }
        value.jpeg_quality = jpegQuality
        value.jpeg_progressive = jpegProgressive ? 1 : 0
        value.jpeg_optimize = jpegOptimize ? 1 : 0
        switch jpegSubsampling {
        case .full: value.jpeg_subsampling = GLIMS_JPEG_FULL.rawValue
        case .horizontal: value.jpeg_subsampling = GLIMS_JPEG_HORIZONTAL.rawValue
        case .vertical: value.jpeg_subsampling = GLIMS_JPEG_VERTICAL.rawValue
        case .both: value.jpeg_subsampling = GLIMS_JPEG_BOTH.rawValue
        }
        value.png_compression = Int32(pngCompression)
        value.png_interlaced = pngInterlaced ? 1 : 0
        value.png_preserve_transparent_color = pngPreserveTransparentColor ? 1 : 0
        switch tiffCompression {
        case .none: value.tiff_compression = GLIMS_TIFF_NONE.rawValue
        case .lzw: value.tiff_compression = GLIMS_TIFF_LZW.rawValue
        case .deflate: value.tiff_compression = GLIMS_TIFF_DEFLATE.rawValue
        case .packBits: value.tiff_compression = GLIMS_TIFF_PACK_BITS.rawValue
        }
        value.tiff_preserve_transparent_color = tiffPreserveTransparentColor ? 1 : 0
        value.psd_layout = psdLayout == .layers ? GLIMS_PSD_LAYERS.rawValue : GLIMS_PSD_MERGED.rawValue
        return value
    }

    /// The captured CMYK profile bytes required for a PSD CMYK export, after
    /// validating the active export choice.
    func validatedPsdCmykProfileData() throws -> Data {
        guard format == .psd, psdColor == .cmyk else {
            throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                                            message: "CMYK profile data is only valid for PSD CMYK export.")
        }
        guard let profile = psdCmykProfile, PsdCmykProfile.isValidICCData(profile.iccData) else {
            throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                                            message: "Choose a valid CMYK profile before exporting.")
        }
        return profile.iccData
    }
}
