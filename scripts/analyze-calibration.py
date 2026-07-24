#!/usr/bin/env python3
"""Lightroom基準TIFFとPhoto Benchの16bit比較用TIFFをCIEDE2000で比較する。"""

from __future__ import annotations

import argparse
import hashlib
from io import BytesIO
import json
import math
import os
from pathlib import Path
import sys
import tempfile
from typing import Any

import cv2
import numpy as np
from PIL import Image, ImageCms, UnidentifiedImageError
from PIL.ImageCms import PyCMSError


DEFAULT_GATE_ROUTES = {
    "raw": ("xmp-basic", "xmp-full-current"),
    "lr_input": ("lr-input-xmp-basic", "lr-input-xmp-full-current"),
}
DEFAULT_GATE_THRESHOLDS = {
    "mean_delta_e_maximum_increase": 0.25,
    "mean_ev_absolute_error_maximum_increase": 0.05,
    "new_shared_plateau_maximum_area": 0.0005,
}
LEGACY_CANDIDATE_CONTRACT = {
    "exposure-only": ("xmp-exposure-only", "lr-input-xmp-exposure-only"),
    "tone-base": ("xmp-tone", "lr-input-xmp-tone"),
    "basic-legacy": ("xmp-basic", "lr-input-xmp-basic"),
    "full-current": ("xmp-full-current", "lr-input-xmp-full-current"),
}
STAGE_CANDIDATE_CONTRACT = {
    "tone-base": ("xmp-stage-tone-base", "lr-input-xmp-stage-tone-base"),
    "tone-plus-vibrance": (
        "xmp-stage-tone-plus-vibrance",
        "lr-input-xmp-stage-tone-plus-vibrance",
    ),
    "tone-plus-global-saturation": (
        "xmp-stage-tone-plus-global-saturation",
        "lr-input-xmp-stage-tone-plus-global-saturation",
    ),
    "tone-plus-global-curve": (
        "xmp-stage-tone-plus-global-curve",
        "lr-input-xmp-stage-tone-plus-global-curve",
    ),
    "tone-plus-rgb-curves": (
        "xmp-stage-tone-plus-rgb-curves",
        "lr-input-xmp-stage-tone-plus-rgb-curves",
    ),
    "tone-plus-all-curves": (
        "xmp-stage-tone-plus-all-curves",
        "lr-input-xmp-stage-tone-plus-all-curves",
    ),
    "tone-plus-mixer-hue": (
        "xmp-stage-tone-plus-mixer-hue",
        "lr-input-xmp-stage-tone-plus-mixer-hue",
    ),
    "tone-plus-mixer-saturation": (
        "xmp-stage-tone-plus-mixer-saturation",
        "lr-input-xmp-stage-tone-plus-mixer-saturation",
    ),
    "tone-plus-mixer-luminance": (
        "xmp-stage-tone-plus-mixer-luminance",
        "lr-input-xmp-stage-tone-plus-mixer-luminance",
    ),
    "tone-plus-all-mixer": (
        "xmp-stage-tone-plus-all-mixer",
        "lr-input-xmp-stage-tone-plus-all-mixer",
    ),
    "tone-plus-curves-mixer": (
        "xmp-stage-tone-plus-curves-mixer",
        "lr-input-xmp-stage-tone-plus-curves-mixer",
    ),
    "full-current": (
        "xmp-stage-full-current",
        "lr-input-xmp-stage-full-current",
    ),
}
COMPARISON_CONTRACT = {
    "maxDimension": 1500,
    "outputFormat": "RGBA16 sRGB TIFF",
    "outputColorSpace": "sRGB IEC61966-2.1",
    "bitsPerChannel": 16,
    "referenceSoftware": "Adobe Lightroom 9.3 (Macintosh)",
    "referenceWhiteBalance": "As Shot",
    "orientationPolicy": "Photo Bench normalizes source orientation before comparison",
    "cropPolicy": "full frame; no analyzer-side resize or registration",
}
RAW_PROFILE_CONTRACT = {
    "id": "panasonic-dc-s5-lightroom-9.3-edr1-v2",
    "boostAmount": 0.9,
    "extendedDynamicRangeAmount": 1.0,
}
PREVIEW_PARITY_STAGE_IDS = ("neutral", "basic-legacy", "full-current")
PREVIEW_PARITY_ROUTE_LABELS = {
    "full-resolution": "full-decode",
    "interactive-preview": "scaled-decode",
}
PREVIEW_PARITY_DECODE_ROUTES = {
    "full-resolution": "preview-parity-full-resolution",
    "interactive-preview": "preview-parity-interactive-preview",
}
PREVIEW_PARITY_V3_BASELINE_ROUTE = "preview-parity-full-resolution"


def preview_parity_v3_candidate_route(maximum_dimension: int) -> str:
    return f"preview-parity-interactive-preview-{maximum_dimension}"


DEFAULT_PREVIEW_PARITY_THRESHOLDS = {
    "mean_delta_e_maximum": 1.0,
    "mean_ev_absolute_drift_maximum": 0.02,
    "new_shared_plateau_maximum_area": 0.0001,
}
DEFAULT_PREVIEW_PARITY_V3_THRESHOLDS = {
    "mean_delta_e_maximum": 1.0,
    "delta_e_p95_maximum": 2.0,
    "mean_ev_absolute_drift_maximum": 0.02,
    "net_shared_plateau_area_increase_maximum": 0.0001,
    "spatially_distinct_new_shared_plateau_maximum_area": 0.0001,
}
CANONICAL_SETTLE_CONTRACT = {
    "outputMaxDimension": 2_560,
    "downsamplingFilter": "CILanczosScaleTransform",
    "inputAspectRatio": 1.0,
    "workingColorSpace": "extended-linear-sRGB",
    "outputTransformPlacement": "after-downsampling",
    "baselineStageID": "basic-legacy",
    "candidateStageID": "full-current",
}
CANONICAL_SETTLE_THRESHOLD_CONTRACT = {
    "completeClipNormalizedMinimum": 1 - 0.5 / 65_535,
    "nearClipNormalizedMinimum": 0.999,
    "completeClipMaximumPixelCountIncrease": 0,
    "nearClipMaximumPixelCountIncrease": 0,
    "newSharedPlateauMaximumArea": 0.0005,
}
LEGACY_RENDER_PIPELINE_IDENTIFIER = (
    "extended-linear-srgb-edits-final-srgb-then-resize-v1"
)
CURRENT_RENDER_PIPELINE_IDENTIFIER = (
    "extended-linear-srgb-edits-resize-before-final-srgb-v1"
)
SUPPORTED_MANIFEST_SCHEMA_VERSIONS = (2, 3, 4)
CURRENT_MANIFEST_SCHEMA_VERSION = 4
RUN_SCHEMA_VERSION = 2
REPORT_SCHEMA_VERSION = 5
DEFAULT_MANIFEST_PATH = "calibration/manifest-v4.json"
DEFAULT_RUN_MANIFEST_PATH = ".photobench/calibration/run-manifest.json"
PLATEAU_LUMINANCE_QUANTILE = 0.999
PLATEAU_CODE_VALUE_TOLERANCE = 2 / 65_535
MEAN_EV_BLACK_THRESHOLD = 0.01


def _require_srgb_icc_profile(path: Path) -> str:
    try:
        with Image.open(path) as image:
            icc_profile = image.info.get("icc_profile")
    except (OSError, UnidentifiedImageError) as error:
        raise RuntimeError(f"TIFF metadataを読み込めません: {path}: {error}") from error
    if not isinstance(icc_profile, bytes) or not icc_profile:
        raise RuntimeError(f"sRGB ICC profileがありません: {path}")
    try:
        profile = ImageCms.ImageCmsProfile(BytesIO(icc_profile))
        description = ImageCms.getProfileDescription(profile).strip()
        name = ImageCms.getProfileName(profile).strip()
        color_space = profile.profile.xcolor_space.strip()
    except (OSError, TypeError, ValueError, PyCMSError) as error:
        raise RuntimeError(f"ICC profileを検証できません: {path}: {error}") from error
    identity = f"{description} {name}".lower().replace(" ", "")
    if color_space != "RGB" or (
        "srgb" not in identity and "iec61966-2.1" not in identity
    ):
        raise RuntimeError(
            f"sRGB IEC61966-2.1 profileではありません: {path} "
            f"description={description!r} colorSpace={color_space!r}"
        )
    return description


def read_srgb(path: Path) -> np.ndarray:
    _require_srgb_icc_profile(path)
    image = cv2.imread(str(path), cv2.IMREAD_UNCHANGED | cv2.IMREAD_IGNORE_ORIENTATION)
    if image is None:
        raise RuntimeError(f"画像を読み込めません: {path}")
    if image.dtype != np.uint16:
        raise RuntimeError(
            f"16-bit TIFFではありません: {path} dtype={image.dtype}"
        )
    if image.ndim != 3 or image.shape[2] not in (3, 4):
        raise RuntimeError(
            f"3/4 channel TIFFではありません: {path} shape={image.shape}"
        )
    if image.shape[2] == 4:
        image = image[..., :3]
    image = image[..., ::-1]
    normalized = image.astype(np.float32) / 65_535.0
    if not np.all(np.isfinite(normalized)):
        raise RuntimeError(f"画像に非finite値があります: {path}")
    return normalized


def srgb_to_lab(srgb: np.ndarray) -> np.ndarray:
    linear = srgb_to_linear(srgb)
    matrix = np.array(
        [[0.4124564, 0.3575761, 0.1804375],
         [0.2126729, 0.7151522, 0.0721750],
         [0.0193339, 0.1191920, 0.9503041]],
        dtype=np.float32,
    )
    xyz = linear @ matrix.T
    xyz /= np.array([0.95047, 1.0, 1.08883], dtype=np.float32)
    delta = 6 / 29
    f = np.where(xyz > delta**3, np.cbrt(xyz), xyz / (3 * delta**2) + 4 / 29)
    return np.stack(
        [116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])],
        axis=-1,
    )


def srgb_to_linear(srgb: np.ndarray) -> np.ndarray:
    return np.where(
        srgb <= 0.04045,
        srgb / 12.92,
        ((srgb + 0.055) / 1.055) ** 2.4,
    )


def encoded_luminance(srgb: np.ndarray) -> np.ndarray:
    return (
        0.2126 * srgb[..., 0]
        + 0.7152 * srgb[..., 1]
        + 0.0722 * srgb[..., 2]
    )


def linear_luminance(srgb: np.ndarray) -> np.ndarray:
    linear = srgb_to_linear(srgb)
    return (
        0.2126 * linear[..., 0]
        + 0.7152 * linear[..., 1]
        + 0.0722 * linear[..., 2]
    )


def _highlight_plateau_mask(
    luminance: np.ndarray,
    highlight: np.ndarray,
) -> np.ndarray:
    if luminance.size < 2:
        return np.zeros_like(highlight, dtype=bool)
    plateau = np.zeros_like(highlight, dtype=bool)

    horizontal = (
        highlight[:, :-1]
        & highlight[:, 1:]
        & (
            np.abs(luminance[:, :-1] - luminance[:, 1:])
            <= PLATEAU_CODE_VALUE_TOLERANCE
        )
    )
    plateau[:, :-1] |= horizontal
    plateau[:, 1:] |= horizontal

    vertical = (
        highlight[:-1, :]
        & highlight[1:, :]
        & (
            np.abs(luminance[:-1, :] - luminance[1:, :])
            <= PLATEAU_CODE_VALUE_TOLERANCE
        )
    )
    plateau[:-1, :] |= vertical
    plateau[1:, :] |= vertical

    return plateau


def _highlight_plateau_fraction(
    luminance: np.ndarray,
    highlight: np.ndarray,
) -> float:
    plateau = _highlight_plateau_mask(luminance, highlight)
    return float(np.count_nonzero(plateau) / luminance.size)


def _dilate_binary_mask(mask: np.ndarray, radius_pixels: int) -> np.ndarray:
    """Dilate a 2-D mask with a deterministic square (8-neighbour) footprint."""
    if mask.ndim != 2:
        raise ValueError(f"dilation maskは2次元である必要があります: shape={mask.shape}")
    if isinstance(radius_pixels, bool) or not isinstance(radius_pixels, int):
        raise ValueError("dilation radiusは整数である必要があります")
    if radius_pixels < 0:
        raise ValueError("dilation radiusは0以上である必要があります")
    source = mask.astype(bool, copy=False)
    if radius_pixels == 0:
        return source.copy()
    padded = np.pad(source, radius_pixels, mode="constant", constant_values=False)
    height, width = source.shape
    dilated = np.zeros_like(source, dtype=bool)
    diameter = radius_pixels * 2 + 1
    for y_offset in range(diameter):
        for x_offset in range(diameter):
            dilated |= padded[
                y_offset : y_offset + height,
                x_offset : x_offset + width,
            ]
    return dilated


def _maximum_true_density_window(
    mask: np.ndarray,
    *,
    window_size_pixels: int,
) -> dict[str, Any]:
    """Locate the densest fixed-size diagnostic window without changing gates."""
    if mask.ndim != 2 or mask.size == 0:
        raise ValueError(f"density maskは空でない2次元が必要です: shape={mask.shape}")
    if (
        isinstance(window_size_pixels, bool)
        or not isinstance(window_size_pixels, int)
        or window_size_pixels <= 0
    ):
        raise ValueError("density window sizeは正の整数である必要があります")
    height, width = mask.shape
    window_height = min(window_size_pixels, height)
    window_width = min(window_size_pixels, width)
    integral = cv2.integral(mask.astype(np.uint8), sdepth=cv2.CV_64F)
    sums = (
        integral[window_height:, window_width:]
        - integral[:-window_height, window_width:]
        - integral[window_height:, :-window_width]
        + integral[:-window_height, :-window_width]
    )
    flat_index = int(np.argmax(sums))
    y, x = np.unravel_index(flat_index, sums.shape)
    maximum_count = int(sums[y, x])
    window_pixel_count = window_height * window_width
    return {
        "window_size_pixels": window_size_pixels,
        "actual_window_width": window_width,
        "actual_window_height": window_height,
        "maximum_pixel_count": maximum_count,
        "maximum_window_density": maximum_count / window_pixel_count,
        "bbox": {
            "x": int(x),
            "y": int(y),
            "width": window_width,
            "height": window_height,
        },
    }


def _outside_plateau_distance_histogram(
    reference_plateau: np.ndarray,
    outside_tolerance: np.ndarray,
) -> dict[str, int]:
    """Bin Chebyshev distance from each outside pixel to reference plateau."""
    outside_count = int(np.count_nonzero(outside_tolerance))
    empty = {"distance-2": 0, "distance-3-to-4": 0, "distance-5-to-8": 0,
             "distance-9-or-more": 0, "no-reference-plateau": 0}
    if outside_count == 0:
        return empty
    if not np.any(reference_plateau):
        empty["no-reference-plateau"] = outside_count
        return empty
    distances = cv2.distanceTransform(
        (~reference_plateau).astype(np.uint8),
        cv2.DIST_C,
        3,
    )[outside_tolerance]
    return {
        "distance-2": int(np.count_nonzero(distances == 2)),
        "distance-3-to-4": int(
            np.count_nonzero((distances >= 3) & (distances <= 4))
        ),
        "distance-5-to-8": int(
            np.count_nonzero((distances >= 5) & (distances <= 8))
        ),
        "distance-9-or-more": int(np.count_nonzero(distances >= 9)),
        "no-reference-plateau": 0,
    }


def highlight_plateau_fraction(srgb: np.ndarray) -> float:
    """Return the image-area fraction occupied by a bright, near-flat shelf."""
    luminance = encoded_luminance(srgb)
    if luminance.size < 2:
        return 0.0

    # Selecting all samples tied at the percentile is deliberate: a broad,
    # quantized highlight ceiling is the plateau this diagnostic must expose.
    threshold = float(np.quantile(luminance, PLATEAU_LUMINANCE_QUANTILE))
    return _highlight_plateau_fraction(luminance, luminance >= threshold)


def shared_highlight_plateau_fractions(
    basic: np.ndarray,
    full: np.ndarray,
) -> tuple[float, float, float]:
    """Measure basic/full shelves over one shared spatial highlight region.

    Independent percentile masks cannot be compared: an already-flat region
    may simply move into the brightest 0.1% after an intentional color edit.
    The union mask below asks the gate's real question instead: did the full
    stage collapse detail that was still distinct at the same pixel positions
    in the basic stage?
    """
    basic_plateau, full_plateau = shared_highlight_plateau_masks(basic, full)
    pixel_count = basic.shape[0] * basic.shape[1]
    return (
        float(np.count_nonzero(basic_plateau) / pixel_count),
        float(np.count_nonzero(full_plateau) / pixel_count),
        float(np.count_nonzero(full_plateau & ~basic_plateau) / pixel_count),
    )


