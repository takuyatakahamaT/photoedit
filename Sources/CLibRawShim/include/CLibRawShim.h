#ifndef PHOTOBENCH_CLIBRAWSHIM_H
#define PHOTOBENCH_CLIBRAWSHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Everything `Sources/PhotoCore/LibRawDecoder.swift` needs from one RAW
/// file, produced by a single open+unpack+dcraw_process+make_mem_image
/// round trip so Swift never has to touch the giant, version-fragile
/// `libraw_data_t` layout directly (see `docs/PHASE1_BASE_RENDERING.md`
/// B2 "LibRawの取り込み").
typedef struct {
    /// Interleaved unsigned 16-bit samples, `colors` channels per pixel,
    /// `width * height * colors` entries. Owned; free with
    /// `clibraw_shim_free`.
    unsigned short *pixels;
    size_t pixelCount;
    int width;
    int height;
    int colors;
    int bits;

    /// `raw->color.cam_mul` / `pre_mul` (R, G1, B, G2 order, as LibRaw
    /// stores them).
    float camMul[4];
    float preMul[4];

    char make[64];
    char model[64];
    char normalizedMake[64];
    char normalizedModel[64];

    unsigned int black;
    unsigned int maximum;

    float isoSpeed;
    float shutter;
    float aperture;
    float focalLength;
    char lensName[128];

    /// The RAW's true full-resolution pixel size, captured before
    /// `half_size` (if requested) shrinks the processed output -- this is
    /// what `DecodeInfo.nativeWidth/nativeHeight` must report regardless of
    /// which size was actually decoded.
    int nativeWidth;
    int nativeHeight;
    /// 1 if `half_size` was actually requested for this decode, else 0.
    int appliedHalfSize;
} CLibRawShimResult;

/// Decodes `path` with the phase1 base-rendering settings (output_color=0,
/// use_camera_wb=1, no_auto_bright=1, gamm=[1,1], output_bps=16,
/// highlight=0, user_qual=3(AHD), half_size as requested).
///
/// Returns 0 on success (`outResult` is populated and must be released with
/// `clibraw_shim_free`); otherwise returns a LibRaw error code (negative;
/// see `clibraw_shim_strerror`) and `outResult` is left zeroed.
int clibraw_shim_decode(const char *path, int halfSize, CLibRawShimResult *outResult);

/// Releases the pixel buffer owned by a successful `clibraw_shim_decode`
/// result. Safe to call once on a zeroed/already-freed result (no-op).
void clibraw_shim_free(CLibRawShimResult *result);

/// `libraw_strerror`, exposed so Swift can build a readable error message.
const char *clibraw_shim_strerror(int errorCode);

#ifdef __cplusplus
}
#endif

#endif
