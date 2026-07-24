#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

import cv2
import numpy as np
from PIL import Image, ImageCms


MODULE_PATH = Path(__file__).with_name("analyze-calibration.py")
SPEC = importlib.util.spec_from_file_location("photo_bench_calibration_analysis", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"分析モジュールを読み込めません: {MODULE_PATH}")
ANALYSIS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYSIS)


TEST_SRGB_ICC_PROFILE = ImageCms.ImageCmsProfile(
    ImageCms.createProfile("sRGB")
).tobytes()


def write_srgb_tiff(path: Path, image: np.ndarray) -> None:
    """Write a tiny uncompressed 16-bit RGB TIFF with an embedded sRGB ICC."""
    if image.dtype != np.uint16 or image.ndim != 3 or image.shape[2] != 3:
        raise ValueError("test TIFF must be uint16 RGB")
    height, width, _ = image.shape
    entry_count = 11
    ifd_offset = 8
    ifd_size = 2 + entry_count * 12 + 4
    bits_offset = ifd_offset + ifd_size
    icc_offset = (bits_offset + 6 + 1) & ~1
    pixel_offset = (icc_offset + len(TEST_SRGB_ICC_PROFILE) + 1) & ~1
    byte_count = width * height * 3 * 2
    entries = [
        (256, 4, 1, width),
        (257, 4, 1, height),
        (258, 3, 3, bits_offset),
        (259, 3, 1, 1),
        (262, 3, 1, 2),
        (273, 4, 1, pixel_offset),
        (277, 3, 1, 3),
        (278, 4, 1, height),
        (279, 4, 1, byte_count),
        (284, 3, 1, 1),
        (34675, 7, len(TEST_SRGB_ICC_PROFILE), icc_offset),
    ]
    encoded = bytearray(b"II" + struct.pack("<HI", 42, ifd_offset))
    encoded += struct.pack("<H", entry_count)
    for tag, field_type, count, value in entries:
        encoded += struct.pack("<HHI", tag, field_type, count)
        encoded += (
            struct.pack("<H", value) + b"\0\0"
            if field_type == 3 and count == 1
            else struct.pack("<I", value)
        )
    encoded += struct.pack("<I", 0)
    encoded += struct.pack("<HHH", 16, 16, 16)
    encoded += b"\0" * (icc_offset - len(encoded))
    encoded += TEST_SRGB_ICC_PROFILE
    encoded += b"\0" * (pixel_offset - len(encoded))
    encoded += image.astype("<u2", copy=False).tobytes()
    path.write_bytes(encoded)