def shared_highlight_plateau_masks(
    reference: np.ndarray,
    candidate: np.ndarray,
) -> tuple[np.ndarray, np.ndarray]:
    """Return reference/candidate luma-plateau masks over one shared highlight ROI."""
    if reference.shape != candidate.shape:
        raise ValueError(
            "reference/candidate画像のshapeが一致しません: "
            f"reference={reference.shape}, candidate={candidate.shape}"
        )
    reference_luminance = encoded_luminance(reference)
    candidate_luminance = encoded_luminance(candidate)
    reference_threshold = float(
        np.quantile(reference_luminance, PLATEAU_LUMINANCE_QUANTILE)
    )
    candidate_threshold = float(
        np.quantile(candidate_luminance, PLATEAU_LUMINANCE_QUANTILE)
    )
    shared_highlight = (reference_luminance >= reference_threshold) | (
        candidate_luminance >= candidate_threshold
    )
    return (
        _highlight_plateau_mask(reference_luminance, shared_highlight),
        _highlight_plateau_mask(candidate_luminance, shared_highlight),
    )


def shared_highlight_plateau_spatial_metrics(
    reference: np.ndarray,
    candidate: np.ndarray,
    *,
    tolerance_pixels: int,
) -> dict[str, Any]:
    """Measure plateau growth while tolerating bounded boundary relocation.

    The legacy set difference remains observable, but it is not a reliable gate
    when independently downsampled images relocate a plateau boundary by a
    pixel. v3 therefore gates both net area change and candidate plateau pixels
    outside a dilated reference mask.
    """
    reference_plateau, candidate_plateau = shared_highlight_plateau_masks(
        reference, candidate
    )
    pixel_count = reference.shape[0] * reference.shape[1]
    reference_count = int(np.count_nonzero(reference_plateau))
    candidate_count = int(np.count_nonzero(candidate_plateau))
    legacy_new_count = int(np.count_nonzero(candidate_plateau & ~reference_plateau))
    tolerated_reference = _dilate_binary_mask(reference_plateau, tolerance_pixels)
    outside_tolerance = candidate_plateau & ~tolerated_reference
    outside_tolerance_count = int(np.count_nonzero(outside_tolerance))
    density_window = _maximum_true_density_window(
        outside_tolerance,
        window_size_pixels=128,
    )
    distance_histogram = _outside_plateau_distance_histogram(
        reference_plateau,
        outside_tolerance,
    )
    component_count, _, component_stats, _ = cv2.connectedComponentsWithStats(
        outside_tolerance.astype(np.uint8),
        connectivity=8,
    )
    if component_count > 1:
        component_areas = component_stats[1:, cv2.CC_STAT_AREA]
        largest_label = 1 + int(np.argmax(component_areas))
        largest_component_count = int(component_stats[largest_label, cv2.CC_STAT_AREA])
        largest_component_bbox: dict[str, int] | None = {
            "x": int(component_stats[largest_label, cv2.CC_STAT_LEFT]),
            "y": int(component_stats[largest_label, cv2.CC_STAT_TOP]),
            "width": int(component_stats[largest_label, cv2.CC_STAT_WIDTH]),
            "height": int(component_stats[largest_label, cv2.CC_STAT_HEIGHT]),
        }
    else:
        largest_component_count = 0
        largest_component_bbox = None
    return {
        "reference_shared_highlight_plateau_fraction": reference_count / pixel_count,
        "candidate_shared_highlight_plateau_fraction": candidate_count / pixel_count,
        "legacy_new_shared_highlight_plateau_fraction": legacy_new_count / pixel_count,
        "shared_highlight_plateau_area_fraction_change": (
            candidate_count - reference_count
        ) / pixel_count,
        "candidate_plateau_outside_reference_dilation_fraction": (
            outside_tolerance_count / pixel_count
        ),
        "candidate_plateau_outside_reference_dilation_component_count": max(
            component_count - 1, 0
        ),
        "candidate_plateau_outside_reference_dilation_largest_component_fraction": (
            largest_component_count / pixel_count
        ),
        "candidate_plateau_outside_reference_dilation_largest_component_bbox": (
            largest_component_bbox
        ),
        "candidate_plateau_outside_reference_dilation_worst_window": density_window,
        "candidate_plateau_outside_reference_dilation_distance_histogram_pixels": (
            distance_histogram
        ),
        "reference_dilation_radius_pixels": tolerance_pixels,
    }


def mean_ev_drift(reference: np.ndarray, candidate: np.ndarray) -> float:
    reference_luminance = linear_luminance(reference)
    candidate_luminance = linear_luminance(candidate)
    valid = reference_luminance > MEAN_EV_BLACK_THRESHOLD
    if not np.any(valid):
        return 0.0
    epsilon = np.finfo(np.float32).tiny
    ratio = np.maximum(candidate_luminance[valid], epsilon) / reference_luminance[valid]
    return float(np.mean(np.log2(ratio)))


def delta_e_2000(lab1: np.ndarray, lab2: np.ndarray) -> np.ndarray:
    # Sharma et al. (2005), kL=kC=kH=1.
    l1, a1, b1 = np.moveaxis(lab1, -1, 0)
    l2, a2, b2 = np.moveaxis(lab2, -1, 0)
    c1 = np.hypot(a1, b1)
    c2 = np.hypot(a2, b2)
    c_bar = (c1 + c2) / 2
    g = 0.5 * (1 - np.sqrt(c_bar**7 / (c_bar**7 + 25**7)))
    ap1, ap2 = (1 + g) * a1, (1 + g) * a2
    cp1, cp2 = np.hypot(ap1, b1), np.hypot(ap2, b2)
    hp1 = np.mod(np.degrees(np.arctan2(b1, ap1)), 360)
    hp2 = np.mod(np.degrees(np.arctan2(b2, ap2)), 360)
    hp1 = np.where((ap1 == 0) & (b1 == 0), 0, hp1)
    hp2 = np.where((ap2 == 0) & (b2 == 0), 0, hp2)

    dl = l2 - l1
    dc = cp2 - cp1
    dh_angle = hp2 - hp1
    dh_angle = np.where(np.abs(dh_angle) <= 180, dh_angle, dh_angle - np.sign(dh_angle) * 360)
    dh_angle = np.where((cp1 * cp2) == 0, 0, dh_angle)
    dh = 2 * np.sqrt(cp1 * cp2) * np.sin(np.radians(dh_angle / 2))

    l_bar = (l1 + l2) / 2
    cp_bar = (cp1 + cp2) / 2
    hp_sum = hp1 + hp2
    hp_bar = np.where(
        (cp1 * cp2) == 0,
        hp_sum,
        np.where(
            np.abs(hp1 - hp2) <= 180,
            hp_sum / 2,
            np.where(hp_sum < 360, (hp_sum + 360) / 2, (hp_sum - 360) / 2),
        ),
    )
    t = (
        1
        - 0.17 * np.cos(np.radians(hp_bar - 30))
        + 0.24 * np.cos(np.radians(2 * hp_bar))
        + 0.32 * np.cos(np.radians(3 * hp_bar + 6))
        - 0.20 * np.cos(np.radians(4 * hp_bar - 63))
    )
    sl = 1 + 0.015 * (l_bar - 50) ** 2 / np.sqrt(20 + (l_bar - 50) ** 2)
    sc = 1 + 0.045 * cp_bar
    sh = 1 + 0.015 * cp_bar * t
    delta_theta = 30 * np.exp(-((hp_bar - 275) / 25) ** 2)
    rc = 2 * np.sqrt(cp_bar**7 / (cp_bar**7 + 25**7))
    rt = -rc * np.sin(np.radians(2 * delta_theta))
    return np.sqrt((dl / sl) ** 2 + (dc / sc) ** 2 + (dh / sh) ** 2 + rt * (dc / sc) * (dh / sh))


def summarize(reference: np.ndarray, candidate: np.ndarray) -> dict[str, float]:
    if reference.shape != candidate.shape:
        raise ValueError(
            "比較画像のshapeが一致しません。Python側では補正リサイズしません: "
            f"reference={reference.shape}, candidate={candidate.shape}. "
            "PhotoBenchCalibrationで両方を同じmaxDimensionに正規化してください。"
        )
    # Registration/demosaic noise is suppressed only for perceptual color
    # metrics. Clipping must be measured from the untouched normalized TIFF;
    # blurring a saturated pixel would hide the very plateau we need to count.
    reference_blurred = cv2.GaussianBlur(reference, (0, 0), sigmaX=1.2, sigmaY=1.2)
    candidate_blurred = cv2.GaussianBlur(candidate, (0, 0), sigmaX=1.2, sigmaY=1.2)
    delta = delta_e_2000(srgb_to_lab(reference_blurred), srgb_to_lab(candidate_blurred))
    luminance = (
        0.2126 * reference_blurred[..., 0]
        + 0.7152 * reference_blurred[..., 1]
        + 0.0722 * reference_blurred[..., 2]
    )
    grad_x = cv2.Sobel(luminance, cv2.CV_32F, 1, 0, ksize=3)
    grad_y = cv2.Sobel(luminance, cv2.CV_32F, 0, 1, ksize=3)
    midtone = (reference_blurred.min(axis=2) > 0.02) & (
        reference_blurred.max(axis=2) < 0.98
    )
    low_detail = midtone & (np.hypot(grad_x, grad_y) < 0.08)

    def stats(values: np.ndarray, prefix: str) -> dict[str, float]:
        return {
            f"{prefix}_mean": float(np.mean(values)),
            f"{prefix}_median": float(np.median(values)),
            f"{prefix}_p95": float(np.percentile(values, 95)),
        }

    result = stats(delta, "all")
    result.update(stats(delta[midtone], "midtone"))
    result.update(stats(delta[low_detail], "low_detail"))
    result["rgb_mae"] = float(
        np.mean(np.abs(reference_blurred - candidate_blurred))
    )
    result["low_detail_fraction"] = float(np.mean(low_detail))
    exact_threshold = 1 - 0.5 / 65_535
    result["reference_complete_clip_fraction"] = float(
        np.mean(np.any(reference >= exact_threshold, axis=2))
    )
    result["candidate_complete_clip_fraction"] = float(
        np.mean(np.any(candidate >= exact_threshold, axis=2))
    )
    result["reference_near_clip_fraction"] = float(
        np.mean(np.any(reference >= 0.999, axis=2))
    )
    result["candidate_near_clip_fraction"] = float(
        np.mean(np.any(candidate >= 0.999, axis=2))
    )
    result["reference_highlight_plateau_fraction"] = highlight_plateau_fraction(
        reference
    )
    result["candidate_highlight_plateau_fraction"] = highlight_plateau_fraction(
        candidate
    )
    result["mean_ev_drift"] = mean_ev_drift(reference_blurred, candidate_blurred)
    return result


def _non_regression_check(
    basic: dict[str, float],
    full: dict[str, float],
    metric: str,
) -> dict[str, Any]:
    basic_value = basic[metric]
    full_value = full[metric]
    return {
        "basic": basic_value,
        "full": full_value,
        "passed": full_value <= basic_value,
    }


def evaluate_quality_gates(
    preset_report: dict[str, dict[str, dict[str, float]]],
    stems: tuple[str, ...] | None = None,
    missing_candidates: list[str] | None = None,
    routes: dict[str, tuple[str, str]] | None = None,
    thresholds: dict[str, float] | None = None,
) -> dict[str, Any]:
    """Evaluate fail-closed HDR/HSL quality gates for every scene and route."""
    if stems is None:
        stems = tuple(preset_report)
    routes = routes or DEFAULT_GATE_ROUTES
    thresholds = thresholds or DEFAULT_GATE_THRESHOLDS
    delta_e_increase = thresholds["mean_delta_e_maximum_increase"]
    ev_increase = thresholds["mean_ev_absolute_error_maximum_increase"]
    plateau_maximum = thresholds["new_shared_plateau_maximum_area"]
    missing = list(missing_candidates or [])
    scenes: dict[str, Any] = {}
    route_results: list[bool] = []

    for stem in stems:
        candidates = preset_report.get(stem, {})
        scene_routes: dict[str, Any] = {}
        for route, (basic_label, full_label) in routes.items():
            route_missing = [
                label for label in (basic_label, full_label) if label not in candidates
            ]
            if route_missing:
                missing.extend(f"{stem}-{label}.tif" for label in route_missing)
                scene_routes[route] = {
                    "passed": False,
                    "missing_candidates": route_missing,
                    "checks": {},
                }
                route_results.append(False)
                continue

            basic = candidates[basic_label]
            full = candidates[full_label]
            checks: dict[str, Any] = {
                "complete_clip_non_regression": _non_regression_check(
                    basic, full, "candidate_complete_clip_fraction"
                ),
                "near_clip_non_regression": _non_regression_check(
                    basic, full, "candidate_near_clip_fraction"
                ),
            }

            basic_plateau = basic["shared_highlight_plateau_fraction"]
            full_plateau = full["shared_highlight_plateau_fraction"]
            new_plateau = full["new_shared_highlight_plateau_fraction"]
            checks["new_shared_highlight_plateau_area"] = {
                "basic": basic_plateau,
                "full": full_plateau,
                "new": new_plateau,
                "maximum_new": plateau_maximum,
                "passed": new_plateau <= plateau_maximum,
            }

            delta_e_limit = basic["all_mean"] + delta_e_increase
            checks["mean_delta_e_regression"] = {
                "basic": basic["all_mean"],
                "full": full["all_mean"],
                "maximum": round(delta_e_limit, 5),
                "passed": full["all_mean"] <= delta_e_limit,
            }
            basic_ev_error = abs(basic["mean_ev_drift"])
            full_ev_error = abs(full["mean_ev_drift"])
            ev_error_limit = basic_ev_error + ev_increase
            checks["mean_ev_drift_non_regression"] = {
                "basic": basic["mean_ev_drift"],
                "full": full["mean_ev_drift"],
                "basic_absolute_error": round(basic_ev_error, 5),
                "full_absolute_error": round(full_ev_error, 5),
                "maximum_full_absolute_error": round(ev_error_limit, 5),
                "allowed_absolute_error_increase": ev_increase,
                "passed": full_ev_error <= ev_error_limit,
            }
            route_passed = all(check["passed"] for check in checks.values())
            scene_routes[route] = {
                "basic_candidate": basic_label,
                "full_candidate": full_label,
                "passed": route_passed,
                "checks": checks,
            }
            route_results.append(route_passed)
        scenes[stem] = scene_routes

    unique_missing = sorted(set(missing))
    all_present = not unique_missing
    return {
        "thresholds": {
            "full_mean_delta_e_maximum_increase": delta_e_increase,
            "full_mean_ev_absolute_error_maximum_increase": ev_increase,
            "full_shared_highlight_plateau_maximum_area_increase": plateau_maximum,
        },
        "all_expected_candidates_present": all_present,
        "missing_candidates": unique_missing,
        "scenes": scenes,
        "passed": all_present and bool(route_results) and all(route_results),
    }


def preview_parity_metrics(
    reference: np.ndarray,
    candidate: np.ndarray,
) -> dict[str, Any]:
    """Compare a scaled full decode with the same-stage interactive decode."""
    summary = summarize(reference, candidate)
    reference_plateau, candidate_plateau, new_plateau = (
        shared_highlight_plateau_fractions(reference, candidate)
    )
    return {
        "mean_delta_e_2000": summary["all_mean"],
        "mean_ev_drift": summary["mean_ev_drift"],
        "reference_shared_highlight_plateau_fraction": reference_plateau,
        "candidate_shared_highlight_plateau_fraction": candidate_plateau,
        "new_shared_highlight_plateau_fraction": new_plateau,
        "full_metrics": summary,
    }


def preview_parity_v3_metrics(
    reference: np.ndarray,
    candidate: np.ndarray,
    *,
    tolerance_pixels: int,
) -> dict[str, Any]:
    """Compare one v3 oversampled RAW route with the common full-decode output.

    Color metrics use the preregistered Gaussian-blurred comparison implemented
    by ``summarize``. Plateau metrics intentionally use the unblurred encoded
    luma raster and preserve the legacy exact-coordinate set difference only as
    a diagnostic; v3 gates signed area growth and pixels outside a bounded
    dilation instead.
    """
    summary = summarize(reference, candidate)
    plateau = shared_highlight_plateau_spatial_metrics(
        reference,
        candidate,
        tolerance_pixels=tolerance_pixels,
    )
    return {
        "mean_delta_e_2000": summary["all_mean"],
        "blurred_delta_e_2000_p95": summary["all_p95"],
        "mean_ev_drift": summary["mean_ev_drift"],
        **plateau,
        "full_metrics": summary,
    }


