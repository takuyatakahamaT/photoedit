#include "include/CLibRawShim.h"

#include <libraw/libraw.h>
#include <stdlib.h>
#include <string.h>

/// Sentinels for failures this shim detects itself (LibRaw's own codes never
/// go below LIBRAW_MEMPOOL_OVERFLOW == -100013, see libraw_const.h).
enum {
    CLIBRAW_SHIM_INIT_FAILED = -900001,
    CLIBRAW_SHIM_MAKE_MEM_IMAGE_FAILED = -900002,
    CLIBRAW_SHIM_ALLOCATION_FAILED = -900003,
};

static void copyCString(char *dest, size_t destSize, const char *src) {
    if (destSize == 0) {
        return;
    }
    if (src == NULL) {
        dest[0] = '\0';
        return;
    }
    strncpy(dest, src, destSize - 1);
    dest[destSize - 1] = '\0';
}

int clibraw_shim_decode(const char *path, int halfSize, CLibRawShimResult *outResult) {
    memset(outResult, 0, sizeof(*outResult));

    libraw_data_t *raw = libraw_init(0);
    if (raw == NULL) {
        return CLIBRAW_SHIM_INIT_FAILED;
    }

    int ret = libraw_open_file(raw, path);
    if (ret != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return ret;
    }

    /// Captured before touching `params`/`unpack`/`dcraw_process`: `identify()`
    /// (run inside `libraw_open_file`) already knows the RAW's true full
    /// visible pixel size, and `half_size` only shrinks it later inside
    /// `dcraw_process`'s `raw2image`. Reading it now -- rather than deriving
    /// it by doubling a possibly-halved `image->width/height` afterwards --
    /// keeps `nativeWidth/nativeHeight` exact regardless of rounding.
    int nativeWidth = raw->sizes.width;
    int nativeHeight = raw->sizes.height;

    raw->params.output_color = 0;
    raw->params.use_camera_wb = 1;
    raw->params.no_auto_bright = 1;
    raw->params.gamm[0] = 1.0;
    raw->params.gamm[1] = 1.0;
    raw->params.output_bps = 16;
    raw->params.highlight = 0;
    raw->params.user_qual = 3;
    raw->params.half_size = halfSize ? 1 : 0;

    ret = libraw_unpack(raw);
    if (ret != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return ret;
    }

    ret = libraw_dcraw_process(raw);
    if (ret != LIBRAW_SUCCESS) {
        libraw_close(raw);
        return ret;
    }

    int errc = 0;
    libraw_processed_image_t *image = libraw_dcraw_make_mem_image(raw, &errc);
    if (image == NULL) {
        libraw_close(raw);
        return errc != 0 ? errc : CLIBRAW_SHIM_MAKE_MEM_IMAGE_FAILED;
    }

    size_t pixelCount = (size_t)image->width * (size_t)image->height * (size_t)image->colors;
    unsigned short *buffer = (unsigned short *)malloc(pixelCount * sizeof(unsigned short));
    if (buffer == NULL) {
        libraw_dcraw_clear_mem(image);
        libraw_close(raw);
        return CLIBRAW_SHIM_ALLOCATION_FAILED;
    }
    memcpy(buffer, image->data, pixelCount * sizeof(unsigned short));

    outResult->pixels = buffer;
    outResult->pixelCount = pixelCount;
    outResult->width = image->width;
    outResult->height = image->height;
    outResult->colors = image->colors;
    outResult->bits = image->bits;

    memcpy(outResult->camMul, raw->color.cam_mul, sizeof(outResult->camMul));
    memcpy(outResult->preMul, raw->color.pre_mul, sizeof(outResult->preMul));
    copyCString(outResult->make, sizeof(outResult->make), raw->idata.make);
    copyCString(outResult->model, sizeof(outResult->model), raw->idata.model);
    copyCString(outResult->normalizedMake, sizeof(outResult->normalizedMake), raw->idata.normalized_make);
    copyCString(outResult->normalizedModel, sizeof(outResult->normalizedModel), raw->idata.normalized_model);
    outResult->black = raw->color.black;
    outResult->maximum = raw->color.maximum;
    outResult->isoSpeed = raw->other.iso_speed;
    outResult->shutter = raw->other.shutter;
    outResult->aperture = raw->other.aperture;
    outResult->focalLength = raw->other.focal_len;
    copyCString(outResult->lensName, sizeof(outResult->lensName), raw->lens.Lens);
    outResult->nativeWidth = nativeWidth;
    outResult->nativeHeight = nativeHeight;
    outResult->appliedHalfSize = raw->params.half_size ? 1 : 0;

    libraw_dcraw_clear_mem(image);
    libraw_close(raw);
    return 0;
}

void clibraw_shim_free(CLibRawShimResult *result) {
    if (result == NULL) {
        return;
    }
    if (result->pixels != NULL) {
        free(result->pixels);
        result->pixels = NULL;
    }
    result->pixelCount = 0;
}

const char *clibraw_shim_strerror(int errorCode) {
    switch (errorCode) {
    case CLIBRAW_SHIM_INIT_FAILED:
        return "libraw_init failed (out of memory)";
    case CLIBRAW_SHIM_MAKE_MEM_IMAGE_FAILED:
        return "libraw_dcraw_make_mem_image failed";
    case CLIBRAW_SHIM_ALLOCATION_FAILED:
        return "pixel buffer allocation failed";
    default:
        return libraw_strerror(errorCode);
    }
}