class CalibrationAnalysisTests(unittest.TestCase):
    def test_delta_e_2000_matches_sharma_reference_vectors(self) -> None:
        # Sharma, Wu, and Dalal (2005) supplementary CIEDE2000 test data.
        lab1 = np.array(
            [
                [50.0000, 2.6772, -79.7751],
                [50.0000, 3.1571, -77.2803],
                [50.0000, 2.8361, -74.0200],
                [50.0000, -1.3802, -84.2814],
                [50.0000, -1.1848, -84.8006],
                [50.0000, -0.9009, -85.5211],
                [50.0000, 0.0000, 0.0000],
            ],
            dtype=np.float64,
        )
        lab2 = np.array(
            [
                [50.0000, 0.0000, -82.7485],
                [50.0000, 0.0000, -82.7485],
                [50.0000, 0.0000, -82.7485],
                [50.0000, 0.0000, -82.7485],
                [50.0000, 0.0000, -82.7485],
                [50.0000, 0.0000, -82.7485],
                [50.0000, -1.0000, 2.0000],
            ],
            dtype=np.float64,
        )
        expected = np.array(
            [2.0425, 2.8615, 3.4412, 1.0000, 1.0000, 1.0000, 2.3669],
            dtype=np.float64,
        )

        actual = ANALYSIS.delta_e_2000(lab1, lab2)

        np.testing.assert_allclose(actual, expected, rtol=0, atol=5e-4)

    def test_clip_fraction_uses_unblurred_pixels(self) -> None:
        reference = np.full((4, 4, 3), 0.5, dtype=np.float32)
        candidate = reference.copy()
        candidate[1, 1, 0] = 1.0

        result = ANALYSIS.summarize(reference, candidate)

        self.assertEqual(result["reference_complete_clip_fraction"], 0.0)
        self.assertEqual(result["candidate_complete_clip_fraction"], 1 / 16)
        self.assertEqual(result["candidate_near_clip_fraction"], 1 / 16)

    def test_highlight_plateau_measures_a_broad_flat_region_as_image_area(self) -> None:
        ramp = np.linspace(0.1, 0.8, 10_000, dtype=np.float32).reshape(100, 100)
        image = np.repeat(ramp[..., None], 3, axis=2)
        image[10:30, 10:30, :] = 1.0

        self.assertAlmostEqual(ANALYSIS.highlight_plateau_fraction(image), 0.04)

    def test_highlight_plateau_denominator_is_every_image_pixel(self) -> None:
        ramp = np.linspace(0.1, 0.8, 10_000, dtype=np.float32).reshape(100, 100)
        image = np.repeat(ramp[..., None], 3, axis=2)
        image[10:12, 10:12, :] = 1.0

        self.assertAlmostEqual(ANALYSIS.highlight_plateau_fraction(image), 4 / 10_000)

    def test_highlight_plateau_rejects_a_smooth_bright_ramp(self) -> None:
        ramp = np.linspace(0.1, 0.999, 10_000, dtype=np.float32).reshape(100, 100)
        image = np.repeat(ramp[..., None], 3, axis=2)

        self.assertEqual(ANALYSIS.highlight_plateau_fraction(image), 0.0)

    def test_shared_plateau_gate_does_not_blame_full_for_an_inherited_shelf(self) -> None:
        ramp = np.linspace(0.1, 0.9, 10_000, dtype=np.float32).reshape(100, 100)
        basic = np.repeat(ramp[..., None], 3, axis=2)
        basic[10:30, 10:30, :] = 0.7
        full = basic.copy()
        full[10:30, 10:30, :] = 0.98

        # The shelf enters full's own top percentile, but it was already flat
        # at exactly the same pixels before the full stage.
        self.assertEqual(ANALYSIS.highlight_plateau_fraction(basic), 0.0)
        self.assertAlmostEqual(ANALYSIS.highlight_plateau_fraction(full), 0.04)
        basic_fraction, full_fraction, new_fraction = (
            ANALYSIS.shared_highlight_plateau_fractions(basic, full)
        )
        self.assertAlmostEqual(basic_fraction, 0.04)
        self.assertAlmostEqual(full_fraction, 0.04)
        self.assertEqual(new_fraction, 0.0)

    def test_shared_plateau_gate_detects_detail_collapsed_by_full(self) -> None:
        ramp = np.linspace(0.1, 0.9, 10_000, dtype=np.float32).reshape(100, 100)
        basic = np.repeat(ramp[..., None], 3, axis=2)
        full = basic.copy()
        full[10:30, 10:30, :] = 0.98

        basic_fraction, full_fraction, new_fraction = (
            ANALYSIS.shared_highlight_plateau_fractions(basic, full)
        )
        self.assertEqual(basic_fraction, 0.0)
        self.assertAlmostEqual(full_fraction, 0.04)
        self.assertAlmostEqual(new_fraction, 0.04)

    @staticmethod
    def plateau_fixture(
        *regions: tuple[slice, slice],
    ) -> np.ndarray:
        ramp = np.linspace(0.1, 0.9, 10_000, dtype=np.float32).reshape(100, 100)
        image = np.repeat(ramp[..., None], 3, axis=2)
        for rows, columns in regions:
            image[rows, columns, :] = 0.98
        return image

    def test_square_dilation_includes_diagonal_one_pixel_neighbours(self) -> None:
        mask = np.zeros((5, 5), dtype=bool)
        mask[2, 2] = True

        dilated = ANALYSIS._dilate_binary_mask(mask, 1)

        self.assertEqual(np.count_nonzero(dilated), 9)
        self.assertTrue(dilated[1, 1])
        self.assertTrue(dilated[3, 3])
        self.assertFalse(dilated[0, 0])

    def test_maximum_density_window_locates_the_cluster_without_gating_it(self) -> None:
        mask = np.zeros((10, 12), dtype=bool)
        mask[6:9, 8:11] = True

        result = ANALYSIS._maximum_true_density_window(
            mask, window_size_pixels=4
        )

        self.assertEqual(result["maximum_pixel_count"], 9)
        self.assertEqual(result["maximum_window_density"], 9 / 16)
        bbox = result["bbox"]
        self.assertLessEqual(bbox["x"], 8)
        self.assertLessEqual(bbox["y"], 6)
        self.assertGreaterEqual(bbox["x"] + bbox["width"], 11)
        self.assertGreaterEqual(bbox["y"] + bbox["height"], 9)

    def test_spatial_plateau_metrics_allow_one_pixel_boundary_shift(self) -> None:
        reference = self.plateau_fixture((slice(10, 30), slice(10, 30)))
        candidate = self.plateau_fixture((slice(11, 31), slice(11, 31)))

        metrics = ANALYSIS.shared_highlight_plateau_spatial_metrics(
            reference, candidate, tolerance_pixels=1
        )

        self.assertGreater(
            metrics["legacy_new_shared_highlight_plateau_fraction"], 0
        )
        self.assertAlmostEqual(
            metrics["shared_highlight_plateau_area_fraction_change"], 0
        )
        self.assertEqual(
            metrics["candidate_plateau_outside_reference_dilation_fraction"], 0
        )

    def test_spatial_plateau_metrics_reject_two_pixel_expansion(self) -> None:
        reference = self.plateau_fixture((slice(10, 30), slice(10, 30)))
        candidate = self.plateau_fixture((slice(8, 32), slice(8, 32)))

        metrics = ANALYSIS.shared_highlight_plateau_spatial_metrics(
            reference, candidate, tolerance_pixels=1
        )

        self.assertGreater(
            metrics["shared_highlight_plateau_area_fraction_change"], 0.0001
        )
        self.assertGreater(
            metrics["candidate_plateau_outside_reference_dilation_fraction"],
            0.0001,
        )
        self.assertGreaterEqual(
            metrics[
                "candidate_plateau_outside_reference_dilation_largest_component_fraction"
            ],
            0.0001,
        )
        self.assertIsNotNone(
            metrics[
                "candidate_plateau_outside_reference_dilation_largest_component_bbox"
            ]
        )
        histogram = metrics[
            "candidate_plateau_outside_reference_dilation_distance_histogram_pixels"
        ]
        outside_pixel_count = round(
            metrics["candidate_plateau_outside_reference_dilation_fraction"]
            * reference.shape[0]
            * reference.shape[1]
        )
        self.assertEqual(sum(histogram.values()), outside_pixel_count)
        self.assertGreater(histogram["distance-2"], 0)

    def test_spatial_plateau_metrics_reject_isolated_new_plateau(self) -> None:
        reference = self.plateau_fixture((slice(10, 30), slice(10, 30)))
        candidate = self.plateau_fixture(
            (slice(10, 30), slice(10, 30)),
            (slice(60, 70), slice(60, 70)),
        )

        metrics = ANALYSIS.shared_highlight_plateau_spatial_metrics(
            reference, candidate, tolerance_pixels=1
        )

        self.assertGreater(
            metrics["candidate_plateau_outside_reference_dilation_fraction"],
            0.0001,
        )

    def test_spatial_plateau_metrics_reject_widespread_detail_collapse(self) -> None:
        reference = self.plateau_fixture((slice(20, 30), slice(20, 30)))
        candidate = self.plateau_fixture((slice(10, 50), slice(10, 50)))

        metrics = ANALYSIS.shared_highlight_plateau_spatial_metrics(
            reference, candidate, tolerance_pixels=1
        )

        self.assertGreater(
            metrics["shared_highlight_plateau_area_fraction_change"], 0.0001
        )
        self.assertGreater(
            metrics["candidate_plateau_outside_reference_dilation_fraction"],
            0.0001,
        )

    def test_spatial_plateau_metrics_reject_same_area_far_relocation(self) -> None:
        reference = self.plateau_fixture((slice(10, 30), slice(10, 30)))
        candidate = self.plateau_fixture((slice(60, 80), slice(60, 80)))

        metrics = ANALYSIS.shared_highlight_plateau_spatial_metrics(
            reference, candidate, tolerance_pixels=1
        )

        self.assertAlmostEqual(
            metrics["shared_highlight_plateau_area_fraction_change"], 0
        )
        self.assertGreater(
            metrics["candidate_plateau_outside_reference_dilation_fraction"],
            0.0001,
        )

    def test_spatial_plateau_metrics_allow_candidate_plateau_decrease(self) -> None:
        reference = self.plateau_fixture((slice(10, 30), slice(10, 30)))
        candidate = self.plateau_fixture((slice(12, 28), slice(12, 28)))

        metrics = ANALYSIS.shared_highlight_plateau_spatial_metrics(
            reference, candidate, tolerance_pixels=1
        )

        self.assertLess(
            metrics["shared_highlight_plateau_area_fraction_change"], 0
        )
        self.assertEqual(
            metrics["candidate_plateau_outside_reference_dilation_fraction"], 0
        )

    def test_spatial_plateau_metrics_separate_net_growth_from_spatial_growth(self) -> None:
        reference = self.plateau_fixture((slice(10, 30), slice(10, 30)))
        candidate = self.plateau_fixture((slice(9, 31), slice(9, 31)))

        metrics = ANALYSIS.shared_highlight_plateau_spatial_metrics(
            reference, candidate, tolerance_pixels=1
        )

        self.assertGreater(
            metrics["shared_highlight_plateau_area_fraction_change"], 0.0001
        )
        self.assertEqual(
            metrics["candidate_plateau_outside_reference_dilation_fraction"], 0
        )

    def test_mean_ev_drift_uses_linear_luminance_and_excludes_black(self) -> None:
        def encode(linear: float) -> float:
            if linear <= 0.0031308:
                return 12.92 * linear
            return 1.055 * linear ** (1 / 2.4) - 0.055

        reference = np.full((8, 8, 3), encode(0.18), dtype=np.float32)
        candidate = np.full((8, 8, 3), encode(0.36), dtype=np.float32)
        reference[0, 0, :] = 0
        candidate[0, 0, :] = 1

        self.assertAlmostEqual(ANALYSIS.mean_ev_drift(reference, candidate), 1.0, places=5)

    @staticmethod
    def metrics(
        *, clip: float, near_clip: float, plateau: float, delta_e: float, ev: float
    ) -> dict[str, float]:
        return {
            "candidate_complete_clip_fraction": clip,
            "candidate_near_clip_fraction": near_clip,
            "candidate_highlight_plateau_fraction": plateau,
            "shared_highlight_plateau_fraction": plateau,
            "new_shared_highlight_plateau_fraction": 0.0,
            "all_mean": delta_e,
            "mean_ev_drift": ev,
        }

    def gate_fixture(
        self,
        *,
        basic: dict[str, float],
        full: dict[str, float],
    ) -> dict[str, dict[str, dict[str, float]]]:
        basic = dict(basic)
        full = dict(full)
        full["new_shared_highlight_plateau_fraction"] = max(
            full["shared_highlight_plateau_fraction"]
            - basic["shared_highlight_plateau_fraction"],
            0,
        )
        return {
            "scene": {
                "xmp-basic": basic,
                "xmp-full-current": full,
                "lr-input-xmp-basic": dict(basic),
                "lr-input-xmp-full-current": dict(full),
            }
        }

    def test_quality_gates_pass_for_non_regressing_full_stage(self) -> None:
        basic = self.metrics(clip=0.02, near_clip=0.025, plateau=0.02, delta_e=4.0, ev=0.2)
        full = self.metrics(clip=0.01, near_clip=0.02, plateau=0.01, delta_e=4.2, ev=0.24)

        result = ANALYSIS.evaluate_quality_gates(
            self.gate_fixture(basic=basic, full=full), stems=("scene",)
        )

        self.assertTrue(result["passed"])
        self.assertTrue(result["scenes"]["scene"]["raw"]["passed"])
        self.assertTrue(result["scenes"]["scene"]["lr_input"]["passed"])

    def test_quality_gates_fail_for_plateau_regression(self) -> None:
        basic = self.metrics(clip=0.02, near_clip=0.025, plateau=0.02, delta_e=4.0, ev=0.2)
        full = self.metrics(clip=0.01, near_clip=0.02, plateau=0.04, delta_e=4.2, ev=0.24)

        result = ANALYSIS.evaluate_quality_gates(
            self.gate_fixture(basic=basic, full=full), stems=("scene",)
        )

        self.assertFalse(result["passed"])
        raw_checks = result["scenes"]["scene"]["raw"]["checks"]
        self.assertFalse(
            raw_checks["new_shared_highlight_plateau_area"]["passed"]
        )

    def test_quality_gates_enforce_every_numeric_limit(self) -> None:
        basic = self.metrics(clip=0.02, near_clip=0.025, plateau=0.02, delta_e=4.0, ev=0.2)
        full = self.metrics(clip=0.021, near_clip=0.026, plateau=0.031, delta_e=4.251, ev=0.251)

        result = ANALYSIS.evaluate_quality_gates(
            self.gate_fixture(basic=basic, full=full), stems=("scene",)
        )

        checks = result["scenes"]["scene"]["raw"]["checks"]
        self.assertFalse(checks["complete_clip_non_regression"]["passed"])
        self.assertFalse(checks["near_clip_non_regression"]["passed"])
        self.assertFalse(checks["new_shared_highlight_plateau_area"]["passed"])
        self.assertFalse(checks["mean_delta_e_regression"]["passed"])
        self.assertFalse(checks["mean_ev_drift_non_regression"]["passed"])

    def test_mean_ev_gate_allows_full_stage_to_move_toward_reference(self) -> None:
        basic = self.metrics(clip=0.02, near_clip=0.025, plateau=0.02, delta_e=4.0, ev=0.5)
        full = self.metrics(clip=0.01, near_clip=0.02, plateau=0.01, delta_e=4.2, ev=0.0)

        result = ANALYSIS.evaluate_quality_gates(
            self.gate_fixture(basic=basic, full=full), stems=("scene",)
        )

        check = result["scenes"]["scene"]["raw"]["checks"][
            "mean_ev_drift_non_regression"
        ]
        self.assertTrue(check["passed"])
        self.assertEqual(check["basic_absolute_error"], 0.5)
        self.assertEqual(check["full_absolute_error"], 0.0)

    def test_quality_gates_fail_closed_for_missing_candidate(self) -> None:
        basic = self.metrics(clip=0.02, near_clip=0.025, plateau=0.02, delta_e=4.0, ev=0.2)
        full = self.metrics(clip=0.01, near_clip=0.02, plateau=0.01, delta_e=4.2, ev=0.24)
        fixture = self.gate_fixture(basic=basic, full=full)
        del fixture["scene"]["xmp-full-current"]

        result = ANALYSIS.evaluate_quality_gates(fixture, stems=("scene",))

        self.assertFalse(result["passed"])
        self.assertFalse(result["all_expected_candidates_present"])
        self.assertIn("scene-xmp-full-current.tif", result["missing_candidates"])

    def test_quality_gates_include_external_missing_candidate(self) -> None:
        basic = self.metrics(clip=0.02, near_clip=0.025, plateau=0.02, delta_e=4.0, ev=0.2)
        full = self.metrics(clip=0.01, near_clip=0.02, plateau=0.01, delta_e=4.2, ev=0.24)

        result = ANALYSIS.evaluate_quality_gates(
            self.gate_fixture(basic=basic, full=full),
            stems=("scene",),
            missing_candidates=["scene-boost-090.tif"],
        )

        self.assertFalse(result["passed"])
        self.assertIn("scene-boost-090.tif", result["missing_candidates"])

    @staticmethod
    def preview_measurement(
        *, delta_e: float, ev: float, new_plateau: float
    ) -> dict[str, object]:
        return {
            "metrics": {
                "mean_delta_e_2000": delta_e,
                "mean_ev_drift": ev,
                "reference_shared_highlight_plateau_fraction": 0.001,
                "candidate_shared_highlight_plateau_fraction": (
                    0.001 + new_plateau
                ),
                "new_shared_highlight_plateau_fraction": new_plateau,
            }
        }

    def preview_gate_fixture(
        self, *, delta_e: float, ev: float, new_plateau: float
    ) -> dict[str, dict[str, dict[str, object]]]:
        return {
            scene_id: {
                stage_id: self.preview_measurement(
                    delta_e=delta_e,
                    ev=ev,
                    new_plateau=new_plateau,
                )
                for stage_id in ANALYSIS.PREVIEW_PARITY_STAGE_IDS
            }
            for scene_id in ("scene-a", "scene-b")
        }

    def test_preview_parity_gates_pass_at_every_inclusive_limit(self) -> None:
        result = ANALYSIS.evaluate_preview_parity_gates(
            self.preview_gate_fixture(delta_e=1.0, ev=-0.02, new_plateau=0.0001),
            scene_ids=("scene-a", "scene-b"),
        )

        self.assertTrue(result["passed"])
        self.assertEqual(result["evaluated_pair_count"], 6)
        self.assertTrue(
            result["scenes"]["scene-a"]["neutral"]["passed"]
        )

    def test_preview_parity_gates_fail_each_numeric_threshold_independently(self) -> None:
        cases = (
            (1.000001, 0.0, 0.0, "mean_delta_e_2000"),
            (0.0, -0.020001, 0.0, "mean_ev_absolute_drift"),
            (0.0, 0.0, 0.000101, "new_shared_highlight_plateau_area"),
        )
        for delta_e, ev, plateau, check_name in cases:
            with self.subTest(check=check_name):
                result = ANALYSIS.evaluate_preview_parity_gates(
                    self.preview_gate_fixture(
                        delta_e=delta_e,
                        ev=ev,
                        new_plateau=plateau,
                    ),
                    scene_ids=("scene-a", "scene-b"),
                )
                self.assertFalse(result["passed"])
                checks = result["scenes"]["scene-a"]["neutral"]["checks"]
                self.assertFalse(checks[check_name]["passed"])

    def test_preview_parity_missing_stage_is_structural_failure(self) -> None:
        fixture = self.preview_gate_fixture(delta_e=0.0, ev=0.0, new_plateau=0.0)
        del fixture["scene-b"]["full-current"]

        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "stage"
        ):
            ANALYSIS.evaluate_preview_parity_gates(
                fixture, scene_ids=("scene-a", "scene-b")
            )

    @staticmethod
    def preview_v3_measurement(
        *,
        delta_e: float,
        p95: float,
        ev: float,
        net_plateau_change: float,
        outside_dilation: float,
    ) -> dict[str, object]:
        reference_fraction = 0.001
        return {
            "metrics": {
                "mean_delta_e_2000": delta_e,
                "blurred_delta_e_2000_p95": p95,
                "mean_ev_drift": ev,
                "reference_shared_highlight_plateau_fraction": reference_fraction,
                "candidate_shared_highlight_plateau_fraction": (
                    reference_fraction + net_plateau_change
                ),
                "shared_highlight_plateau_area_fraction_change": net_plateau_change,
                "candidate_plateau_outside_reference_dilation_fraction": (
                    outside_dilation
                ),
                "legacy_new_shared_highlight_plateau_fraction": max(
                    outside_dilation, 0.0002
                ),
                "candidate_plateau_outside_reference_dilation_largest_component_fraction": (
                    outside_dilation
                ),
                "candidate_plateau_outside_reference_dilation_largest_component_bbox": (
                    None
                ),
            }
        }

    def preview_v3_gate_fixture(
        self,
        *,
        delta_e: float = 1.0,
        p95: float = 2.0,
        ev: float = -0.02,
        net_plateau_change: float = 0.0001,
        outside_dilation: float = 0.0001,
    ) -> dict[str, dict[str, dict[str, dict[str, object]]]]:
        return {
            scene_id: {
                str(dimension): {
                    stage_id: self.preview_v3_measurement(
                        delta_e=delta_e,
                        p95=p95,
                        ev=ev,
                        net_plateau_change=net_plateau_change,
                        outside_dilation=outside_dilation,
                    )
                    for stage_id in ANALYSIS.PREVIEW_PARITY_STAGE_IDS
                }
                for dimension in (3072, 3840)
            }
            for scene_id in ("scene-a", "scene-b")
        }

    def test_preview_parity_v3_passes_inclusive_limits_and_selects_3072(self) -> None:
        result = ANALYSIS.evaluate_preview_parity_v3_gates(
            self.preview_v3_gate_fixture(),
            scene_ids=("scene-a", "scene-b"),
            candidate_dimensions=(3072, 3840),
        )

        self.assertTrue(result["passed"])
        self.assertEqual(result["evaluated_pair_count"], 12)
        self.assertEqual(
            result["eligible_candidate_decode_maximum_dimensions"], [3072, 3840]
        )
        self.assertEqual(
            result["selected_candidate_decode_maximum_dimension"], 3072
        )

    def test_preview_parity_v3_fails_each_numeric_threshold_independently(self) -> None:
        cases = (
            ({"delta_e": 1.000001}, "mean_delta_e_2000"),
            ({"p95": 2.000001}, "blurred_delta_e_2000_p95"),
            ({"ev": -0.020001}, "mean_ev_absolute_drift"),
            (
                {"net_plateau_change": 0.000101},
                "net_shared_highlight_plateau_area_increase",
            ),
            (
                {"outside_dilation": 0.000101},
                "spatially_distinct_new_shared_highlight_plateau_area",
            ),
        )
        for overrides, check_name in cases:
            with self.subTest(check=check_name):
                result = ANALYSIS.evaluate_preview_parity_v3_gates(
                    self.preview_v3_gate_fixture(**overrides),
                    scene_ids=("scene-a", "scene-b"),
                    candidate_dimensions=(3072, 3840),
                )
                self.assertFalse(result["passed"])
                checks = result["candidates"]["3072"]["scenes"]["scene-a"][
                    "neutral"
                ]["checks"]
                self.assertFalse(checks[check_name]["passed"])

    def test_preview_parity_v3_selects_3840_when_3072_fails(self) -> None:
        fixture = self.preview_v3_gate_fixture(
            net_plateau_change=-0.0005,
            outside_dilation=0,
        )
        fixture["scene-a"]["3072"]["neutral"] = self.preview_v3_measurement(
            delta_e=1.1,
            p95=2.0,
            ev=0,
            net_plateau_change=0,
            outside_dilation=0,
        )

        result = ANALYSIS.evaluate_preview_parity_v3_gates(
            fixture,
            scene_ids=("scene-a", "scene-b"),
            candidate_dimensions=(3072, 3840),
        )

        self.assertFalse(result["candidates"]["3072"]["passed"])
        self.assertTrue(result["candidates"]["3840"]["passed"])
        self.assertEqual(
            result["selected_candidate_decode_maximum_dimension"], 3840
        )

    def test_preview_parity_v3_missing_candidate_is_structural_failure(self) -> None:
        fixture = self.preview_v3_gate_fixture()
        del fixture["scene-b"]["3840"]

        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "candidate route"
        ):
            ANALYSIS.evaluate_preview_parity_v3_gates(
                fixture,
                scene_ids=("scene-a", "scene-b"),
                candidate_dimensions=(3072, 3840),
            )


class CalibrationEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.manifest, self.run = self._make_evidence()

    @staticmethod
    def _hash(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _write_bytes(self, relative: str, data: bytes) -> dict[str, object]:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return {"path": relative, "sha256": self._hash(path)}

    def _make_evidence(self) -> tuple[dict[str, object], dict[str, object]]:
        preset = self._write_bytes("fixture.xmp", b"preset")
        scene_fixtures: list[dict[str, object]] = []
        for scene_id in ("scene-a", "scene-b"):
            scene_fixtures.append(
                {
                    "id": scene_id,
                    "sceneGroup": "synthetic",
                    "fold": "development",
                    "lighting": "controlled",
                    "capture": {"width": 6, "height": 4},
                    "raw": self._write_bytes(
                        f"fixtures/{scene_id}.raw", f"raw-{scene_id}".encode()
                    ),
                    "lightroomBefore": self._write_bytes(
                        f"fixtures/{scene_id}-before.tif",
                        f"lightroom-before-{scene_id}".encode(),
                    ),
                    "lightroomAfter": self._write_bytes(
                        f"fixtures/{scene_id}-after.tif",
                        f"lightroom-after-{scene_id}".encode(),
                    ),
                }
            )
        source_path = self.root / "source.swift"
        source_path.write_text("let version = 1\n", encoding="utf-8")

        legacy = [
            {"id": identifier, "rawLabel": labels[0], "lightroomInputLabel": labels[1]}
            for identifier, labels in ANALYSIS.LEGACY_CANDIDATE_CONTRACT.items()
        ]
        stages = [
            {
                "id": identifier,
                "rawLabel": labels[0],
                "lightroomInputLabel": labels[1],
            }
            for identifier, labels in ANALYSIS.STAGE_CANDIDATE_CONTRACT.items()
        ]
        manifest: dict[str, object] = {
            "schemaVersion": 2,
            "suiteID": "test-suite",
            "description": "synthetic calibration evidence",
            "expectedEnvironment": {
                "macOSVersion": "1.2.3",
                "macOSBuild": "build",
                "architecture": "arm64",
                "hardwareModel": "Mac-test",
                "metalDevice": "GPU-test",
                "rawDecoderBackend": "RAW-test",
            },
            "processing": {
                "fingerprint": {
                    "rawDecode": "raw-decode",
                    "basicTone": "basic",
                    "toneCurve": "curve",
                    "colorMixer": "mixer",
                    "outputTransform": "output",
                },
                "sourceFiles": ["source.swift"],
            },
            "preset": {
                "file": preset,
                "uuid": "preset-uuid",
                "cameraRawVersion": "17.0",
                "processVersion": "11.0",
            },
            "comparison": dict(ANALYSIS.COMPARISON_CONTRACT),
            "rawProfile": dict(ANALYSIS.RAW_PROFILE_CONTRACT),
            "diagnostics": {
                "boostAmounts": [0.0],
                "extendedDynamicRangeAmounts": [0.0],
            },
            "legacyCandidates": legacy,
            "stageMatrix": stages,
            "qualityGate": {
                "routes": [
                    {"id": "raw", "basicLabel": "xmp-basic", "fullLabel": "xmp-full-current"},
                    {
                        "id": "lr-input",
                        "basicLabel": "lr-input-xmp-basic",
                        "fullLabel": "lr-input-xmp-full-current",
                    },
                ],
                "meanDeltaEMaximumIncrease": 0.25,
                "meanEVAbsoluteErrorMaximumIncrease": 0.05,
                "newSharedPlateauMaximumArea": 0.0005,
            },
            "benchmark": {"previewMaxDimension": 4},
            "previewParity": {
                "maxDimension": 4,
                "settingsStageIDs": list(ANALYSIS.PREVIEW_PARITY_STAGE_IDS),
                "baselineDecodeIntent": "full-resolution",
                "candidateDecodeIntent": "interactive-preview",
                "thresholds": {
                    "meanDeltaEMaximum": 1.0,
                    "meanEVAbsoluteDriftMaximum": 0.02,
                    "newSharedPlateauMaximumArea": 0.0001,
                },
            },
            "scenes": scene_fixtures,
        }
        manifest_path = self.root / ANALYSIS.DEFAULT_MANIFEST_PATH
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        artifacts: list[dict[str, object]] = []
        for index, (relative, specification) in enumerate(
            ANALYSIS.expected_artifact_specs(manifest).items()
        ):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            is_preview_parity = specification.get("candidateGroup") == "preview-parity"
            if is_preview_parity:
                stage_id = specification["candidateID"]
                scene_id = specification["sceneID"]
                stage_index = ANALYSIS.PREVIEW_PARITY_STAGE_IDS.index(stage_id)
                scene_index = ("scene-a", "scene-b").index(scene_id)
                value = np.uint16(20_000 + scene_index * 1_000 + stage_index * 100)
                image = np.full((3, 4, 3), value, dtype=np.uint16)
                settings = {"stage": stage_id}
            else:
                value = np.uint16(30_000 + index * 100)
                image = np.full((4, 6, 3), value, dtype=np.uint16)
                settings = {}
            write_srgb_tiff(path, image)
            canonical_settings = json.dumps(
                settings,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
            artifacts.append(
                {
                    **specification,
                    "path": relative,
                    "sha256": self._hash(path),
                    "byteCount": path.stat().st_size,
                    "width": image.shape[1],
                    "height": image.shape[0],
                    "renderAndEncodeMilliseconds": float(index + 1),
                    "settings": settings,
                    "settingsSHA256": hashlib.sha256(canonical_settings).hexdigest(),
                }
            )

        input_records = ANALYSIS._fixture_records(manifest, self.root)
        source_hash = self._hash(source_path)
        source_record = {
            "role": "implementationSource",
            "path": "source.swift",
            "sha256": source_hash,
            "byteCount": source_path.stat().st_size,
        }
        source_fingerprint = hashlib.sha256(
            f"source.swift\0{source_hash}".encode("utf-8")
        ).hexdigest()
        decodes: list[dict[str, object]] = []
        for scene_id in ("scene-a", "scene-b"):
            for route, backend, intent, requested_maximum, scale, width, height in (
                ("raw", "RAW-test", "full-resolution", None, 1.0, 6, 4),
                ("lr-input", "Image I/O", "full-resolution", None, None, 6, 4),
                (
                    ANALYSIS.PREVIEW_PARITY_DECODE_ROUTES["full-resolution"],
                    "RAW-test",
                    "full-resolution",
                    None,
                    1.0,
                    6,
                    4,
                ),
                (
                    ANALYSIS.PREVIEW_PARITY_DECODE_ROUTES["interactive-preview"],
                    "RAW-test",
                    "interactive-preview",
                    4,
                    4 / 6,
                    4,
                    3,
                ),
            ):
                is_raw = backend == "RAW-test"
                decodes.append(
                    {
                        "sceneID": scene_id,
                        "route": route,
                        "backend": backend,
                        "intent": intent,
                        "requestedMaximumDimension": requested_maximum,
                        "nativeWidth": 6,
                        "nativeHeight": 4,
                        "appliedScaleFactor": scale,
                        "width": width,
                        "height": height,
                        "decoderGraphSetupMilliseconds": 1.0,
                        "cameraMake": "Camera" if is_raw else None,
                        "cameraModel": "Model" if is_raw else None,
                        "calibrationID": (
                            ANALYSIS.RAW_PROFILE_CONTRACT["id"] if is_raw else None
                        ),
                    }
                )
        run: dict[str, object] = {
            "schemaVersion": 2,
            "status": "complete",
            "runID": "run-id",
            "startedAtUTC": "2026-07-24T00:00:00Z",
            "completedAtUTC": "2026-07-24T00:01:00Z",
            "manifest": {
                "path": ANALYSIS.DEFAULT_MANIFEST_PATH,
                "sha256": self._hash(manifest_path),
                "suiteID": "test-suite",
            },
            "runtime": {
                "macOSVersion": "1.2.3",
                "macOSBuild": "build",
                "architecture": "arm64",
                "hardwareModel": "Mac-test",
                "processorCount": 1,
                "physicalMemoryBytes": 1,
                "thermalState": "nominal",
                "lowPowerModeEnabled": False,
                "buildConfiguration": "release",
                "coreImageFrameworkVersion": "1",
                "executableSHA256": "e" * 64,
                "metalDevice": {
                    "name": "GPU-test",
                    "registryID": 1,
                    "hasUnifiedMemory": True,
                    "currentAllocatedSize": 1,
                    "recommendedMaxWorkingSetSize": 2,
                },
            },
            "processing": manifest["processing"]["fingerprint"],
            "sourceFingerprintSHA256": source_fingerprint,
            "postflightSourceFingerprintSHA256": source_fingerprint,
            "sourceFiles": [source_record],
            "verifiedInputs": json.loads(json.dumps(input_records)),
            "postflightVerifiedInputs": json.loads(json.dumps(input_records)),
            "decodes": decodes,
            "artifacts": artifacts,
            "edrHeadroom": [
                {
                    "sceneID": scene_id,
                    "amount": 0.0,
                    "maximumChannel": 1.0,
                    "extendedChannelPixelFraction": 0.0,
                    "maximumLuminance": 1.0,
                    "extendedLuminancePixelFraction": 0.0,
                }
                for scene_id in ("scene-a", "scene-b")
            ],
        }
        run_path = self.root / ANALYSIS.DEFAULT_RUN_MANIFEST_PATH
        run_path.parent.mkdir(parents=True, exist_ok=True)
        run_path.write_text(json.dumps(run), encoding="utf-8")
        return manifest, run

    def _save_run(self) -> None:
        path = self.root / ANALYSIS.DEFAULT_RUN_MANIFEST_PATH
        path.write_text(json.dumps(self.run), encoding="utf-8")

    def _artifact(self, relative: str) -> dict[str, object]:
        return next(
            artifact
            for artifact in self.run["artifacts"]
            if artifact["path"] == relative
        )

    def _refresh_artifact_record(
        self, artifact: dict[str, object], path: Path, image: np.ndarray
    ) -> None:
        artifact["sha256"] = self._hash(path)
        artifact["byteCount"] = path.stat().st_size
        artifact["width"] = image.shape[1]
        artifact["height"] = image.shape[0]

    def test_manifest_and_complete_run_validate_all_evidence(self) -> None:
        report = ANALYSIS.analyze_calibration(self.root)

        self.assertEqual(report["schema_version"], 4)
        self.assertEqual(report["validation"]["status"], "passed")
        self.assertEqual(
            report["validation"]["artifacts"]["verified"],
            len(ANALYSIS.expected_artifact_specs(self.manifest)),
        )
        self.assertTrue(report["validation"]["sources"]["postflight_matches"])
        self.assertEqual(set(report["preview_parity"]), {"scene-a", "scene-b"})
        self.assertEqual(
            set(report["preview_parity"]["scene-a"]),
            set(ANALYSIS.PREVIEW_PARITY_STAGE_IDS),
        )
        self.assertEqual(report["preview_parity_gates"]["evaluated_pair_count"], 6)
        self.assertTrue(report["preview_parity_gates"]["passed"])

    def test_stale_artifact_hash_fails_closed_and_replaces_report(self) -> None:
        artifact = self.run["artifacts"][0]
        path = self.root / artifact["path"]
        image = np.full((4, 6, 3), 60_000, dtype=np.uint16)
        self.assertTrue(cv2.imwrite(str(path), image))

        status = ANALYSIS.main([str(self.root)])

        self.assertEqual(status, 2)
        report = json.loads(
            (self.root / ".photobench/calibration/report.json").read_text(encoding="utf-8")
        )
        self.assertEqual(report["validation"]["status"], "failed")
        self.assertIn("SHA-256", report["validation"]["errors"][0])

    def test_preflight_and_postflight_inputs_must_match(self) -> None:
        self.run["postflightVerifiedInputs"][0]["sha256"] = "f" * 64
        self._save_run()

        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "postflight入力"
        ):
            ANALYSIS.analyze_calibration(self.root)

    def test_run_must_be_complete_and_bound_to_current_manifest_hash(self) -> None:
        self.run["status"] = "running"
        self.run["completedAtUTC"] = None
        self._save_run()
        with self.assertRaisesRegex(ANALYSIS.StructuralValidationError, "complete"):
            ANALYSIS.analyze_calibration(self.root)

        self.run["status"] = "complete"
        self.run["completedAtUTC"] = "2026-07-24T00:01:00Z"
        self.run["manifest"]["sha256"] = "f" * 64
        self._save_run()
        with self.assertRaisesRegex(ANALYSIS.StructuralValidationError, "現在のmanifest"):
            ANALYSIS.analyze_calibration(self.root)

    def test_artifact_byte_count_and_dimensions_must_match(self) -> None:
        artifact = self.run["artifacts"][0]
        original_byte_count = artifact["byteCount"]
        artifact["byteCount"] = original_byte_count + 1
        self._save_run()
        with self.assertRaisesRegex(ANALYSIS.StructuralValidationError, "byteCount"):
            ANALYSIS.analyze_calibration(self.root)

        artifact["byteCount"] = original_byte_count
        artifact["width"] = artifact["width"] + 1
        self._save_run()
        with self.assertRaisesRegex(ANALYSIS.StructuralValidationError, "dimension"):
            ANALYSIS.analyze_calibration(self.root)

    def test_missing_preview_parity_artifact_fails_closed(self) -> None:
        relative = (
            ".photobench/calibration/renders/"
            "scene-b-preview-parity-full-current-scaled-decode.tif"
        )
        self.run["artifacts"] = [
            artifact
            for artifact in self.run["artifacts"]
            if artifact["path"] != relative
        ]
        self._save_run()

        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "artifactが不足"
        ):
            ANALYSIS.analyze_calibration(self.root)

    def test_preview_parity_pair_shape_mismatch_fails_closed(self) -> None:
        relative = (
            ".photobench/calibration/renders/"
            "scene-a-preview-parity-neutral-scaled-decode.tif"
        )
        artifact = self._artifact(relative)
        path = self.root / relative
        image = np.full((2, 4, 3), 20_000, dtype=np.uint16)
        write_srgb_tiff(path, image)
        self._refresh_artifact_record(artifact, path, image)
        self._save_run()

        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "shapeが一致"
        ):
            ANALYSIS.analyze_calibration(self.root)

    def test_preview_parity_pair_settings_mismatch_fails_closed(self) -> None:
        relative = (
            ".photobench/calibration/renders/"
            "scene-a-preview-parity-neutral-scaled-decode.tif"
        )
        artifact = self._artifact(relative)
        artifact["settings"] = {"stage": "neutral", "exposure": 1.0}
        canonical = json.dumps(
            artifact["settings"],
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
        artifact["settingsSHA256"] = hashlib.sha256(canonical).hexdigest()
        self._save_run()

        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "settings不一致"
        ):
            ANALYSIS.analyze_calibration(self.root)

    def test_preview_decode_intent_and_scale_factor_fail_closed(self) -> None:
        original_run = json.loads(json.dumps(self.run))
        cases = (
            ("intent", "full-resolution", "decode intent"),
            ("appliedScaleFactor", 0.5, "scaleFactor"),
        )
        route = ANALYSIS.PREVIEW_PARITY_DECODE_ROUTES["interactive-preview"]
        for field, invalid, expected_message in cases:
            with self.subTest(field=field):
                self.run = json.loads(json.dumps(original_run))
                decode = next(
                    record
                    for record in self.run["decodes"]
                    if record["sceneID"] == "scene-a" and record["route"] == route
                )
                decode[field] = invalid
                self._save_run()
                with self.assertRaisesRegex(
                    ANALYSIS.StructuralValidationError, expected_message
                ):
                    ANALYSIS.analyze_calibration(self.root)

    def test_artifact_without_srgb_icc_fails_closed(self) -> None:
        relative = (
            ".photobench/calibration/renders/"
            "scene-a-preview-parity-neutral-scaled-decode.tif"
        )
        artifact = self._artifact(relative)
        path = self.root / relative
        image = np.full((3, 4, 3), 20_000, dtype=np.uint16)
        self.assertTrue(cv2.imwrite(str(path), image))
        self._refresh_artifact_record(artifact, path, image)
        self._save_run()

        with self.assertRaisesRegex(RuntimeError, "sRGB ICC"):
            ANALYSIS.analyze_calibration(self.root)

    def test_artifact_with_srgb_icc_but_uint8_pixels_fails_closed(self) -> None:
        relative = (
            ".photobench/calibration/renders/"
            "scene-a-preview-parity-neutral-scaled-decode.tif"
        )
        artifact = self._artifact(relative)
        path = self.root / relative
        image = np.full((3, 4, 3), 128, dtype=np.uint8)
        Image.fromarray(image, mode="RGB").save(
            path,
            format="TIFF",
            icc_profile=TEST_SRGB_ICC_PROFILE,
        )
        self._refresh_artifact_record(artifact, path, image)
        self._save_run()

        with self.assertRaisesRegex(RuntimeError, "16-bit"):
            ANALYSIS.analyze_calibration(self.root)

    def test_postflight_source_fingerprint_must_match(self) -> None:
        self.run["postflightSourceFingerprintSHA256"] = "f" * 64
        self._save_run()

        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "preflight/postflight"
        ):
            ANALYSIS.analyze_calibration(self.root)

    def test_runtime_executable_sha256_is_required_and_canonical(self) -> None:
        for invalid in (None, "a" * 63, "A" * 64, "g" * 64):
            with self.subTest(invalid=invalid):
                self.run["runtime"]["executableSHA256"] = invalid
                self._save_run()
                with self.assertRaisesRegex(
                    ANALYSIS.StructuralValidationError,
                    "run.runtime.executableSHA256",
                ):
                    ANALYSIS.analyze_calibration(self.root)

    def test_stage_matrix_reports_both_routes_and_non_additive_effect(self) -> None:
        report = ANALYSIS.analyze_calibration(self.root)

        matrix = report["stage_matrix"]["scene-a"]
        self.assertIn("raw", matrix)
        self.assertIn("lr_input", matrix)
        self.assertEqual(
            set(matrix["raw"]["stages"]),
            set(ANALYSIS.STAGE_CANDIDATE_CONTRACT),
        )
        effect = matrix["raw"]["stages"]["tone-plus-vibrance"]["effect_vs_tone_base"]
        self.assertEqual(effect["interpretation"], "pairwise non-additive diagnostic")
        self.assertIn("direct_image_difference", effect)
        self.assertIn("metric_delta_vs_reference", effect)

    def test_read_srgb_rejects_uint8_and_grayscale(self) -> None:
        uint8_path = self.root / "uint8.tif"
        grayscale_path = self.root / "gray.tif"
        rgba_path = self.root / "rgba.tif"
        self.assertTrue(cv2.imwrite(str(uint8_path), np.zeros((3, 4, 3), dtype=np.uint8)))
        self.assertTrue(cv2.imwrite(str(grayscale_path), np.zeros((3, 4), dtype=np.uint16)))
        self.assertTrue(cv2.imwrite(str(rgba_path), np.zeros((3, 4, 4), dtype=np.uint16)))

        with mock.patch.object(
            ANALYSIS, "_require_srgb_icc_profile", return_value="sRGB"
        ):
            with self.assertRaisesRegex(RuntimeError, "16-bit"):
                ANALYSIS.read_srgb(uint8_path)
            with self.assertRaisesRegex(RuntimeError, "3/4 channel"):
                ANALYSIS.read_srgb(grayscale_path)
            self.assertEqual(ANALYSIS.read_srgb(rgba_path).shape, (3, 4, 3))

    def test_read_srgb_requires_embedded_srgb_icc_and_accepts_valid_tiff(self) -> None:
        no_icc_path = self.root / "no-icc.tif"
        valid_path = self.root / "valid-srgb.tif"
        image = np.full((3, 4, 3), 20_000, dtype=np.uint16)
        self.assertTrue(cv2.imwrite(str(no_icc_path), image))
        write_srgb_tiff(valid_path, image)

        with self.assertRaisesRegex(RuntimeError, "sRGB ICC"):
            ANALYSIS.read_srgb(no_icc_path)
        self.assertEqual(ANALYSIS.read_srgb(valid_path).shape, (3, 4, 3))

    def test_manifest_schema_is_fail_closed(self) -> None:
        self.manifest["schemaVersion"] = 99

        with self.assertRaisesRegex(ANALYSIS.StructuralValidationError, "schema"):
            ANALYSIS.validate_manifest(self.manifest, self.root)

    def test_manifest_v3_freezes_oversampled_decode_and_spatial_gate_contract(self) -> None:
        manifest = json.loads(json.dumps(self.manifest))
        manifest["schemaVersion"] = 3
        manifest["benchmark"]["previewMaxDimension"] = 2560
        manifest["previewParity"] = {
            "outputMaxDimension": 2560,
            "candidateDecodeMaximumDimensions": [3072, 3840],
            "plateauSpatialTolerance": {
                "radiusPixels": 1,
                "structuringElement": "square-3x3",
            },
            "settingsStageIDs": list(ANALYSIS.PREVIEW_PARITY_STAGE_IDS),
            "baselineDecodeIntent": "full-resolution",
            "candidateDecodeIntent": "interactive-preview",
            "thresholds": {
                "meanDeltaEMaximum": 1.0,
                "blurredDeltaE2000P95Maximum": 2.0,
                "meanEVAbsoluteDriftMaximum": 0.02,
                "netSharedPlateauAreaIncreaseMaximum": 0.0001,
                "spatiallyDistinctNewSharedPlateauMaximumArea": 0.0001,
            },
        }

        ANALYSIS.validate_manifest(manifest, self.root)
        self.assertEqual(
            len(ANALYSIS.expected_artifact_specs(manifest)),
            len(ANALYSIS.expected_artifact_specs(self.manifest)) + 6,
        )

        invalid = json.loads(json.dumps(manifest))
        invalid["previewParity"]["candidateDecodeMaximumDimensions"] = [2560, 3840]
        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "candidateDecodeMaximumDimensions"
        ):
            ANALYSIS.validate_manifest(invalid, self.root)

        invalid = json.loads(json.dumps(manifest))
        invalid["previewParity"]["plateauSpatialTolerance"][
            "structuringElement"
        ] = "cross"
        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "square-3x3"
        ):
            ANALYSIS.validate_manifest(invalid, self.root)

    def test_manifest_v2_fixed_comparison_raw_profile_and_stage_labels(self) -> None:
        invalid_comparison = json.loads(json.dumps(self.manifest))
        invalid_comparison["comparison"]["maxDimension"] = 1499
        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "comparison.maxDimension"
        ):
            ANALYSIS.validate_manifest(invalid_comparison, self.root)

        invalid_profile = json.loads(json.dumps(self.manifest))
        invalid_profile["rawProfile"]["boostAmount"] = 0.89
        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "rawProfile.boostAmount"
        ):
            ANALYSIS.validate_manifest(invalid_profile, self.root)

        invalid_stage = json.loads(json.dumps(self.manifest))
        invalid_stage["stageMatrix"][0]["rawLabel"] = "xmp-stage-renamed"
        with self.assertRaisesRegex(
            ANALYSIS.StructuralValidationError, "stageMatrix.*v2固定契約"
        ):
            ANALYSIS.validate_manifest(invalid_stage, self.root)

    def test_quality_and_preview_exit_policies_are_independent(self) -> None:
        quality_failed = {
            "quality_gates": {"passed": False},
            "preview_parity_gates": {"passed": True},
        }
        with mock.patch.object(
            ANALYSIS, "analyze_calibration", return_value=quality_failed
        ):
            self.assertEqual(ANALYSIS.main([str(self.root)]), 0)
            self.assertEqual(ANALYSIS.main([str(self.root), "--enforce"]), 1)
            self.assertEqual(
                ANALYSIS.main([str(self.root), "--enforce-preview-parity"]), 0
            )

        preview_failed = {
            "quality_gates": {"passed": True},
            "preview_parity_gates": {"passed": False},
        }
        with mock.patch.object(
            ANALYSIS, "analyze_calibration", return_value=preview_failed
        ):
            self.assertEqual(ANALYSIS.main([str(self.root)]), 0)
            self.assertEqual(ANALYSIS.main([str(self.root), "--enforce"]), 0)
            self.assertEqual(
                ANALYSIS.main([str(self.root), "--enforce-preview-parity"]), 1
            )

    def test_structural_failure_is_always_exit_two(self) -> None:
        error = ANALYSIS.StructuralValidationError("stale evidence")
        with mock.patch.object(ANALYSIS, "analyze_calibration", side_effect=error):
            self.assertEqual(ANALYSIS.main([str(self.root)]), 2)
            self.assertEqual(ANALYSIS.main([str(self.root), "--enforce"]), 2)
            self.assertEqual(
                ANALYSIS.main([str(self.root), "--enforce-preview-parity"]), 2
            )

    def test_atomic_json_rejects_nonfinite_without_replacing_old_report(self) -> None:
        report_path = self.root / "report.json"
        report_path.write_text('{"old": true}\n', encoding="utf-8")

        with self.assertRaises(ValueError):
            ANALYSIS.atomic_write_json(report_path, {"bad": float("nan")})

        self.assertEqual(report_path.read_text(encoding="utf-8"), '{"old": true}\n')


if __name__ == "__main__":
    unittest.main()