def evaluate_preview_parity_gates(
    measurements: dict[str, dict[str, dict[str, Any]]],
    *,
    scene_ids: tuple[str, ...],
    stage_ids: tuple[str, ...] = PREVIEW_PARITY_STAGE_IDS,
    thresholds: dict[str, float] | None = None,
) -> dict[str, Any]:
    """Evaluate preview parity independently from Lightroom quality gates.

    Missing scenes, stages, or metrics are evidence-structure failures rather
    than numeric gate failures. A complete formal run may fail only because one
    or more measured values exceed the frozen threshold.
    """
    thresholds = thresholds or DEFAULT_PREVIEW_PARITY_THRESHOLDS
    required_thresholds = set(DEFAULT_PREVIEW_PARITY_THRESHOLDS)
    if set(thresholds) != required_thresholds:
        raise StructuralValidationError(
            "preview parity threshold keyが固定契約と一致しません"
        )
    normalized_thresholds = {
        key: _require_number(value, f"previewParity.thresholds.{key}", minimum=0)
        for key, value in thresholds.items()
    }
    expected_scenes = set(scene_ids)
    if set(measurements) != expected_scenes:
        raise StructuralValidationError(
            "preview parity測定sceneがmanifestと一致しません"
        )

    scenes: dict[str, Any] = {}
    stage_results: list[bool] = []
    required_metric_keys = (
        "mean_delta_e_2000",
        "mean_ev_drift",
        "reference_shared_highlight_plateau_fraction",
        "candidate_shared_highlight_plateau_fraction",
        "new_shared_highlight_plateau_fraction",
    )
    for scene_id in scene_ids:
        scene_measurements = measurements[scene_id]
        if set(scene_measurements) != set(stage_ids):
            raise StructuralValidationError(
                f"preview parity stageが固定契約と一致しません: {scene_id}"
            )
        scene_stages: dict[str, Any] = {}
        for stage_id in stage_ids:
            entry = _require_dict(
                scene_measurements[stage_id],
                f"previewParity.{scene_id}.{stage_id}",
            )
            metrics = _require_dict(
                entry.get("metrics"),
                f"previewParity.{scene_id}.{stage_id}.metrics",
            )
            numeric = {
                key: _require_number(
                    metrics.get(key),
                    f"previewParity.{scene_id}.{stage_id}.{key}",
                    minimum=(None if key == "mean_ev_drift" else 0),
                )
                for key in required_metric_keys
            }
            checks = {
                "mean_delta_e_2000": {
                    "observed": numeric["mean_delta_e_2000"],
                    "maximum": normalized_thresholds["mean_delta_e_maximum"],
                    "passed": numeric["mean_delta_e_2000"]
                    <= normalized_thresholds["mean_delta_e_maximum"],
                },
                "mean_ev_absolute_drift": {
                    "observed": numeric["mean_ev_drift"],
                    "observed_absolute": abs(numeric["mean_ev_drift"]),
                    "maximum": normalized_thresholds[
                        "mean_ev_absolute_drift_maximum"
                    ],
                    "passed": abs(numeric["mean_ev_drift"])
                    <= normalized_thresholds[
                        "mean_ev_absolute_drift_maximum"
                    ],
                },
                "new_shared_highlight_plateau_area": {
                    "reference": numeric[
                        "reference_shared_highlight_plateau_fraction"
                    ],
                    "candidate": numeric[
                        "candidate_shared_highlight_plateau_fraction"
                    ],
                    "new": numeric["new_shared_highlight_plateau_fraction"],
                    "maximum_new": normalized_thresholds[
                        "new_shared_plateau_maximum_area"
                    ],
                    "passed": numeric["new_shared_highlight_plateau_fraction"]
                    <= normalized_thresholds[
                        "new_shared_plateau_maximum_area"
                    ],
                },
            }
            passed = all(check["passed"] for check in checks.values())
            scene_stages[stage_id] = {"passed": passed, "checks": checks}
            stage_results.append(passed)
        scenes[scene_id] = scene_stages
    return {
        "thresholds": normalized_thresholds,
        "expected_scene_count": len(scene_ids),
        "expected_stage_count_per_scene": len(stage_ids),
        "evaluated_pair_count": len(stage_results),
        "scenes": scenes,
        "passed": bool(stage_results) and all(stage_results),
    }


def evaluate_preview_parity_v3_gates(
    measurements: dict[str, dict[str, dict[str, dict[str, Any]]]],
    *,
    scene_ids: tuple[str, ...],
    candidate_dimensions: tuple[int, ...],
    stage_ids: tuple[str, ...] = PREVIEW_PARITY_STAGE_IDS,
    thresholds: dict[str, float] | None = None,
    tolerance_pixels: int = 1,
) -> dict[str, Any]:
    """Evaluate each oversampled preview route independently and fail closed.

    A candidate is eligible only when every scene/stage pair passes all five
    preregistered gates. Product selection prefers the smallest eligible decode
    ceiling; an empty eligible set means the full-resolution decode remains the
    product route.
    """
    thresholds = thresholds or DEFAULT_PREVIEW_PARITY_V3_THRESHOLDS
    if set(thresholds) != set(DEFAULT_PREVIEW_PARITY_V3_THRESHOLDS):
        raise StructuralValidationError(
            "preview parity v3 threshold keyが固定契約と一致しません"
        )
    normalized_thresholds = {
        key: _require_number(value, f"previewParity.thresholds.{key}", minimum=0)
        for key, value in thresholds.items()
    }
    if (
        not candidate_dimensions
        or len(set(candidate_dimensions)) != len(candidate_dimensions)
        or any(
            isinstance(value, bool) or not isinstance(value, int) or value <= 0
            for value in candidate_dimensions
        )
    ):
        raise StructuralValidationError(
            "preview parity v3 candidate dimensionが空、重複、または不正です"
        )
    if isinstance(tolerance_pixels, bool) or not isinstance(tolerance_pixels, int):
        raise StructuralValidationError(
            "preview parity v3 tolerance pixelは整数である必要があります"
        )
    if tolerance_pixels != 1:
        raise StructuralValidationError(
            "preview parity v3 tolerance pixelは固定値1である必要があります"
        )
    if set(measurements) != set(scene_ids):
        raise StructuralValidationError(
            "preview parity v3測定sceneがmanifestと一致しません"
        )

    required_metric_keys = (
        "mean_delta_e_2000",
        "blurred_delta_e_2000_p95",
        "mean_ev_drift",
        "reference_shared_highlight_plateau_fraction",
        "candidate_shared_highlight_plateau_fraction",
        "shared_highlight_plateau_area_fraction_change",
        "candidate_plateau_outside_reference_dilation_fraction",
        "legacy_new_shared_highlight_plateau_fraction",
        "candidate_plateau_outside_reference_dilation_largest_component_fraction",
    )
    expected_candidate_keys = {str(value) for value in candidate_dimensions}
    candidates: dict[str, Any] = {}
    eligible_dimensions: list[int] = []
    total_pairs = 0

    for dimension in candidate_dimensions:
        dimension_key = str(dimension)
        candidate_scenes: dict[str, Any] = {}
        candidate_stage_results: list[bool] = []
        for scene_id in scene_ids:
            scene_measurements = _require_dict(
                measurements[scene_id], f"previewParity.{scene_id}"
            )
            if set(scene_measurements) != expected_candidate_keys:
                raise StructuralValidationError(
                    f"preview parity v3 candidate routeがmanifestと一致しません: "
                    f"{scene_id}"
                )
            candidate_measurements = _require_dict(
                scene_measurements[dimension_key],
                f"previewParity.{scene_id}.{dimension_key}",
            )
            if set(candidate_measurements) != set(stage_ids):
                raise StructuralValidationError(
                    f"preview parity v3 stageが固定契約と一致しません: "
                    f"{scene_id}/{dimension_key}"
                )
            scene_stages: dict[str, Any] = {}
            for stage_id in stage_ids:
                field = f"previewParity.{scene_id}.{dimension_key}.{stage_id}"
                entry = _require_dict(candidate_measurements[stage_id], field)
                metrics = _require_dict(entry.get("metrics"), f"{field}.metrics")
                numeric = {
                    key: _require_number(
                        metrics.get(key),
                        f"{field}.metrics.{key}",
                        minimum=(
                            None
                            if key
                            in (
                                "mean_ev_drift",
                                "shared_highlight_plateau_area_fraction_change",
                            )
                            else 0
                        ),
                    )
                    for key in required_metric_keys
                }
                net_increase = max(
                    0.0,
                    numeric["shared_highlight_plateau_area_fraction_change"],
                )
                checks = {
                    "mean_delta_e_2000": {
                        "observed": numeric["mean_delta_e_2000"],
                        "maximum": normalized_thresholds["mean_delta_e_maximum"],
                        "passed": numeric["mean_delta_e_2000"]
                        <= normalized_thresholds["mean_delta_e_maximum"],
                    },
                    "blurred_delta_e_2000_p95": {
                        "observed": numeric["blurred_delta_e_2000_p95"],
                        "maximum": normalized_thresholds["delta_e_p95_maximum"],
                        "passed": numeric["blurred_delta_e_2000_p95"]
                        <= normalized_thresholds["delta_e_p95_maximum"],
                    },
                    "mean_ev_absolute_drift": {
                        "observed": numeric["mean_ev_drift"],
                        "observed_absolute": abs(numeric["mean_ev_drift"]),
                        "maximum": normalized_thresholds[
                            "mean_ev_absolute_drift_maximum"
                        ],
                        "passed": abs(numeric["mean_ev_drift"])
                        <= normalized_thresholds[
                            "mean_ev_absolute_drift_maximum"
                        ],
                    },
                    "net_shared_highlight_plateau_area_increase": {
                        "reference": numeric[
                            "reference_shared_highlight_plateau_fraction"
                        ],
                        "candidate": numeric[
                            "candidate_shared_highlight_plateau_fraction"
                        ],
                        "observed_signed_change": numeric[
                            "shared_highlight_plateau_area_fraction_change"
                        ],
                        "observed_positive_increase": net_increase,
                        "maximum_increase": normalized_thresholds[
                            "net_shared_plateau_area_increase_maximum"
                        ],
                        "passed": net_increase
                        <= normalized_thresholds[
                            "net_shared_plateau_area_increase_maximum"
                        ],
                    },
                    "spatially_distinct_new_shared_highlight_plateau_area": {
                        "observed": numeric[
                            "candidate_plateau_outside_reference_dilation_fraction"
                        ],
                        "maximum": normalized_thresholds[
                            "spatially_distinct_new_shared_plateau_maximum_area"
                        ],
                        "reference_dilation_radius_pixels": tolerance_pixels,
                        "passed": numeric[
                            "candidate_plateau_outside_reference_dilation_fraction"
                        ]
                        <= normalized_thresholds[
                            "spatially_distinct_new_shared_plateau_maximum_area"
                        ],
                    },
                }
                passed = all(check["passed"] for check in checks.values())
                scene_stages[stage_id] = {
                    "passed": passed,
                    "checks": checks,
                    "diagnostics": {
                        "legacy_exact_coordinate_new_plateau_fraction": numeric[
                            "legacy_new_shared_highlight_plateau_fraction"
                        ],
                        "outside_dilation_largest_component_fraction": numeric[
                            "candidate_plateau_outside_reference_dilation_largest_component_fraction"
                        ],
                        "outside_dilation_largest_component_bbox": metrics.get(
                            "candidate_plateau_outside_reference_dilation_largest_component_bbox"
                        ),
                        "outside_dilation_worst_window": metrics.get(
                            "candidate_plateau_outside_reference_dilation_worst_window"
                        ),
                        "outside_dilation_distance_histogram_pixels": metrics.get(
                            "candidate_plateau_outside_reference_dilation_distance_histogram_pixels"
                        ),
                    },
                }
                candidate_stage_results.append(passed)
                total_pairs += 1
            candidate_scenes[scene_id] = scene_stages
        candidate_passed = bool(candidate_stage_results) and all(
            candidate_stage_results
        )
        if candidate_passed:
            eligible_dimensions.append(dimension)
        candidates[dimension_key] = {
            "passed": candidate_passed,
            "evaluated_pair_count": len(candidate_stage_results),
            "scenes": candidate_scenes,
        }

    selected = min(eligible_dimensions) if eligible_dimensions else None
    return {
        "thresholds": normalized_thresholds,
        "plateau_spatial_tolerance": {
            "radius_pixels": tolerance_pixels,
            "structuring_element": "square-3x3",
        },
        "expected_scene_count": len(scene_ids),
        "expected_candidate_count": len(candidate_dimensions),
        "expected_stage_count_per_candidate_per_scene": len(stage_ids),
        "evaluated_pair_count": total_pairs,
        "candidates": candidates,
        "eligible_candidate_decode_maximum_dimensions": sorted(
            eligible_dimensions
        ),
        "selected_candidate_decode_maximum_dimension": selected,
        "fallback_when_none_pass": "full-resolution RAW decode",
        "passed": selected is not None,
    }


class StructuralValidationError(RuntimeError):
    """The calibration evidence is incomplete, stale, or malformed."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1_048_576):
            digest.update(chunk)
    return digest.hexdigest()


def _reject_json_constant(value: str) -> None:
    raise StructuralValidationError(f"JSONに非finite値があります: {value}")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise StructuralValidationError(f"JSON keyが重複しています: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_json_constant,
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise StructuralValidationError(f"JSONを読み込めません: {path}: {error}") from error
    if not isinstance(value, dict):
        raise StructuralValidationError(f"JSON rootがobjectではありません: {path}")
    return value


def _require_dict(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise StructuralValidationError(f"{field}はobjectである必要があります")
    return value


def _require_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise StructuralValidationError(f"{field}はarrayである必要があります")
    return value


def _require_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise StructuralValidationError(f"{field}は空でない文字列である必要があります")
    return value


def _require_number(value: Any, field: str, *, minimum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise StructuralValidationError(f"{field}は数値である必要があります")
    converted = float(value)
    if not math.isfinite(converted) or (minimum is not None and converted < minimum):
        raise StructuralValidationError(f"{field}が範囲外または非finiteです")
    return converted


def _require_integer(value: Any, field: str, *, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise StructuralValidationError(f"{field}は{minimum}以上の整数である必要があります")
    return value


def _require_sha256(value: Any, field: str) -> str:
    text = _require_text(value, field)
    if len(text) != 64 or text != text.lower() or any(c not in "0123456789abcdef" for c in text):
        raise StructuralValidationError(f"{field}はlowercase SHA-256ではありません")
    return text


def resolve_inside(root: Path, relative: Any, *, must_exist: bool = True) -> Path:
    text = _require_text(relative, "path")
    relative_path = Path(text)
    if relative_path.is_absolute() or ".." in relative_path.parts or "\\" in text or "\0" in text:
        raise StructuralValidationError(f"pathがproject root外を指す可能性があります: {text}")
    candidate = (root / relative_path).resolve(strict=False)
    try:
        candidate.relative_to(root)
    except ValueError as error:
        raise StructuralValidationError(f"pathがproject root外を指しています: {text}") from error
    if must_exist and (not candidate.exists() or not candidate.is_file()):
        raise StructuralValidationError(f"fileが見つかりません: {text}")
    return candidate


def _safe_identifier(value: Any, field: str) -> str:
    text = _require_text(value, field)
    if any(not (character.isascii() and (character.isalnum() or character == "-")) for character in text):
        raise StructuralValidationError(f"{field}に未対応文字があります: {text}")
    return text


def _validate_canonical_settle_contract(
    manifest: dict[str, Any],
    *,
    schema_version: int,
) -> None:
    field_name = "canonicalSettleGate"
    if schema_version in (2, 3):
        if field_name in manifest:
            raise StructuralValidationError(
                f"manifest schema v{schema_version}に{field_name}を指定できません"
            )
        return

    gate = _require_dict(manifest.get(field_name), f"manifest.{field_name}")
    expected_keys = {*CANONICAL_SETTLE_CONTRACT, "thresholds"}
    if set(gate) != expected_keys:
        raise StructuralValidationError(
            f"{field_name}のkeyがschema v4固定契約と一致しません"
        )
    for field, expected in CANONICAL_SETTLE_CONTRACT.items():
        actual = gate.get(field)
        if field == "inputAspectRatio":
            actual = _require_number(actual, f"{field_name}.{field}", minimum=0)
        if actual != expected:
            raise StructuralValidationError(
                f"{field_name}.{field}がschema v4固定契約と一致しません: "
                f"expected={expected!r} actual={actual!r}"
            )

    thresholds = _require_dict(
        gate.get("thresholds"), f"{field_name}.thresholds"
    )
    if set(thresholds) != set(CANONICAL_SETTLE_THRESHOLD_CONTRACT):
        raise StructuralValidationError(
            f"{field_name}.thresholdsのkeyがschema v4固定契約と一致しません"
        )
    for field, expected in CANONICAL_SETTLE_THRESHOLD_CONTRACT.items():
        value_field = f"{field_name}.thresholds.{field}"
        if field.endswith("PixelCountIncrease"):
            actual = _require_integer(thresholds.get(field), value_field)
        else:
            actual = _require_number(thresholds.get(field), value_field, minimum=0)
        if actual != expected:
            raise StructuralValidationError(
                f"{value_field}がschema v4固定契約と一致しません: "
                f"expected={expected!r} actual={actual!r}"
            )


def _normalized_processing_fingerprint(
    value: Any,
    *,
    schema_version: int,
    field: str,
) -> dict[str, Any]:
    """Mirror Swift's legacy decode default before comparing run provenance."""
    fingerprint = dict(_require_dict(value, field))
    if schema_version <= 3:
        fingerprint.setdefault(
            "renderPipeline",
            LEGACY_RENDER_PIPELINE_IDENTIFIER,
        )
    return fingerprint


def canonical_settle_metrics(
    baseline: np.ndarray,
    candidate: np.ndarray,
    *,
    thresholds: dict[str, Any],
) -> dict[str, Any]:
    """Measure clipping and plateau growth on the canonical final raster."""
    if baseline.shape != candidate.shape:
        raise StructuralValidationError(
            "canonical settle画像のshapeが一致しません: "
            f"baseline={baseline.shape} candidate={candidate.shape}"
        )
    if baseline.ndim != 3 or baseline.shape[2] != 3 or baseline.size == 0:
        raise StructuralValidationError(
            f"canonical settle画像shapeが不正です: {baseline.shape}"
        )
    if not np.all(np.isfinite(baseline)) or not np.all(np.isfinite(candidate)):
        raise StructuralValidationError("canonical settle画像に非finite値があります")
    if set(thresholds) != set(CANONICAL_SETTLE_THRESHOLD_CONTRACT):
        raise StructuralValidationError(
            "canonical settle threshold keyが固定契約と一致しません"
        )
    complete_threshold = _require_number(
        thresholds.get("completeClipNormalizedMinimum"),
        "canonicalSettleGate.thresholds.completeClipNormalizedMinimum",
        minimum=0,
    )
    near_threshold = _require_number(
        thresholds.get("nearClipNormalizedMinimum"),
        "canonicalSettleGate.thresholds.nearClipNormalizedMinimum",
        minimum=0,
    )
    if complete_threshold > 1 or near_threshold > 1:
        raise StructuralValidationError(
            "canonical settle clip thresholdは1以下である必要があります"
        )

    pixel_count = baseline.shape[0] * baseline.shape[1]

    def clipped_pixel_count(image: np.ndarray, threshold: float) -> int:
        return int(np.count_nonzero(np.any(image >= threshold, axis=2)))

    baseline_complete = clipped_pixel_count(baseline, complete_threshold)
    candidate_complete = clipped_pixel_count(candidate, complete_threshold)
    baseline_near = clipped_pixel_count(baseline, near_threshold)
    candidate_near = clipped_pixel_count(candidate, near_threshold)
    baseline_plateau, candidate_plateau, new_plateau = (
        shared_highlight_plateau_fractions(baseline, candidate)
    )
    return {
        "pixel_count": pixel_count,
        "complete_clip_normalized_minimum": complete_threshold,
        "near_clip_normalized_minimum": near_threshold,
        "baseline_complete_clip_pixel_count": baseline_complete,
        "candidate_complete_clip_pixel_count": candidate_complete,
        "complete_clip_pixel_count_increase": (
            candidate_complete - baseline_complete
        ),
        "baseline_complete_clip_fraction": baseline_complete / pixel_count,
        "candidate_complete_clip_fraction": candidate_complete / pixel_count,
        "baseline_near_clip_pixel_count": baseline_near,
        "candidate_near_clip_pixel_count": candidate_near,
        "near_clip_pixel_count_increase": candidate_near - baseline_near,
        "baseline_near_clip_fraction": baseline_near / pixel_count,
        "candidate_near_clip_fraction": candidate_near / pixel_count,
        "baseline_shared_highlight_plateau_fraction": baseline_plateau,
        "candidate_shared_highlight_plateau_fraction": candidate_plateau,
        "new_shared_highlight_plateau_fraction": new_plateau,
    }


def evaluate_canonical_settle_gates(
    measurements: dict[str, dict[str, Any]],
    *,
    scene_ids: tuple[str, ...],
    thresholds: dict[str, Any],
) -> dict[str, Any]:
    """Evaluate v4 final-raster clipping regression gates fail closed."""
    if set(thresholds) != set(CANONICAL_SETTLE_THRESHOLD_CONTRACT):
        raise StructuralValidationError(
            "canonical settle threshold keyが固定契約と一致しません"
        )
    normalized_thresholds = {
        "complete_clip_normalized_minimum": _require_number(
            thresholds.get("completeClipNormalizedMinimum"),
            "canonicalSettleGate.thresholds.completeClipNormalizedMinimum",
            minimum=0,
        ),
        "near_clip_normalized_minimum": _require_number(
            thresholds.get("nearClipNormalizedMinimum"),
            "canonicalSettleGate.thresholds.nearClipNormalizedMinimum",
            minimum=0,
        ),
        "complete_clip_maximum_pixel_count_increase": _require_integer(
            thresholds.get("completeClipMaximumPixelCountIncrease"),
            "canonicalSettleGate.thresholds.completeClipMaximumPixelCountIncrease",
        ),
        "near_clip_maximum_pixel_count_increase": _require_integer(
            thresholds.get("nearClipMaximumPixelCountIncrease"),
            "canonicalSettleGate.thresholds.nearClipMaximumPixelCountIncrease",
        ),
        "new_shared_plateau_maximum_area": _require_number(
            thresholds.get("newSharedPlateauMaximumArea"),
            "canonicalSettleGate.thresholds.newSharedPlateauMaximumArea",
            minimum=0,
        ),
    }
    if set(measurements) != set(scene_ids):
        raise StructuralValidationError(
            "canonical settle測定sceneがmanifestと一致しません"
        )

    required_metrics = {
        "pixel_count",
        "complete_clip_normalized_minimum",
        "near_clip_normalized_minimum",
        "baseline_complete_clip_pixel_count",
        "candidate_complete_clip_pixel_count",
        "complete_clip_pixel_count_increase",
        "baseline_complete_clip_fraction",
        "candidate_complete_clip_fraction",
        "baseline_near_clip_pixel_count",
        "candidate_near_clip_pixel_count",
        "near_clip_pixel_count_increase",
        "baseline_near_clip_fraction",
        "candidate_near_clip_fraction",
        "baseline_shared_highlight_plateau_fraction",
        "candidate_shared_highlight_plateau_fraction",
        "new_shared_highlight_plateau_fraction",
    }
    scenes: dict[str, Any] = {}
    scene_results: list[bool] = []
    for scene_id in scene_ids:
        entry = _require_dict(
            measurements[scene_id], f"canonicalSettle.{scene_id}"
        )
        metrics = _require_dict(
            entry.get("metrics"), f"canonicalSettle.{scene_id}.metrics"
        )
        if set(metrics) != required_metrics:
            raise StructuralValidationError(
                f"canonical settle metric keyが固定契約と一致しません: {scene_id}"
            )
        pixel_count = _require_integer(
            metrics.get("pixel_count"),
            f"canonicalSettle.{scene_id}.pixel_count",
            minimum=1,
        )
        integer_fields = (
            "baseline_complete_clip_pixel_count",
            "candidate_complete_clip_pixel_count",
            "baseline_near_clip_pixel_count",
            "candidate_near_clip_pixel_count",
        )
        counts = {
            field: _require_integer(
                metrics.get(field), f"canonicalSettle.{scene_id}.{field}"
            )
            for field in integer_fields
        }
        if any(value > pixel_count for value in counts.values()):
            raise StructuralValidationError(
                f"canonical settle clip pixel countが総pixel数を超えています: {scene_id}"
            )
        complete_increase = _require_integer(
            metrics.get("complete_clip_pixel_count_increase"),
            f"canonicalSettle.{scene_id}.complete_clip_pixel_count_increase",
            minimum=-pixel_count,
        )
        near_increase = _require_integer(
            metrics.get("near_clip_pixel_count_increase"),
            f"canonicalSettle.{scene_id}.near_clip_pixel_count_increase",
            minimum=-pixel_count,
        )
        if complete_increase != (
            counts["candidate_complete_clip_pixel_count"]
            - counts["baseline_complete_clip_pixel_count"]
        ) or near_increase != (
            counts["candidate_near_clip_pixel_count"]
            - counts["baseline_near_clip_pixel_count"]
        ):
            raise StructuralValidationError(
                f"canonical settle clip pixel increaseがcountと一致しません: {scene_id}"
            )
        complete_metric_threshold = _require_number(
            metrics.get("complete_clip_normalized_minimum"),
            f"canonicalSettle.{scene_id}.complete_clip_normalized_minimum",
            minimum=0,
        )
        near_metric_threshold = _require_number(
            metrics.get("near_clip_normalized_minimum"),
            f"canonicalSettle.{scene_id}.near_clip_normalized_minimum",
            minimum=0,
        )
        if (
            complete_metric_threshold
            != normalized_thresholds["complete_clip_normalized_minimum"]
            or near_metric_threshold
            != normalized_thresholds["near_clip_normalized_minimum"]
        ):
            raise StructuralValidationError(
                f"canonical settle測定thresholdがmanifestと一致しません: {scene_id}"
            )

        fraction_fields = (
            "baseline_complete_clip_fraction",
            "candidate_complete_clip_fraction",
            "baseline_near_clip_fraction",
            "candidate_near_clip_fraction",
            "baseline_shared_highlight_plateau_fraction",
            "candidate_shared_highlight_plateau_fraction",
            "new_shared_highlight_plateau_fraction",
        )
        fractions = {
            field: _require_number(
                metrics.get(field), f"canonicalSettle.{scene_id}.{field}", minimum=0
            )
            for field in fraction_fields
        }
        if any(value > 1 for value in fractions.values()):
            raise StructuralValidationError(
                f"canonical settle fractionが1を超えています: {scene_id}"
            )
        count_fraction_pairs = (
            ("baseline_complete_clip_pixel_count", "baseline_complete_clip_fraction"),
            ("candidate_complete_clip_pixel_count", "candidate_complete_clip_fraction"),
            ("baseline_near_clip_pixel_count", "baseline_near_clip_fraction"),
            ("candidate_near_clip_pixel_count", "candidate_near_clip_fraction"),
        )
        for count_field, fraction_field in count_fraction_pairs:
            if not math.isclose(
                fractions[fraction_field],
                counts[count_field] / pixel_count,
                rel_tol=0,
                abs_tol=1e-15,
            ):
                raise StructuralValidationError(
                    f"canonical settle fractionがpixel countと一致しません: "
                    f"{scene_id}/{fraction_field}"
                )

        complete_maximum = normalized_thresholds[
            "complete_clip_maximum_pixel_count_increase"
        ]
        near_maximum = normalized_thresholds[
            "near_clip_maximum_pixel_count_increase"
        ]
        plateau_maximum = normalized_thresholds[
            "new_shared_plateau_maximum_area"
        ]
        checks = {
            "complete_clip_pixel_count_non_regression": {
                "baseline": counts["baseline_complete_clip_pixel_count"],
                "candidate": counts["candidate_complete_clip_pixel_count"],
                "observed_increase": complete_increase,
                "maximum_increase": complete_maximum,
                "passed": complete_increase <= complete_maximum,
            },
            "near_clip_pixel_count_non_regression": {
                "baseline": counts["baseline_near_clip_pixel_count"],
                "candidate": counts["candidate_near_clip_pixel_count"],
                "observed_increase": near_increase,
                "maximum_increase": near_maximum,
                "passed": near_increase <= near_maximum,
            },
            "new_shared_highlight_plateau_area": {
                "baseline": fractions[
                    "baseline_shared_highlight_plateau_fraction"
                ],
                "candidate": fractions[
                    "candidate_shared_highlight_plateau_fraction"
                ],
                "new": fractions["new_shared_highlight_plateau_fraction"],
                "maximum_new": plateau_maximum,
                "passed": fractions["new_shared_highlight_plateau_fraction"]
                <= plateau_maximum,
            },
        }
        passed = all(check["passed"] for check in checks.values())
        scenes[scene_id] = {"passed": passed, "checks": checks}
        scene_results.append(passed)
    return {
        "thresholds": normalized_thresholds,
        "expected_scene_count": len(scene_ids),
        "evaluated_scene_count": len(scene_results),
        "scenes": scenes,
        "passed": bool(scene_results) and all(scene_results),
    }


def validate_manifest(manifest: dict[str, Any], root: Path) -> dict[str, Any]:
    schema_version = manifest.get("schemaVersion")
    if schema_version not in SUPPORTED_MANIFEST_SCHEMA_VERSIONS:
        raise StructuralValidationError(
            f"未対応のmanifest schemaです: {schema_version}"
        )
    suite_id = _require_text(manifest.get("suiteID"), "manifest.suiteID")
    _require_text(manifest.get("description"), "manifest.description")
    expected_environment = _require_dict(
        manifest.get("expectedEnvironment"), "manifest.expectedEnvironment"
    )
    for field in (
        "macOSVersion", "macOSBuild", "architecture", "hardwareModel",
        "metalDevice", "rawDecoderBackend",
    ):
        _require_text(expected_environment.get(field), f"expectedEnvironment.{field}")

    processing = _require_dict(manifest.get("processing"), "manifest.processing")
    fingerprint = _require_dict(processing.get("fingerprint"), "processing.fingerprint")
    for field in (
        "rawDecode", "basicTone", "toneCurve", "colorMixer", "outputTransform"
    ):
        _require_text(fingerprint.get(field), f"processing.fingerprint.{field}")
    if schema_version <= 3:
        render_pipeline = fingerprint.get(
            "renderPipeline",
            LEGACY_RENDER_PIPELINE_IDENTIFIER,
        )
        if render_pipeline != LEGACY_RENDER_PIPELINE_IDENTIFIER:
            raise StructuralValidationError(
                "processing.fingerprint.renderPipelineがlegacy契約と一致しません"
            )
    elif fingerprint.get("renderPipeline") != CURRENT_RENDER_PIPELINE_IDENTIFIER:
        raise StructuralValidationError(
            "processing.fingerprint.renderPipelineがschema v4契約と一致しません"
        )
    source_files = _require_list(processing.get("sourceFiles"), "processing.sourceFiles")
    if not source_files:
        raise StructuralValidationError("processing.sourceFilesが空です")
    source_paths = [_require_text(path, "processing.sourceFiles[]") for path in source_files]
    if len(set(source_paths)) != len(source_paths):
        raise StructuralValidationError("processing.sourceFilesが重複しています")
    for path in source_paths:
        resolve_inside(root, path)

    comparison = _require_dict(manifest.get("comparison"), "manifest.comparison")
    for field, expected in COMPARISON_CONTRACT.items():
        if comparison.get(field) != expected:
            raise StructuralValidationError(
                f"comparison.{field}がv2固定契約と一致しません: "
                f"expected={expected!r} actual={comparison.get(field)!r}"
            )

    preset = _require_dict(manifest.get("preset"), "manifest.preset")
    preset_file = _require_dict(preset.get("file"), "preset.file")
    resolve_inside(root, preset_file.get("path"))
    _require_sha256(preset_file.get("sha256"), "preset.file.sha256")
    for field in ("uuid", "cameraRawVersion", "processVersion"):
        _require_text(preset.get(field), f"preset.{field}")

    diagnostics = _require_dict(manifest.get("diagnostics"), "manifest.diagnostics")
    for field in ("boostAmounts", "extendedDynamicRangeAmounts"):
        values = _require_list(diagnostics.get(field), f"diagnostics.{field}")
        numbers = [_require_number(value, f"diagnostics.{field}[]", minimum=0) for value in values]
        if not numbers or len(set(numbers)) != len(numbers):
            raise StructuralValidationError(f"diagnostics.{field}は空または重複しています")

    raw_profile = _require_dict(manifest.get("rawProfile"), "manifest.rawProfile")
    for field, expected in RAW_PROFILE_CONTRACT.items():
        if raw_profile.get(field) != expected:
            raise StructuralValidationError(
                f"rawProfile.{field}がv2固定契約と一致しません: "
                f"expected={expected!r} actual={raw_profile.get(field)!r}"
            )

    legacy = _require_list(manifest.get("legacyCandidates"), "manifest.legacyCandidates")
    legacy_contract: dict[str, tuple[str, str]] = {}
    for value in legacy:
        candidate = _require_dict(value, "legacyCandidates[]")
        identifier = _safe_identifier(candidate.get("id"), "legacyCandidates.id")
        legacy_contract[identifier] = (
            _safe_identifier(candidate.get("rawLabel"), "legacyCandidates.rawLabel"),
            _safe_identifier(
                candidate.get("lightroomInputLabel"),
                "legacyCandidates.lightroomInputLabel",
            ),
        )
    if legacy_contract != LEGACY_CANDIDATE_CONTRACT or len(legacy_contract) != len(legacy):
        raise StructuralValidationError(
            "legacyCandidatesのID/labelは既存report contractと一致する必要があります"
        )

    stage_matrix = _require_list(manifest.get("stageMatrix"), "manifest.stageMatrix")
    if not stage_matrix:
        raise StructuralValidationError("stageMatrixが空です")
    stage_contract: dict[str, tuple[str, str]] = {}
    all_labels = {label for labels in legacy_contract.values() for label in labels}
    for value in stage_matrix:
        candidate = _require_dict(value, "stageMatrix[]")
        identifier = _safe_identifier(candidate.get("id"), "stageMatrix.id")
        raw_label = _safe_identifier(candidate.get("rawLabel"), "stageMatrix.rawLabel")
        lr_label = _safe_identifier(
            candidate.get("lightroomInputLabel"), "stageMatrix.lightroomInputLabel"
        )
        if identifier in stage_contract or raw_label in all_labels or lr_label in all_labels or raw_label == lr_label:
            raise StructuralValidationError("stageMatrixのIDまたはlabelが重複しています")
        stage_contract[identifier] = (raw_label, lr_label)
        all_labels.update((raw_label, lr_label))
    if stage_contract != STAGE_CANDIDATE_CONTRACT:
        raise StructuralValidationError(
            "stageMatrixのID/labelがv2固定契約と一致しません"
        )

    scenes = _require_list(manifest.get("scenes"), "manifest.scenes")
    if len(scenes) != 2:
        raise StructuralValidationError(
            f"manifest schema v2は固定2 sceneが必要です: actual={len(scenes)}"
        )
    scene_ids: set[str] = set()
    for value in scenes:
        scene = _require_dict(value, "scenes[]")
        scene_id = _safe_identifier(scene.get("id"), "scene.id")
        if scene_id in scene_ids:
            raise StructuralValidationError(f"scene.idが重複しています: {scene_id}")
        scene_ids.add(scene_id)
        _require_text(scene.get("sceneGroup"), f"scenes.{scene_id}.sceneGroup")
        fold = _require_text(scene.get("fold"), f"scenes.{scene_id}.fold")
        if fold not in ("train", "holdout", "development"):
            raise StructuralValidationError(f"scenes.{scene_id}.foldが未対応です: {fold}")
        _require_text(scene.get("lighting"), f"scenes.{scene_id}.lighting")
        capture = _require_dict(scene.get("capture"), f"scenes.{scene_id}.capture")
        _require_integer(capture.get("width"), f"scenes.{scene_id}.capture.width", minimum=1)
        _require_integer(capture.get("height"), f"scenes.{scene_id}.capture.height", minimum=1)
        for fixture_name in ("raw", "lightroomBefore", "lightroomAfter"):
            fixture = _require_dict(scene.get(fixture_name), f"scenes.{scene_id}.{fixture_name}")
            resolve_inside(root, fixture.get("path"))
            _require_sha256(fixture.get("sha256"), f"scenes.{scene_id}.{fixture_name}.sha256")

    quality_gate = _require_dict(manifest.get("qualityGate"), "manifest.qualityGate")
    routes = _require_list(quality_gate.get("routes"), "qualityGate.routes")
    if not routes:
        raise StructuralValidationError("qualityGate.routesが空です")
    route_ids: set[str] = set()
    legacy_labels = {label for pair in legacy_contract.values() for label in pair}
    for value in routes:
        route = _require_dict(value, "qualityGate.routes[]")
        route_id = _safe_identifier(route.get("id"), "qualityGate.route.id")
        if route_id in route_ids:
            raise StructuralValidationError(f"qualityGate.route.idが重複しています: {route_id}")
        route_ids.add(route_id)
        if route.get("basicLabel") not in legacy_labels or route.get("fullLabel") not in legacy_labels:
            raise StructuralValidationError(f"qualityGate routeが未定義labelを参照しています: {route_id}")
    if route_ids != {"raw", "lr-input"}:
        raise StructuralValidationError(
            "qualityGate.routesは既存report contractのraw/lr-inputである必要があります"
        )
    for field in (
        "meanDeltaEMaximumIncrease",
        "meanEVAbsoluteErrorMaximumIncrease",
        "newSharedPlateauMaximumArea",
    ):
        _require_number(quality_gate.get(field), f"qualityGate.{field}", minimum=0)

    benchmark = _require_dict(manifest.get("benchmark"), "manifest.benchmark")
    preview_parity = _require_dict(
        manifest.get("previewParity"), "manifest.previewParity"
    )
    stage_ids = _require_list(
        preview_parity.get("settingsStageIDs"),
        "previewParity.settingsStageIDs",
    )
    if stage_ids != list(PREVIEW_PARITY_STAGE_IDS):
        raise StructuralValidationError(
            "previewParity.settingsStageIDsが固定3 stageと一致しません"
        )
    if (
        preview_parity.get("baselineDecodeIntent") != "full-resolution"
        or preview_parity.get("candidateDecodeIntent") != "interactive-preview"
    ):
        raise StructuralValidationError(
            "previewParity decode intentが固定契約と一致しません"
        )
    preview_thresholds = _require_dict(
        preview_parity.get("thresholds"), "previewParity.thresholds"
    )
    if schema_version == 2:
        forbidden_v3_fields = {
            "outputMaxDimension",
            "candidateDecodeMaximumDimensions",
            "plateauSpatialTolerance",
        }
        if forbidden_v3_fields & set(preview_parity):
            raise StructuralValidationError(
                "schema v2 previewParityにv3専用fieldを指定できません"
            )
        preview_max_dimension = _require_integer(
            preview_parity.get("maxDimension"),
            "previewParity.maxDimension",
            minimum=1,
        )
        if benchmark.get("previewMaxDimension") != preview_max_dimension:
            raise StructuralValidationError(
                "previewParity.maxDimensionがbenchmark.previewMaxDimensionと一致しません"
            )
        threshold_contract = {
            "meanDeltaEMaximum": DEFAULT_PREVIEW_PARITY_THRESHOLDS[
                "mean_delta_e_maximum"
            ],
            "meanEVAbsoluteDriftMaximum": DEFAULT_PREVIEW_PARITY_THRESHOLDS[
                "mean_ev_absolute_drift_maximum"
            ],
            "newSharedPlateauMaximumArea": DEFAULT_PREVIEW_PARITY_THRESHOLDS[
                "new_shared_plateau_maximum_area"
            ],
        }
    else:
        if "maxDimension" in preview_parity:
            raise StructuralValidationError(
                "schema v3/v4 previewParityに旧maxDimensionを指定できません"
            )
        output_max_dimension = _require_integer(
            preview_parity.get("outputMaxDimension"),
            "previewParity.outputMaxDimension",
            minimum=1,
        )
        if benchmark.get("previewMaxDimension") != output_max_dimension:
            raise StructuralValidationError(
                "previewParity.outputMaxDimensionがbenchmark.previewMaxDimensionと一致しません"
            )
        if output_max_dimension != 2_560:
            raise StructuralValidationError(
                "schema v3/v4 previewParity.outputMaxDimensionは2560固定です"
            )
        candidate_dimensions = [
            _require_integer(
                value,
                "previewParity.candidateDecodeMaximumDimensions[]",
                minimum=output_max_dimension + 1,
            )
            for value in _require_list(
                preview_parity.get("candidateDecodeMaximumDimensions"),
                "previewParity.candidateDecodeMaximumDimensions",
            )
        ]
        if candidate_dimensions != [3_072, 3_840] or len(set(candidate_dimensions)) != 2:
            raise StructuralValidationError(
                "schema v3/v4 candidate decode dimensionは3072/3840の固定順が必要です"
            )
        tolerance = _require_dict(
            preview_parity.get("plateauSpatialTolerance"),
            "previewParity.plateauSpatialTolerance",
        )
        if set(tolerance) != {"radiusPixels", "structuringElement"}:
            raise StructuralValidationError(
                "previewParity.plateauSpatialTolerance keyが固定契約と一致しません"
            )
        if (
            tolerance.get("radiusPixels") != 1
            or tolerance.get("structuringElement") != "square-3x3"
        ):
            raise StructuralValidationError(
                "schema v3/v4 plateau spatial toleranceはsquare-3x3/Chebyshev半径1固定です"
            )
        threshold_contract = {
            "meanDeltaEMaximum": DEFAULT_PREVIEW_PARITY_V3_THRESHOLDS[
                "mean_delta_e_maximum"
            ],
            "blurredDeltaE2000P95Maximum": DEFAULT_PREVIEW_PARITY_V3_THRESHOLDS[
                "delta_e_p95_maximum"
            ],
            "meanEVAbsoluteDriftMaximum": DEFAULT_PREVIEW_PARITY_V3_THRESHOLDS[
                "mean_ev_absolute_drift_maximum"
            ],
            "netSharedPlateauAreaIncreaseMaximum": (
                DEFAULT_PREVIEW_PARITY_V3_THRESHOLDS[
                    "net_shared_plateau_area_increase_maximum"
                ]
            ),
            "spatiallyDistinctNewSharedPlateauMaximumArea": (
                DEFAULT_PREVIEW_PARITY_V3_THRESHOLDS[
                    "spatially_distinct_new_shared_plateau_maximum_area"
                ]
            ),
        }
    if set(preview_thresholds) != set(threshold_contract):
        raise StructuralValidationError(
            "previewParity.thresholdsのkeyが固定契約と一致しません"
        )
    for field, maximum in threshold_contract.items():
        value = _require_number(
            preview_thresholds.get(field),
            f"previewParity.thresholds.{field}",
            minimum=0,
        )
        if value > maximum:
            raise StructuralValidationError(
                f"previewParity.thresholds.{field}が固定上限を超えています: "
                f"actual={value} maximum={maximum}"
            )
    _validate_canonical_settle_contract(
        manifest,
        schema_version=schema_version,
    )
    if schema_version == 4:
        canonical_settle = manifest["canonicalSettleGate"]
        if canonical_settle["outputMaxDimension"] != preview_parity[
            "outputMaxDimension"
        ]:
            raise StructuralValidationError(
                "canonicalSettleGate.outputMaxDimensionがpreviewParityと一致しません"
            )
    return {"suite_id": suite_id, "scene_ids": tuple(scene_ids)}


def _fixture_records(manifest: dict[str, Any], root: Path) -> list[dict[str, Any]]:
    items: list[tuple[str, dict[str, Any]]] = [("preset", manifest["preset"]["file"])]
    for scene in manifest["scenes"]:
        items.extend(
            (
                (f"{scene['id']}.raw", scene["raw"]),
                (f"{scene['id']}.lightroomBefore", scene["lightroomBefore"]),
                (f"{scene['id']}.lightroomAfter", scene["lightroomAfter"]),
            )
        )
    records: list[dict[str, Any]] = []
    for role, fixture in items:
        path = resolve_inside(root, fixture["path"])
        actual = sha256_file(path)
        if actual != fixture["sha256"]:
            raise StructuralValidationError(
                f"入力SHA-256不一致: {fixture['path']} expected={fixture['sha256']} actual={actual}"
            )
        records.append(
            {
                "role": role,
                "path": fixture["path"],
                "sha256": actual,
                "byteCount": path.stat().st_size,
            }
        )
    return records


def _verified_records(value: Any, field: str) -> list[dict[str, Any]]:
    records = _require_list(value, field)
    normalized: list[dict[str, Any]] = []
    paths: set[str] = set()
    for index, item in enumerate(records):
        record = _require_dict(item, f"{field}[{index}]")
        path = _require_text(record.get("path"), f"{field}[{index}].path")
        if path in paths:
            raise StructuralValidationError(f"{field}にpath重複があります: {path}")
        paths.add(path)
        normalized.append(
            {
                "role": _require_text(record.get("role"), f"{field}[{index}].role"),
                "path": path,
                "sha256": _require_sha256(record.get("sha256"), f"{field}[{index}].sha256"),
                "byteCount": _require_integer(
                    record.get("byteCount"), f"{field}[{index}].byteCount"
                ),
            }
        )
    return normalized


def _records_by_path(records: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {record["path"]: record for record in records}


def _three_digit_label(value: float) -> str:
    return f"{int(math.floor(value * 100 + 0.5)):03d}"


def expected_artifact_specs(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    specs: dict[str, dict[str, Any]] = {}

    def add(path: str, **fields: Any) -> None:
        if path in specs:
            raise StructuralValidationError(f"manifestから同一artifact pathが生成されます: {path}")
        specs[path] = fields

    for scene in manifest["scenes"]:
        scene_id = scene["id"]
        for reference in ("before", "after"):
            add(
                f".photobench/calibration/references/{scene_id}-lightroom-{reference}.tif",
                role=f"normalized-reference-{reference}", sceneID=scene_id,
                route=None, candidateGroup=None, candidateID=None, label=None,
            )
        for amount in manifest["diagnostics"]["boostAmounts"]:
            label = _three_digit_label(float(amount))
            add(
                f".photobench/calibration/renders/{scene_id}-boost-{label}.tif",
                role="diagnostic-candidate", sceneID=scene_id, route="raw",
                candidateGroup="boost", candidateID=label, label=f"boost-{label}",
            )
        for amount in manifest["diagnostics"]["extendedDynamicRangeAmounts"]:
            amount_label = _three_digit_label(float(amount))
            for candidate_id, label in (
                ("neutral", f"edr-{amount_label}"),
                ("basic-legacy", f"xmp-basic-edr-{amount_label}"),
                ("full-current", f"xmp-full-edr-{amount_label}"),
            ):
                add(
                    f".photobench/calibration/renders/{scene_id}-{label}.tif",
                    role="diagnostic-candidate", sceneID=scene_id, route="raw",
                    candidateGroup="edr", candidateID=candidate_id, label=label,
                )
        for group, definitions in (
            ("legacy", manifest["legacyCandidates"]),
            ("stage-matrix", manifest["stageMatrix"]),
        ):
            for definition in definitions:
                for route, label in (
                    ("raw", definition["rawLabel"]),
                    ("lr-input", definition["lightroomInputLabel"]),
                ):
                    add(
                        f".photobench/calibration/renders/{scene_id}-{label}.tif",
                        role="comparison-candidate", sceneID=scene_id, route=route,
                        candidateGroup=group, candidateID=definition["id"], label=label,
                    )
        preview_parity = manifest["previewParity"]
        if manifest["schemaVersion"] == 2:
            for stage_id in preview_parity["settingsStageIDs"]:
                for intent_field, role in (
                    ("baselineDecodeIntent", "preview-parity-baseline"),
                    ("candidateDecodeIntent", "preview-parity-candidate"),
                ):
                    intent = preview_parity[intent_field]
                    route_label = PREVIEW_PARITY_ROUTE_LABELS[intent]
                    label = f"preview-parity-{stage_id}-{route_label}"
                    add(
                        f".photobench/calibration/renders/{scene_id}-{label}.tif",
                        role=role,
                        sceneID=scene_id,
                        route=PREVIEW_PARITY_DECODE_ROUTES[intent],
                        candidateGroup="preview-parity",
                        candidateID=stage_id,
                        label=label,
                    )
        else:
            output_dimension = preview_parity["outputMaxDimension"]
            for stage_id in preview_parity["settingsStageIDs"]:
                baseline_label = (
                    f"preview-parity-{stage_id}-full-decode-to-{output_dimension}"
                )
                add(
                    f".photobench/calibration/renders/{scene_id}-{baseline_label}.tif",
                    role="preview-parity-baseline",
                    sceneID=scene_id,
                    route=PREVIEW_PARITY_V3_BASELINE_ROUTE,
                    candidateGroup="preview-parity",
                    candidateID=stage_id,
                    label=baseline_label,
                )
                for decode_dimension in preview_parity[
                    "candidateDecodeMaximumDimensions"
                ]:
                    candidate_label = (
                        f"preview-parity-{stage_id}-decode-{decode_dimension}"
                        f"-to-{output_dimension}"
                    )
                    add(
                        f".photobench/calibration/renders/{scene_id}-{candidate_label}.tif",
                        role="preview-parity-candidate",
                        sceneID=scene_id,
                        route=preview_parity_v3_candidate_route(decode_dimension),
                        candidateGroup="preview-parity",
                        candidateID=stage_id,
                        label=candidate_label,
                    )
    return specs


def _validate_finite_tree(value: Any, field: str) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise StructuralValidationError(f"{field}に非finite値があります")
    if isinstance(value, list):
        for index, item in enumerate(value):
            _validate_finite_tree(item, f"{field}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            _validate_finite_tree(item, f"{field}.{key}")


def _validate_artifacts(
    run: dict[str, Any], manifest: dict[str, Any], root: Path
) -> tuple[dict[str, dict[str, Any]], dict[str, Any]]:
    expected = expected_artifact_specs(manifest)
    artifacts = _require_list(run.get("artifacts"), "run.artifacts")
    actual: dict[str, dict[str, Any]] = {}
    for index, value in enumerate(artifacts):
        artifact = _require_dict(value, f"run.artifacts[{index}]")
        relative = _require_text(artifact.get("path"), f"run.artifacts[{index}].path")
        if relative in actual:
            raise StructuralValidationError(f"artifact pathが重複しています: {relative}")
        spec = expected.get(relative)
        if spec is None:
            raise StructuralValidationError(f"manifestにないartifactがあります: {relative}")
        for field, wanted in spec.items():
            if artifact.get(field) != wanted:
                raise StructuralValidationError(
                    f"artifact metadata不一致: {relative} {field} expected={wanted!r} actual={artifact.get(field)!r}"
                )
        path = resolve_inside(root, relative)
        expected_hash = _require_sha256(artifact.get("sha256"), f"artifact.{relative}.sha256")
        actual_hash = sha256_file(path)
        if actual_hash != expected_hash:
            raise StructuralValidationError(
                f"artifact SHA-256不一致: {relative} expected={expected_hash} actual={actual_hash}"
            )
        byte_count = _require_integer(artifact.get("byteCount"), f"artifact.{relative}.byteCount")
        if path.stat().st_size != byte_count:
            raise StructuralValidationError(
                f"artifact byteCount不一致: {relative} expected={byte_count} actual={path.stat().st_size}"
            )
        width = _require_integer(artifact.get("width"), f"artifact.{relative}.width", minimum=1)
        height = _require_integer(artifact.get("height"), f"artifact.{relative}.height", minimum=1)
        image = read_srgb(path)
        if image.shape[:2] != (height, width):
            raise StructuralValidationError(
                f"artifact dimension不一致: {relative} expected={width}x{height} actual={image.shape[1]}x{image.shape[0]}"
            )
        _require_number(
            artifact.get("renderAndEncodeMilliseconds"),
            f"artifact.{relative}.renderAndEncodeMilliseconds",
            minimum=0,
        )
        settings_hash = _require_sha256(
            artifact.get("settingsSHA256"), f"artifact.{relative}.settingsSHA256"
        )
        settings = _require_dict(
            artifact.get("settings"), f"artifact.{relative}.settings"
        )
        _validate_finite_tree(settings, f"artifact.{relative}.settings")
        canonical_settings = json.dumps(
            settings,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        actual_settings_hash = hashlib.sha256(canonical_settings).hexdigest()
        if settings_hash != actual_settings_hash:
            raise StructuralValidationError(
                f"artifact settingsSHA256不一致: {relative} "
                f"expected={settings_hash} actual={actual_settings_hash}"
            )
        actual[relative] = artifact
    missing = sorted(set(expected) - set(actual))
    if missing:
        raise StructuralValidationError(
            "run manifestにartifactが不足しています: " + ", ".join(missing)
        )
    return actual, {"expected": len(expected), "verified": len(actual)}


def _validate_sources(
    run: dict[str, Any], manifest: dict[str, Any], root: Path
) -> dict[str, Any]:
    records = _verified_records(run.get("sourceFiles"), "run.sourceFiles")
    expected_paths = sorted(manifest["processing"]["sourceFiles"])
    if sorted(record["path"] for record in records) != expected_paths:
        raise StructuralValidationError("run.sourceFilesがmanifest.processing.sourceFilesと一致しません")
    by_path = _records_by_path(records)
    for relative in expected_paths:
        path = resolve_inside(root, relative)
        record = by_path[relative]
        if record["role"] != "implementationSource":
            raise StructuralValidationError(
                f"source roleがimplementationSourceではありません: {relative}"
            )
        actual_hash = sha256_file(path)
        if actual_hash != record["sha256"] or path.stat().st_size != record["byteCount"]:
            raise StructuralValidationError(f"implementation sourceが校正後に変わりました: {relative}")
    canonical = "\n".join(
        f"{relative}\0{by_path[relative]['sha256']}" for relative in expected_paths
    ).encode("utf-8")
    fingerprint = hashlib.sha256(canonical).hexdigest()
    if run.get("sourceFingerprintSHA256") != fingerprint:
        raise StructuralValidationError("run.sourceFingerprintSHA256がsourceFilesと一致しません")
    return {"sha256": fingerprint, "files": records}


def validate_run_manifest(
    run: dict[str, Any],
    manifest: dict[str, Any],
    root: Path,
    manifest_relative_path: str,
    manifest_sha256: str,
) -> dict[str, Any]:
    if run.get("schemaVersion") != RUN_SCHEMA_VERSION:
        raise StructuralValidationError(f"未対応のrun schemaです: {run.get('schemaVersion')}")
    if run.get("status") != "complete" or not run.get("completedAtUTC"):
        raise StructuralValidationError(
            f"calibration runがcompleteではありません: {run.get('status')}"
        )
    _require_text(run.get("runID"), "run.runID")
    _require_text(run.get("startedAtUTC"), "run.startedAtUTC")
    manifest_reference = _require_dict(run.get("manifest"), "run.manifest")
    expected_reference = {
        "path": manifest_relative_path,
        "sha256": manifest_sha256,
        "suiteID": manifest["suiteID"],
    }
    if manifest_reference != expected_reference:
        raise StructuralValidationError(
            f"run.manifestが現在のmanifestと一致しません: expected={expected_reference} actual={manifest_reference}"
        )
    normalized_run_processing = _normalized_processing_fingerprint(
        run.get("processing"),
        schema_version=manifest["schemaVersion"],
        field="run.processing",
    )
    normalized_manifest_processing = _normalized_processing_fingerprint(
        manifest["processing"]["fingerprint"],
        schema_version=manifest["schemaVersion"],
        field="manifest.processing.fingerprint",
    )
    if normalized_run_processing != normalized_manifest_processing:
        raise StructuralValidationError("run.processingがmanifest.processing.fingerprintと一致しません")

    current_inputs = _fixture_records(manifest, root)
    preflight = _verified_records(run.get("verifiedInputs"), "run.verifiedInputs")
    postflight = _verified_records(
        run.get("postflightVerifiedInputs"), "run.postflightVerifiedInputs"
    )
    current_by_path = _records_by_path(current_inputs)
    if _records_by_path(preflight) != current_by_path:
        raise StructuralValidationError("run preflight入力が現在のmanifest fixtureと一致しません")
    if _records_by_path(postflight) != current_by_path:
        raise StructuralValidationError("run postflight入力が現在のmanifest fixtureと一致しません")

    runtime = _require_dict(run.get("runtime"), "run.runtime")
    expected_environment = manifest["expectedEnvironment"]
    runtime_fields = {
        "macOSVersion": runtime.get("macOSVersion"),
        "macOSBuild": runtime.get("macOSBuild"),
        "architecture": runtime.get("architecture"),
        "hardwareModel": runtime.get("hardwareModel"),
        "metalDevice": _require_dict(runtime.get("metalDevice"), "run.runtime.metalDevice").get("name"),
    }
    for field, actual in runtime_fields.items():
        if actual != expected_environment[field]:
            raise StructuralValidationError(
                f"run runtime不一致: {field} expected={expected_environment[field]} actual={actual}"
            )
    _require_sha256(
        runtime.get("executableSHA256"), "run.runtime.executableSHA256"
    )
    _validate_finite_tree(runtime, "run.runtime")

    sources = _validate_sources(run, manifest, root)
    postflight_source_fingerprint = _require_sha256(
        run.get("postflightSourceFingerprintSHA256"),
        "run.postflightSourceFingerprintSHA256",
    )
    if postflight_source_fingerprint != run.get("sourceFingerprintSHA256"):
        raise StructuralValidationError(
            "run source fingerprintのpreflight/postflightが一致しません"
        )
    artifact_map, artifact_validation = _validate_artifacts(run, manifest, root)

    decodes = _require_list(run.get("decodes"), "run.decodes")
    decode_keys: set[tuple[str, str]] = set()
    preview_specification = manifest["previewParity"]
    full_preview_route = PREVIEW_PARITY_V3_BASELINE_ROUTE
    if manifest["schemaVersion"] == 2:
        candidate_preview_routes = {
            PREVIEW_PARITY_DECODE_ROUTES["interactive-preview"]: (
                preview_specification["maxDimension"]
            )
        }
    else:
        candidate_preview_routes = {
            preview_parity_v3_candidate_route(dimension): dimension
            for dimension in preview_specification[
                "candidateDecodeMaximumDimensions"
            ]
        }
    supported_routes = {
        "raw",
        "lr-input",
        full_preview_route,
        *candidate_preview_routes,
    }
    for index, value in enumerate(decodes):
        decode = _require_dict(value, f"run.decodes[{index}]")
        key = (
            _require_text(decode.get("sceneID"), f"run.decodes[{index}].sceneID"),
            _require_text(decode.get("route"), f"run.decodes[{index}].route"),
        )
        if key in decode_keys:
            raise StructuralValidationError(f"run decodeが重複しています: {key}")
        decode_keys.add(key)
        scene = next((item for item in manifest["scenes"] if item["id"] == key[0]), None)
        if scene is None or key[1] not in supported_routes:
            raise StructuralValidationError(f"run decodeが未知のscene/routeを参照しています: {key}")
        capture_width = scene["capture"]["width"]
        capture_height = scene["capture"]["height"]
        native_width = _require_integer(
            decode.get("nativeWidth"),
            f"run.decodes[{index}].nativeWidth",
            minimum=1,
        )
        native_height = _require_integer(
            decode.get("nativeHeight"),
            f"run.decodes[{index}].nativeHeight",
            minimum=1,
        )
        width = _require_integer(
            decode.get("width"), f"run.decodes[{index}].width", minimum=1
        )
        height = _require_integer(
            decode.get("height"), f"run.decodes[{index}].height", minimum=1
        )
        if (native_width, native_height) != (capture_width, capture_height):
            raise StructuralValidationError(f"run decode native dimension不一致: {key}")
        intent = _require_text(decode.get("intent"), f"run.decodes[{index}].intent")

        is_raw_route = key[1] in (
            "raw",
            full_preview_route,
            *candidate_preview_routes,
        )
        if is_raw_route:
            if decode.get("backend") != expected_environment["rawDecoderBackend"]:
                raise StructuralValidationError(f"RAW decoder backend不一致: {key}")
            if decode.get("calibrationID") != manifest["rawProfile"]["id"]:
                raise StructuralValidationError(f"RAW calibrationID不一致: {key}")
        if key[1] in candidate_preview_routes:
            preview_max_dimension = candidate_preview_routes[key[1]]
            if intent != preview_specification["candidateDecodeIntent"]:
                raise StructuralValidationError(f"preview candidate decode intent不一致: {key}")
            if decode.get("requestedMaximumDimension") != preview_max_dimension:
                raise StructuralValidationError(
                    f"preview candidate requested dimension不一致: {key}"
                )
            applied_scale = _require_number(
                decode.get("appliedScaleFactor"),
                f"run.decodes[{index}].appliedScaleFactor",
                minimum=0,
            )
            expected_scale = min(
                1.0,
                preview_max_dimension / max(capture_width, capture_height),
            )
            if applied_scale <= 0 or abs(applied_scale - expected_scale) > 0.000_001:
                raise StructuralValidationError(
                    f"preview candidate scaleFactor不一致: {key} "
                    f"expected={expected_scale} actual={applied_scale}"
                )
            expected_width = capture_width * expected_scale
            expected_height = capture_height * expected_scale
            if (
                abs(width - expected_width) > 1
                or abs(height - expected_height) > 1
                or abs(max(width, height) - min(
                    preview_max_dimension, max(capture_width, capture_height)
                )) > 1
            ):
                raise StructuralValidationError(
                    f"preview candidate output dimension不一致: {key} "
                    f"actual={width}x{height}"
                )
        else:
            if intent != "full-resolution":
                raise StructuralValidationError(f"full decode intent不一致: {key}")
            if decode.get("requestedMaximumDimension") is not None:
                raise StructuralValidationError(
                    f"full decodeにrequestedMaximumDimensionがあります: {key}"
                )
            if (width, height) != (capture_width, capture_height):
                raise StructuralValidationError(f"run decode dimension不一致: {key}")
            applied_scale = decode.get("appliedScaleFactor")
            if is_raw_route:
                scale = _require_number(
                    applied_scale,
                    f"run.decodes[{index}].appliedScaleFactor",
                    minimum=0,
                )
                if abs(scale - 1.0) > 0.000_001:
                    raise StructuralValidationError(
                        f"full RAW decode scaleFactor不一致: {key}"
                    )
            elif applied_scale is not None:
                raise StructuralValidationError(
                    f"raster decodeにRAW scaleFactorがあります: {key}"
                )
        _require_number(
            decode.get("decoderGraphSetupMilliseconds"),
            f"run.decodes[{index}].decoderGraphSetupMilliseconds",
            minimum=0,
        )
    expected_decode_keys = {
        (scene["id"], route)
        for scene in manifest["scenes"]
        for route in (
            "raw",
            "lr-input",
            full_preview_route,
            *candidate_preview_routes,
        )
    }
    if decode_keys != expected_decode_keys:
        raise StructuralValidationError("run.decoded scene/routeが不足または過剰です")

    headroom = _require_list(run.get("edrHeadroom"), "run.edrHeadroom")
    headroom_keys: set[tuple[str, float]] = set()
    expected_amounts = {
        float(amount) for amount in manifest["diagnostics"]["extendedDynamicRangeAmounts"]
    }
    scene_ids = {scene["id"] for scene in manifest["scenes"]}
    for index, value in enumerate(headroom):
        record = _require_dict(value, f"run.edrHeadroom[{index}]")
        scene_id = _require_text(record.get("sceneID"), f"run.edrHeadroom[{index}].sceneID")
        amount = _require_number(record.get("amount"), f"run.edrHeadroom[{index}].amount", minimum=0)
        key = (scene_id, amount)
        if key in headroom_keys or scene_id not in scene_ids or amount not in expected_amounts:
            raise StructuralValidationError(f"EDR headroom recordが重複または未知です: {key}")
        headroom_keys.add(key)
        for field in (
            "maximumChannel", "extendedChannelPixelFraction",
            "maximumLuminance", "extendedLuminancePixelFraction",
        ):
            _require_number(record.get(field), f"run.edrHeadroom[{index}].{field}", minimum=0)
    expected_headroom_keys = {
        (scene_id, amount) for scene_id in scene_ids for amount in expected_amounts
    }
    if headroom_keys != expected_headroom_keys:
        raise StructuralValidationError("EDR headroom recordが不足しています")

    return {
        "manifest": {"path": manifest_relative_path, "sha256": manifest_sha256},
        "inputs": {"verified": len(current_inputs), "preflight_matches": True, "postflight_matches": True},
        "sources": {
            **sources,
            "postflight_sha256": postflight_source_fingerprint,
            "postflight_matches": True,
        },
        "artifacts": artifact_validation,
        "artifact_map": artifact_map,
        "runtime": runtime,
        "decodes": decodes,
        "edr_headroom": headroom,
    }


def _methodology(
    thresholds: dict[str, float],
    preview_thresholds: dict[str, float] = DEFAULT_PREVIEW_PARITY_THRESHOLDS,
    *,
    preview_schema_version: int = 2,
    preview_spatial_tolerance: dict[str, Any] | None = None,
    canonical_settle_specification: dict[str, Any] | None = None,
) -> dict[str, Any]:
    methodology: dict[str, Any] = {
        "delta_e_blur_sigma": 1.2,
        "gate_numeric_precision": "unrounded IEEE-754 values; report preserves full precision",
        "clip_source": "unblurred normalized 16-bit TIFF",
        "complete_clip_threshold": "1 - 0.5 / 65535",
        "near_clip_threshold": 0.999,
        "highlight_plateau_source": "unblurred encoded-sRGB luminance",
        "highlight_plateau_selection": "brightest 0.1% with percentile ties",
        "highlight_plateau_adjacency": "horizontal and vertical spatial neighbours",
        "highlight_plateau_maximum_code_value_difference": "2 / 65535",
        "highlight_plateau_denominator": "all image pixels",
        "highlight_plateau_gate_region": (
            "union of basic and full brightest 0.1% spatial masks, including ties"
        ),
        "highlight_plateau_gate": (
            "area flat in full but not basic within the shared region <= "
            f"{thresholds['new_shared_plateau_maximum_area']}"
        ),
        "mean_ev_source": "Gaussian-blurred linear-sRGB luminance",
        "mean_ev_reference_black_threshold": MEAN_EV_BLACK_THRESHOLD,
        "mean_ev_gate": (
            "abs(full drift) <= abs(basic drift) + "
            f"{thresholds['mean_ev_absolute_error_maximum_increase']} EV"
        ),
        "preview_parity_reference": (
            "same-stage full-resolution RAW decode followed by the manifest "
            "max-dimension scale"
        ),
        "preview_parity_candidate": (
            "same-stage interactive-preview RAW decode using CIRAWFilter.scaleFactor"
        ),
        "preview_parity_registration": (
            "exact output shape required; no analyzer-side resize or registration"
        ),
        "preview_parity_mean_delta_e_2000_maximum": preview_thresholds[
            "mean_delta_e_maximum"
        ],
        "preview_parity_mean_ev_absolute_drift_maximum": preview_thresholds[
            "mean_ev_absolute_drift_maximum"
        ],
    }
    if preview_schema_version == 2:
        methodology["preview_parity_new_shared_highlight_plateau_maximum_area"] = (
            preview_thresholds["new_shared_plateau_maximum_area"]
        )
        return methodology
    if preview_schema_version not in (3, 4):
        raise StructuralValidationError(
            f"methodologyのpreview schemaが未対応です: {preview_schema_version}"
        )
    tolerance = preview_spatial_tolerance or {}
    methodology.update(
        {
            "preview_parity_reference": (
                "same-stage full-resolution RAW decode followed by the common "
                "explicit high-quality downsample to the manifest output dimension"
            ),
            "preview_parity_candidate": (
                "same-stage CIRAWFilter.scaleFactor decode at each preregistered "
                "oversampled ceiling followed by the identical edit graph and "
                "high-quality downsample to the common output dimension"
            ),
            "preview_parity_resampler": "CILanczosScaleTransform with explicit crop",
            "preview_parity_blurred_delta_e_2000_p95_maximum": (
                preview_thresholds["delta_e_p95_maximum"]
            ),
            "preview_parity_plateau_metric": (
                "unblurred encoded-sRGB luma plateau; not simultaneous RGB plateau"
            ),
            "preview_parity_plateau_spatial_tolerance": {
                "radius_pixels": tolerance.get("radiusPixels"),
                "structuring_element": tolerance.get("structuringElement"),
                "distance": "Chebyshev",
                "raster": "common final-output raster",
            },
            "preview_parity_net_shared_highlight_plateau_area_increase_maximum": (
                preview_thresholds[
                    "net_shared_plateau_area_increase_maximum"
                ]
            ),
            "preview_parity_spatially_distinct_new_shared_highlight_plateau_maximum_area": (
                preview_thresholds[
                    "spatially_distinct_new_shared_plateau_maximum_area"
                ]
            ),
            "preview_parity_legacy_exact_coordinate_plateau_difference": (
                "diagnostic only; excluded from v3/v4 pass/fail"
            ),
            "preview_parity_plateau_localization_diagnostics": (
                "largest 8-connected component and densest 128x128 window, plus "
                "Chebyshev distance histogram; diagnostic only"
            ),
            "preview_parity_candidate_selection": (
                "select the smallest decode ceiling passing every scene/stage pair; "
                "otherwise retain the full-resolution RAW decode"
            ),
        }
    )
    if preview_schema_version == 4:
        canonical = _require_dict(
            canonical_settle_specification,
            "canonicalSettleGate",
        )
        canonical_thresholds = _require_dict(
            canonical.get("thresholds"),
            "canonicalSettleGate.thresholds",
        )
        methodology.update(
            {
                "canonical_settle_scope": (
                    "same-scene basic-legacy versus full-current, both reused from "
                    "the full-resolution RAW decode preview-parity artifacts on the "
                    "common final-output raster"
                ),
                "canonical_settle_pipeline": (
                    f"{canonical['workingColorSpace']} working edits -> "
                    f"{canonical['downsamplingFilter']} "
                    f"(inputAspectRatio={canonical['inputAspectRatio']}) -> "
                    "SDR output transform"
                ),
                "canonical_settle_output_transform_placement": canonical[
                    "outputTransformPlacement"
                ],
                "canonical_settle_output_maximum_dimension": canonical[
                    "outputMaxDimension"
                ],
                "canonical_settle_complete_clip_normalized_minimum": (
                    canonical_thresholds["completeClipNormalizedMinimum"]
                ),
                "canonical_settle_near_clip_normalized_minimum": (
                    canonical_thresholds["nearClipNormalizedMinimum"]
                ),
                "canonical_settle_complete_clip_maximum_pixel_count_increase": (
                    canonical_thresholds[
                        "completeClipMaximumPixelCountIncrease"
                    ]
                ),
                "canonical_settle_near_clip_maximum_pixel_count_increase": (
                    canonical_thresholds["nearClipMaximumPixelCountIncrease"]
                ),
                "canonical_settle_new_shared_highlight_plateau_maximum_area": (
                    canonical_thresholds["newSharedPlateauMaximumArea"]
                ),
                "canonical_settle_clip_measurement": (
                    "exact integer pixel counts on unblurred normalized 16-bit TIFF; "
                    "a pixel is clipped when any RGB channel meets the threshold"
                ),
            }
        )
    return methodology


def _artifact_path(root: Path, artifacts: dict[str, dict[str, Any]], relative: str) -> Path:
    if relative not in artifacts:
        raise StructuralValidationError(f"検証済みartifactにpathがありません: {relative}")
    return resolve_inside(root, relative)


def _candidate_path(
    root: Path, artifacts: dict[str, dict[str, Any]], scene_id: str, label: str
) -> Path:
    return _artifact_path(
        root,
        artifacts,
        f".photobench/calibration/renders/{scene_id}-{label}.tif",
    )


def _preview_parity_artifact_path(
    root: Path,
    artifacts: dict[str, dict[str, Any]],
    scene_id: str,
    stage_id: str,
    route_label: str,
) -> tuple[Path, dict[str, Any]]:
    relative = (
        f".photobench/calibration/renders/{scene_id}-preview-parity-"
        f"{stage_id}-{route_label}.tif"
    )
    return _artifact_path(root, artifacts, relative), artifacts[relative]


def _preview_parity_v3_artifact_path(
    root: Path,
    artifacts: dict[str, dict[str, Any]],
    scene_id: str,
    stage_id: str,
    *,
    output_dimension: int,
    candidate_decode_dimension: int | None,
) -> tuple[Path, dict[str, Any]]:
    route = (
        "full-decode"
        if candidate_decode_dimension is None
        else f"decode-{candidate_decode_dimension}"
    )
    relative = (
        f".photobench/calibration/renders/{scene_id}-preview-parity-"
        f"{stage_id}-{route}-to-{output_dimension}.tif"
    )
    return _artifact_path(root, artifacts, relative), artifacts[relative]


def analyze_preview_parity(
    root: Path,
    artifacts: dict[str, dict[str, Any]],
    manifest: dict[str, Any],
) -> dict[str, dict[str, dict[str, Any]]]:
    specification = manifest["previewParity"]
    if manifest["schemaVersion"] >= 3:
        return analyze_preview_parity_v3(root, artifacts, manifest)

    max_dimension = specification["maxDimension"]
    result: dict[str, dict[str, dict[str, Any]]] = {}
    for scene in manifest["scenes"]:
        scene_id = scene["id"]
        expected_longest = min(
            max_dimension,
            max(scene["capture"]["width"], scene["capture"]["height"]),
        )
        stages: dict[str, dict[str, Any]] = {}
        expected_shape: tuple[int, int] | None = None
        for stage_id in specification["settingsStageIDs"]:
            reference_path, reference_artifact = _preview_parity_artifact_path(
                root,
                artifacts,
                scene_id,
                stage_id,
                PREVIEW_PARITY_ROUTE_LABELS["full-resolution"],
            )
            candidate_path, candidate_artifact = _preview_parity_artifact_path(
                root,
                artifacts,
                scene_id,
                stage_id,
                PREVIEW_PARITY_ROUTE_LABELS["interactive-preview"],
            )
            if (
                reference_artifact["settingsSHA256"]
                != candidate_artifact["settingsSHA256"]
                or reference_artifact["settings"] != candidate_artifact["settings"]
            ):
                raise StructuralValidationError(
                    f"preview parity settings不一致: {scene_id}/{stage_id}"
                )
            reference = read_srgb(reference_path)
            candidate = read_srgb(candidate_path)
            if reference.shape != candidate.shape:
                raise StructuralValidationError(
                    f"preview parity画像のshapeが一致しません: {scene_id}/{stage_id} "
                    f"reference={reference.shape} candidate={candidate.shape}"
                )
            shape = reference.shape[:2]
            if abs(max(shape) - expected_longest) > 1:
                raise StructuralValidationError(
                    f"preview parity画像の最大辺がmanifestと一致しません: "
                    f"{scene_id}/{stage_id} shape={shape} expected={expected_longest}"
                )
            if expected_shape is not None and shape != expected_shape:
                raise StructuralValidationError(
                    f"preview parity stage間のshapeが一致しません: "
                    f"{scene_id}/{stage_id} expected={expected_shape} actual={shape}"
                )
            expected_shape = shape
            stages[stage_id] = {
                "reference": {
                    "decode_intent": specification["baselineDecodeIntent"],
                    "path": reference_artifact["path"],
                    "sha256": reference_artifact["sha256"],
                    "width": reference_artifact["width"],
                    "height": reference_artifact["height"],
                    "settings_sha256": reference_artifact["settingsSHA256"],
                },
                "candidate": {
                    "decode_intent": specification["candidateDecodeIntent"],
                    "path": candidate_artifact["path"],
                    "sha256": candidate_artifact["sha256"],
                    "width": candidate_artifact["width"],
                    "height": candidate_artifact["height"],
                    "settings_sha256": candidate_artifact["settingsSHA256"],
                },
                "metrics": preview_parity_metrics(reference, candidate),
            }
        result[scene_id] = stages
    return result


def analyze_preview_parity_v3(
    root: Path,
    artifacts: dict[str, dict[str, Any]],
    manifest: dict[str, Any],
) -> dict[str, dict[str, dict[str, dict[str, Any]]]]:
    specification = manifest["previewParity"]
    output_dimension = specification["outputMaxDimension"]
    tolerance_pixels = specification["plateauSpatialTolerance"]["radiusPixels"]
    result: dict[str, dict[str, dict[str, dict[str, Any]]]] = {}
    for scene in manifest["scenes"]:
        scene_id = scene["id"]
        expected_longest = min(
            output_dimension,
            max(scene["capture"]["width"], scene["capture"]["height"]),
        )
        candidates: dict[str, dict[str, dict[str, Any]]] = {}
        expected_shape: tuple[int, int] | None = None
        for decode_dimension in specification[
            "candidateDecodeMaximumDimensions"
        ]:
            stages: dict[str, dict[str, Any]] = {}
            for stage_id in specification["settingsStageIDs"]:
                reference_path, reference_artifact = (
                    _preview_parity_v3_artifact_path(
                        root,
                        artifacts,
                        scene_id,
                        stage_id,
                        output_dimension=output_dimension,
                        candidate_decode_dimension=None,
                    )
                )
                candidate_path, candidate_artifact = (
                    _preview_parity_v3_artifact_path(
                        root,
                        artifacts,
                        scene_id,
                        stage_id,
                        output_dimension=output_dimension,
                        candidate_decode_dimension=decode_dimension,
                    )
                )
                if (
                    reference_artifact["settingsSHA256"]
                    != candidate_artifact["settingsSHA256"]
                    or reference_artifact["settings"]
                    != candidate_artifact["settings"]
                ):
                    raise StructuralValidationError(
                        "preview parity v3 settings不一致: "
                        f"{scene_id}/{decode_dimension}/{stage_id}"
                    )
                reference = read_srgb(reference_path)
                candidate = read_srgb(candidate_path)
                if reference.shape != candidate.shape:
                    raise StructuralValidationError(
                        "preview parity v3画像のshapeが一致しません: "
                        f"{scene_id}/{decode_dimension}/{stage_id} "
                        f"reference={reference.shape} candidate={candidate.shape}"
                    )
                shape = reference.shape[:2]
                if abs(max(shape) - expected_longest) > 1:
                    raise StructuralValidationError(
                        "preview parity v3画像の最大辺がmanifestと一致しません: "
                        f"{scene_id}/{decode_dimension}/{stage_id} "
                        f"shape={shape} expected={expected_longest}"
                    )
                if expected_shape is not None and shape != expected_shape:
                    raise StructuralValidationError(
                        "preview parity v3 route/stage間のshapeが一致しません: "
                        f"{scene_id}/{decode_dimension}/{stage_id} "
                        f"expected={expected_shape} actual={shape}"
                    )
                expected_shape = shape
                stages[stage_id] = {
                    "reference": {
                        "decode_intent": specification["baselineDecodeIntent"],
                        "decode_maximum_dimension": None,
                        "output_maximum_dimension": output_dimension,
                        "path": reference_artifact["path"],
                        "sha256": reference_artifact["sha256"],
                        "width": reference_artifact["width"],
                        "height": reference_artifact["height"],
                        "settings_sha256": reference_artifact["settingsSHA256"],
                    },
                    "candidate": {
                        "decode_intent": specification["candidateDecodeIntent"],
                        "decode_maximum_dimension": decode_dimension,
                        "output_maximum_dimension": output_dimension,
                        "path": candidate_artifact["path"],
                        "sha256": candidate_artifact["sha256"],
                        "width": candidate_artifact["width"],
                        "height": candidate_artifact["height"],
                        "settings_sha256": candidate_artifact["settingsSHA256"],
                    },
                    "metrics": preview_parity_v3_metrics(
                        reference,
                        candidate,
                        tolerance_pixels=tolerance_pixels,
                    ),
                }
            candidates[str(decode_dimension)] = stages
        result[scene_id] = candidates
    return result


def analyze_canonical_settle(
    root: Path,
    artifacts: dict[str, dict[str, Any]],
    manifest: dict[str, Any],
) -> dict[str, dict[str, Any]]:
    """Compare basic/full stages on v4's full-decode canonical 2560 raster."""
    if manifest["schemaVersion"] != 4:
        return {}
    specification = manifest["canonicalSettleGate"]
    preview_specification = manifest["previewParity"]
    output_dimension = specification["outputMaxDimension"]
    baseline_stage_id = specification["baselineStageID"]
    candidate_stage_id = specification["candidateStageID"]
    thresholds = specification["thresholds"]
    result: dict[str, dict[str, Any]] = {}
    for scene in manifest["scenes"]:
        scene_id = scene["id"]
        baseline_path, baseline_artifact = _preview_parity_v3_artifact_path(
            root,
            artifacts,
            scene_id,
            baseline_stage_id,
            output_dimension=output_dimension,
            candidate_decode_dimension=None,
        )
        candidate_path, candidate_artifact = _preview_parity_v3_artifact_path(
            root,
            artifacts,
            scene_id,
            candidate_stage_id,
            output_dimension=output_dimension,
            candidate_decode_dimension=None,
        )

        # Each selected full-decode stage must carry the same settings as every
        # corresponding preview-parity route. This binds the reused artifact to
        # its preregistered stage without requiring an analyzer-side rerender.
        for stage_id, full_artifact in (
            (baseline_stage_id, baseline_artifact),
            (candidate_stage_id, candidate_artifact),
        ):
            for decode_dimension in preview_specification[
                "candidateDecodeMaximumDimensions"
            ]:
                _, witness_artifact = _preview_parity_v3_artifact_path(
                    root,
                    artifacts,
                    scene_id,
                    stage_id,
                    output_dimension=output_dimension,
                    candidate_decode_dimension=decode_dimension,
                )
                if (
                    full_artifact["settingsSHA256"]
                    != witness_artifact["settingsSHA256"]
                    or full_artifact["settings"] != witness_artifact["settings"]
                ):
                    raise StructuralValidationError(
                        "canonical settle settings不一致: "
                        f"{scene_id}/{stage_id}/{decode_dimension}"
                    )

        baseline = read_srgb(baseline_path)
        candidate = read_srgb(candidate_path)
        if baseline.shape != candidate.shape:
            raise StructuralValidationError(
                "canonical settle画像のshapeが一致しません: "
                f"{scene_id} baseline={baseline.shape} candidate={candidate.shape}"
            )
        expected_longest = min(
            output_dimension,
            max(scene["capture"]["width"], scene["capture"]["height"]),
        )
        if abs(max(baseline.shape[:2]) - expected_longest) > 1:
            raise StructuralValidationError(
                "canonical settle画像の最大辺がmanifestと一致しません: "
                f"{scene_id} shape={baseline.shape[:2]} expected={expected_longest}"
            )
        result[scene_id] = {
            "contract": {
                "output_maximum_dimension": output_dimension,
                "downsampling_filter": specification["downsamplingFilter"],
                "input_aspect_ratio": specification["inputAspectRatio"],
                "working_color_space": specification["workingColorSpace"],
                "output_transform_placement": specification[
                    "outputTransformPlacement"
                ],
            },
            "baseline": {
                "stage_id": baseline_stage_id,
                "path": baseline_artifact["path"],
                "sha256": baseline_artifact["sha256"],
                "width": baseline_artifact["width"],
                "height": baseline_artifact["height"],
                "settings_sha256": baseline_artifact["settingsSHA256"],
            },
            "candidate": {
                "stage_id": candidate_stage_id,
                "path": candidate_artifact["path"],
                "sha256": candidate_artifact["sha256"],
                "width": candidate_artifact["width"],
                "height": candidate_artifact["height"],
                "settings_sha256": candidate_artifact["settingsSHA256"],
            },
            "metrics": canonical_settle_metrics(
                baseline,
                candidate,
                thresholds=thresholds,
            ),
        }
    return result


def _metric_delta(metrics: dict[str, float], baseline: dict[str, float]) -> dict[str, float]:
    return {
        key: round(value - baseline[key], 5)
        for key, value in metrics.items()
        if key in baseline
    }


def _distribution(values: list[float]) -> dict[str, Any]:
    if not values or any(not math.isfinite(value) or value < 0 for value in values):
        raise StructuralValidationError("performance sampleが空または不正です")
    ordered = sorted(values)
    return {
        "count": len(ordered),
        "minimum": round(ordered[0], 3),
        "median": round(float(np.percentile(ordered, 50)), 3),
        "p95": round(float(np.percentile(ordered, 95)), 3),
        "maximum": round(ordered[-1], 3),
        "mean": round(float(np.mean(ordered)), 3),
    }


def analyze_calibration(
    root: Path, manifest_path: Path | None = None
) -> dict[str, Any]:
    root = root.resolve()
    selected_manifest = (manifest_path or (root / DEFAULT_MANIFEST_PATH)).resolve()
    try:
        manifest_relative = selected_manifest.relative_to(root).as_posix()
    except ValueError as error:
        raise StructuralValidationError("manifestはproject root内に置く必要があります") from error
    manifest = load_json(selected_manifest)
    validate_manifest(manifest, root)
    manifest_hash = sha256_file(selected_manifest)
    run_path = resolve_inside(root, DEFAULT_RUN_MANIFEST_PATH)
    run = load_json(run_path)
    validation = validate_run_manifest(
        run, manifest, root, manifest_relative, manifest_hash
    )
    artifacts = validation.pop("artifact_map")

    quality_gate = manifest["qualityGate"]
    thresholds = {
        "mean_delta_e_maximum_increase": float(quality_gate["meanDeltaEMaximumIncrease"]),
        "mean_ev_absolute_error_maximum_increase": float(
            quality_gate["meanEVAbsoluteErrorMaximumIncrease"]
        ),
        "new_shared_plateau_maximum_area": float(
            quality_gate["newSharedPlateauMaximumArea"]
        ),
    }
    routes = {
        route["id"].replace("-", "_"): (route["basicLabel"], route["fullLabel"])
        for route in quality_gate["routes"]
    }
    preview_parity = manifest["previewParity"]
    if manifest["schemaVersion"] == 2:
        preview_thresholds = {
            "mean_delta_e_maximum": float(
                preview_parity["thresholds"]["meanDeltaEMaximum"]
            ),
            "mean_ev_absolute_drift_maximum": float(
                preview_parity["thresholds"]["meanEVAbsoluteDriftMaximum"]
            ),
            "new_shared_plateau_maximum_area": float(
                preview_parity["thresholds"]["newSharedPlateauMaximumArea"]
            ),
        }
    else:
        preview_thresholds = {
            "mean_delta_e_maximum": float(
                preview_parity["thresholds"]["meanDeltaEMaximum"]
            ),
            "delta_e_p95_maximum": float(
                preview_parity["thresholds"]["blurredDeltaE2000P95Maximum"]
            ),
            "mean_ev_absolute_drift_maximum": float(
                preview_parity["thresholds"]["meanEVAbsoluteDriftMaximum"]
            ),
            "net_shared_plateau_area_increase_maximum": float(
                preview_parity["thresholds"][
                    "netSharedPlateauAreaIncreaseMaximum"
                ]
            ),
            "spatially_distinct_new_shared_plateau_maximum_area": float(
                preview_parity["thresholds"][
                    "spatiallyDistinctNewSharedPlateauMaximumArea"
                ]
            ),
        }
    scene_ids = tuple(scene["id"] for scene in manifest["scenes"])
    report: dict[str, Any] = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "validation": {
            "status": "passed",
            "manifest_schema_version": manifest["schemaVersion"],
            "run_schema_version": run["schemaVersion"],
            **validation,
        },
        "methodology": _methodology(
            thresholds,
            preview_thresholds,
            preview_schema_version=manifest["schemaVersion"],
            preview_spatial_tolerance=preview_parity.get(
                "plateauSpatialTolerance"
            ),
            canonical_settle_specification=manifest.get("canonicalSettleGate"),
        ),
        "raw_baseline": {},
        "preset": {},
        "stage_matrix": {},
        "edr_diagnostics": {},
        "preview_parity": {},
        "canonical_settle": {},
        "runtime": run["runtime"],
        "provenance": {
            "suite_id": manifest["suiteID"],
            "suite_description": manifest["description"],
            "run_id": run["runID"],
            "started_at_utc": run["startedAtUTC"],
            "completed_at_utc": run["completedAtUTC"],
            "manifest": run["manifest"],
            "processing": run["processing"],
            "source_fingerprint_sha256": run["sourceFingerprintSHA256"],
            "scene_folds": {
                scene["id"]: {
                    "scene_group": scene["sceneGroup"],
                    "fold": scene["fold"],
                    "lighting": scene["lighting"],
                }
                for scene in manifest["scenes"]
            },
            "verified_inputs": run["verifiedInputs"],
            "postflight_verified_inputs": run["postflightVerifiedInputs"],
            "decodes": run["decodes"],
        },
    }

    legacy_labels = [
        label
        for candidate in manifest["legacyCandidates"]
        for label in (candidate["rawLabel"], candidate["lightroomInputLabel"])
    ]
    for scene in manifest["scenes"]:
        scene_id = scene["id"]
        before_path = _artifact_path(
            root,
            artifacts,
            f".photobench/calibration/references/{scene_id}-lightroom-before.tif",
        )
        after_path = _artifact_path(
            root,
            artifacts,
            f".photobench/calibration/references/{scene_id}-lightroom-after.tif",
        )
        before = read_srgb(before_path)
        after = read_srgb(after_path)

        boost_candidates: dict[str, dict[str, float]] = {}
        for amount in manifest["diagnostics"]["boostAmounts"]:
            label = _three_digit_label(float(amount))
            boost_candidates[label] = summarize(
                before, read_srgb(_candidate_path(root, artifacts, scene_id, f"boost-{label}"))
            )
        report["raw_baseline"][scene_id] = boost_candidates

        preset_candidates: dict[str, dict[str, float]] = {}
        gate_images: dict[str, np.ndarray] = {}
        gate_labels = {label for labels in routes.values() for label in labels}
        for label in legacy_labels:
            image = read_srgb(_candidate_path(root, artifacts, scene_id, label))
            preset_candidates[label] = summarize(after, image)
            if label in gate_labels:
                gate_images[label] = image
        for basic_label, full_label in routes.values():
            basic_plateau, full_plateau, new_plateau = shared_highlight_plateau_fractions(
                gate_images[basic_label], gate_images[full_label]
            )
            preset_candidates[basic_label][
                "shared_highlight_plateau_fraction"
            ] = basic_plateau
            preset_candidates[full_label][
                "shared_highlight_plateau_fraction"
            ] = full_plateau
            preset_candidates[full_label][
                "new_shared_highlight_plateau_fraction"
            ] = new_plateau
        report["preset"][scene_id] = preset_candidates

        scene_matrix: dict[str, Any] = {
            "interpretation": (
                "Each row is an independently rendered cumulative/isolation stage. "
                "effect_vs_tone_base is a pairwise diagnostic and must not be summed "
                "or interpreted as an additive stage contribution."
            )
        }
        for route_key, label_field in (
            ("raw", "rawLabel"),
            ("lr_input", "lightroomInputLabel"),
        ):
            tone_definition = next(
                definition for definition in manifest["stageMatrix"]
                if definition["id"] == "tone-base"
            )
            tone_label = tone_definition[label_field]
            tone_image = read_srgb(_candidate_path(root, artifacts, scene_id, tone_label))
            tone_metrics = summarize(after, tone_image)
            stages: dict[str, Any] = {}
            for definition in manifest["stageMatrix"]:
                label = definition[label_field]
                image = tone_image if definition["id"] == "tone-base" else read_srgb(
                    _candidate_path(root, artifacts, scene_id, label)
                )
                metrics = tone_metrics if definition["id"] == "tone-base" else summarize(after, image)
                stages[definition["id"]] = {
                    "label": label,
                    "metrics_vs_lightroom_after": metrics,
                    "effect_vs_tone_base": {
                        "interpretation": "pairwise non-additive diagnostic",
                        "direct_image_difference": summarize(tone_image, image),
                        "metric_delta_vs_reference": _metric_delta(metrics, tone_metrics),
                    },
                }
            scene_matrix[route_key] = {
                "tone_base_stage_id": "tone-base",
                "stages": stages,
            }
        report["stage_matrix"][scene_id] = scene_matrix

        headroom_by_amount = {
            float(record["amount"]): record
            for record in run["edrHeadroom"]
            if record["sceneID"] == scene_id
        }
        edr_scene: dict[str, Any] = {}
        for amount in manifest["diagnostics"]["extendedDynamicRangeAmounts"]:
            numeric_amount = float(amount)
            amount_label = _three_digit_label(numeric_amount)
            candidates: dict[str, Any] = {}
            for candidate_id, label, reference in (
                ("neutral", f"edr-{amount_label}", before),
                ("basic-legacy", f"xmp-basic-edr-{amount_label}", after),
                ("full-current", f"xmp-full-edr-{amount_label}", after),
            ):
                candidates[candidate_id] = {
                    "label": label,
                    "metrics": summarize(
                        reference,
                        read_srgb(_candidate_path(root, artifacts, scene_id, label)),
                    ),
                    "reference": (
                        "lightroom-before" if candidate_id == "neutral" else "lightroom-after"
                    ),
                }
            edr_scene[amount_label] = {
                "amount": numeric_amount,
                "raw_linear_headroom": headroom_by_amount[numeric_amount],
                "encoded_tiff_candidates": candidates,
            }
        report["edr_diagnostics"][scene_id] = edr_scene

    report["quality_gates"] = evaluate_quality_gates(
        report["preset"],
        stems=scene_ids,
        routes=routes,
        thresholds=thresholds,
    )
    report["preview_parity"] = analyze_preview_parity(
        root, artifacts, manifest
    )
    if manifest["schemaVersion"] == 2:
        report["preview_parity_gates"] = evaluate_preview_parity_gates(
            report["preview_parity"],
            scene_ids=scene_ids,
            stage_ids=tuple(preview_parity["settingsStageIDs"]),
            thresholds=preview_thresholds,
        )
    else:
        report["preview_parity_gates"] = evaluate_preview_parity_v3_gates(
            report["preview_parity"],
            scene_ids=scene_ids,
            candidate_dimensions=tuple(
                preview_parity["candidateDecodeMaximumDimensions"]
            ),
            stage_ids=tuple(preview_parity["settingsStageIDs"]),
            thresholds=preview_thresholds,
            tolerance_pixels=preview_parity["plateauSpatialTolerance"][
                "radiusPixels"
            ],
        )
    if manifest["schemaVersion"] == 4:
        canonical_settle = manifest["canonicalSettleGate"]
        report["canonical_settle"] = analyze_canonical_settle(
            root,
            artifacts,
            manifest,
        )
        report["canonical_settle_gates"] = evaluate_canonical_settle_gates(
            report["canonical_settle"],
            scene_ids=scene_ids,
            thresholds=canonical_settle["thresholds"],
        )
        report["canonical_settle_gates"]["applicable"] = True
    else:
        report["canonical_settle_gates"] = {
            "applicable": False,
            "passed": True,
            "scenes": {},
            "not_evaluated_reason": "manifest schema v4 only",
        }
    render_times = [float(artifact["renderAndEncodeMilliseconds"]) for artifact in run["artifacts"]]
    performance_by_group: dict[str, Any] = {}
    for group in sorted({artifact.get("candidateGroup") or artifact["role"] for artifact in run["artifacts"]}):
        values = [
            float(artifact["renderAndEncodeMilliseconds"])
            for artifact in run["artifacts"]
            if (artifact.get("candidateGroup") or artifact["role"]) == group
        ]
        performance_by_group[group] = _distribution(values)
    report["performance_telemetry"] = {
        "scope": (
            "Calibration render-and-encode wall-clock telemetry; diagnostic only, "
            "not the release benchmark gate."
        ),
        "all_artifacts_milliseconds": _distribution(render_times),
        "by_candidate_group_milliseconds": performance_by_group,
        "decoder_graph_setup_milliseconds": {
            f"{decode['sceneID']}:{decode['route']}": decode["decoderGraphSetupMilliseconds"]
            for decode in run["decodes"]
        },
        "release_benchmark": (
            "Not consumed by this analyzer; use .photobench/benchmark/latest.json "
            "from PhotoBenchBenchmark for performance gates."
        ),
    }
    return report


def atomic_write_json(path: Path, value: dict[str, Any]) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        indent=2,
        allow_nan=False,
        sort_keys=False,
    ) + "\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
    return encoded.rstrip("\n")


def _failure_report(message: str) -> dict[str, Any]:
    return {
        "schema_version": REPORT_SCHEMA_VERSION,
        "validation": {"status": "failed", "errors": [message]},
        "methodology": _methodology(DEFAULT_GATE_THRESHOLDS),
        "raw_baseline": {},
        "preset": {},
        "preview_parity": {},
        "canonical_settle": {},
        "quality_gates": {
            "passed": False,
            "all_expected_candidates_present": False,
            "missing_candidates": [],
            "scenes": {},
            "not_evaluated_reason": "structural validation failed",
        },
        "preview_parity_gates": {
            "passed": False,
            "scenes": {},
            "not_evaluated_reason": "structural validation failed",
        },
        "canonical_settle_gates": {
            "applicable": False,
            "passed": False,
            "scenes": {},
            "not_evaluated_reason": "structural validation failed",
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument(
        "--enforce",
        action="store_true",
        help="品質ゲート不合格時に非0で終了する（構造検証失敗は常にexit 2）",
    )
    parser.add_argument(
        "--enforce-preview-parity",
        action="store_true",
        help=(
            "preview parity gate不合格時にexit 1で終了する"
            "（構造検証失敗は常にexit 2）"
        ),
    )
    parser.add_argument(
        "--enforce-canonical-settle",
        action="store_true",
        help=(
            "schema v4 canonical settle gate不合格時にexit 1で終了する"
            "（構造検証失敗は常にexit 2）"
        ),
    )
    args = parser.parse_args(argv)
    root = args.root.resolve()
    report_path = root / ".photobench" / "calibration" / "report.json"
    manifest_path = args.manifest
    if manifest_path is not None and not manifest_path.is_absolute():
        manifest_path = root / manifest_path
    try:
        report = analyze_calibration(root, manifest_path)
        encoded = atomic_write_json(report_path, report)
    except Exception as error:
        failure = _failure_report(str(error))
        try:
            atomic_write_json(report_path, failure)
        except OSError as write_error:
            print(f"Validation FAILED; report保存にも失敗しました: {write_error}", file=sys.stderr)
        print(f"Validation FAILED: {error}", file=sys.stderr)
        return 2

    print(encoded)
    print(f"Saved: {report_path}")
    quality_passed = report["quality_gates"]["passed"]
    preview_parity_passed = report["preview_parity_gates"]["passed"]
    canonical_settle_gate = report.get(
        "canonical_settle_gates",
        {"applicable": False, "passed": True},
    )
    canonical_settle_passed = canonical_settle_gate["passed"]
    print(
        f"Quality gates: {'PASSED' if quality_passed else 'FAILED'}",
        file=sys.stdout if quality_passed else sys.stderr,
    )
    print(
        "Preview parity gates: "
        + ("PASSED" if preview_parity_passed else "FAILED"),
        file=sys.stdout if preview_parity_passed else sys.stderr,
    )
    if canonical_settle_gate.get("applicable", False):
        print(
            "Canonical settle gates: "
            + ("PASSED" if canonical_settle_passed else "FAILED"),
            file=sys.stdout if canonical_settle_passed else sys.stderr,
        )
    enforced_failure = (
        (args.enforce and not quality_passed)
        or (args.enforce_preview_parity and not preview_parity_passed)
        or (args.enforce_canonical_settle and not canonical_settle_passed)
    )
    return 1 if enforced_failure else 0


if __name__ == "__main__":
    raise SystemExit(main())
