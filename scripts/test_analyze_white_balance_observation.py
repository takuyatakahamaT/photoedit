#!/usr/bin/env python3

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "analyze-white-balance-observation.py"
SPEC = importlib.util.spec_from_file_location("wb_observation_analyzer", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
ANALYZER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ANALYZER)


class WhiteBalanceObservationAnalyzerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(
            (ROOT / "calibration" / "white-balance-observation-v1.json").read_text(
                encoding="utf-8"
            )
        )
        self.base_manifest = json.loads(
            (ROOT / "calibration" / "manifest-v4.json").read_text(encoding="utf-8")
        )

    @staticmethod
    def _minimal_run_header(run_id: str) -> dict[str, object]:
        return {
            "schemaVersion": 1,
            "status": "complete",
            "adoptionStatus": ANALYZER.ADOPTION_STATUS,
            "productionAdoptionAllowed": False,
            "runID": run_id,
            "startedAtUTC": "2026-07-24T00:00:00Z",
            "completedAtUTC": "2026-07-24T00:01:00Z",
            "manifest": {},
            "baseCalibrationManifest": {},
            "runtime": {},
            "exifTool": {},
            "sourceFingerprintSHA256": "0" * 64,
            "postflightSourceFingerprintSHA256": "0" * 64,
            "sourceFiles": [],
            "verifiedInputs": [],
            "postflightVerifiedInputs": [],
            "sceneCount": 2,
            "holdoutCount": 0,
            "scenes": [],
            "artifacts": [],
            "setterOrderChecks": [],
        }

    def test_python_literals_match_manifest_and_expand_18_candidates(self) -> None:
        plan = self.manifest["candidatePlan"]
        self.assertEqual(
            plan["temperatureMiredOffsets"], ANALYZER.TEMPERATURE_MIRED_OFFSETS
        )
        self.assertEqual(plan["tintOffsets"], ANALYZER.TINT_OFFSETS)
        self.assertEqual(plan["corners"], ANALYZER.CORNERS)
        candidates = ANALYZER.expected_candidate_ids()
        contracts = ANALYZER.expected_candidate_contracts()
        self.assertEqual(len(candidates), 18)
        self.assertEqual(len(set(candidates)), 18)
        self.assertEqual(candidates[:2], ["as-shot", "custom-center"])
        self.assertEqual(list(contracts), candidates)
        self.assertEqual(
            contracts["corner-mired-plus-030-tint-minus-015"],
            {
                "candidate_id": "corner-mired-plus-030-tint-minus-015",
                "candidate_kind": "corner",
                "temperature_mired_offset": 30,
                "tint_offset": -15,
            },
        )
        ANALYZER.validate_manifest(self.manifest)

    def test_custom_request_uses_source_neutral_and_mired_offsets(self) -> None:
        source = {
            "temperatureKelvin": 5_000.0,
            "tint": 7.5,
            "chromaticityX": 0.34,
            "chromaticityY": 0.35,
        }
        contracts = ANALYZER.expected_candidate_contracts()
        center = ANALYZER.expected_custom_request(source, contracts["custom-center"])
        self.assertEqual(center, {"temperatureKelvin": 5_000.0, "tint": 7.5})
        corner = ANALYZER.expected_custom_request(
            source, contracts["corner-mired-plus-030-tint-minus-015"]
        )
        self.assertAlmostEqual(corner["temperatureKelvin"], 1_000_000 / 230)
        self.assertEqual(corner["tint"], -7.5)

    def test_custom_request_and_neutral_validation_fail_closed(self) -> None:
        with self.assertRaises(ANALYZER.ObservationValidationError):
            ANALYZER._require_custom_request(
                {"temperatureKelvin": 5_000, "tint": 0, "extra": 1}, "request"
            )
        with self.assertRaises(ANALYZER.ObservationValidationError):
            ANALYZER._require_neutral_values(
                {
                    "temperatureKelvin": 5_000,
                    "tint": 0,
                    "chromaticityX": 1.2,
                    "chromaticityY": 0.3,
                },
                "neutral",
            )
        for chromaticity_x, chromaticity_y in ((0, 0.3), (0.3, 0), (0.7, 0.4)):
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._require_neutral_values(
                    {
                        "temperatureKelvin": 5_000,
                        "tint": 0,
                        "chromaticityX": chromaticity_x,
                        "chromaticityY": chromaticity_y,
                    },
                    "neutral",
                )

    def test_offset_order_and_adoption_tampering_fail_closed(self) -> None:
        reordered = copy.deepcopy(self.manifest)
        reordered["candidatePlan"]["temperatureMiredOffsets"][:2] = [-60, -100]
        with self.assertRaises(ANALYZER.ObservationValidationError):
            ANALYZER.validate_manifest(reordered)

        promoted = copy.deepcopy(self.manifest)
        promoted["adoptionStatus"] = "calibrated"
        with self.assertRaises(ANALYZER.ObservationValidationError):
            ANALYZER.validate_manifest(promoted)

    def test_manifest_source_teacher_and_unknown_fields_fail_closed(self) -> None:
        variants: list[tuple[str, dict[str, object]]] = []

        missing_source = copy.deepcopy(self.manifest)
        missing_source["processing"]["sourceFiles"].pop()
        variants.append(("missing-source", missing_source))

        changed_profile = copy.deepcopy(self.manifest)
        changed_profile["scenes"][0]["teacher"]["cameraProfile"] = "Arbitrary"
        variants.append(("teacher-profile", changed_profile))

        unknown_adoption = copy.deepcopy(self.manifest)
        unknown_adoption["productionAdoptionAllowed"] = True
        variants.append(("unknown-adoption-key", unknown_adoption))

        for label, variant in variants:
            with self.subTest(label=label):
                with self.assertRaises(ANALYZER.ObservationValidationError):
                    ANALYZER.validate_manifest(variant)

    def test_manifest_is_literal_extension_of_base_calibration(self) -> None:
        ANALYZER._validate_manifest_against_base(
            self.manifest, self.base_manifest
        )

        variants: list[tuple[str, dict[str, object], dict[str, object]]] = []
        missing_base_source = copy.deepcopy(self.base_manifest)
        missing_base_source["processing"]["sourceFiles"].pop()
        variants.append(("base-source", self.manifest, missing_base_source))

        changed_scene_group = copy.deepcopy(self.manifest)
        changed_scene_group["scenes"][0]["sceneGroup"] = "different-scene"
        variants.append(("scene-group", changed_scene_group, self.base_manifest))

        changed_raw = copy.deepcopy(self.manifest)
        changed_raw["scenes"][0]["raw"]["sha256"] = "0" * 64
        variants.append(("raw", changed_raw, self.base_manifest))

        changed_reference = copy.deepcopy(self.manifest)
        changed_reference["scenes"][0]["lightroomReference"]["sha256"] = "0" * 64
        variants.append(("reference", changed_reference, self.base_manifest))

        changed_temperature = copy.deepcopy(self.manifest)
        changed_temperature["scenes"][0]["teacher"]["temperatureKelvin"] += 1
        variants.append(("teacher-temperature", changed_temperature, self.base_manifest))

        for label, manifest, base_manifest in variants:
            with self.subTest(label=label):
                with self.assertRaises(ANALYZER.ObservationValidationError):
                    ANALYZER._validate_manifest_against_base(
                        manifest, base_manifest
                    )

    def test_duplicate_keys_and_nonfinite_json_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "bad.json"
            path.write_text('{"a": 1, "a": 2}', encoding="utf-8")
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER.load_json(path)
            path.write_text('{"a": NaN}', encoding="utf-8")
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER.load_json(path)

    def test_observation_language_guard_rejects_selection_vocabulary(self) -> None:
        ANALYZER.assert_observation_language(
            {"status": "descriptive", "items": ["fixed order"]}
        )
        for value in (
            {"winner": "x"},
            {"text": "best candidate"},
            {"text": "recommended transform"},
            {"text": "learned mapping"},
        ):
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER.assert_observation_language(value)

    def test_root_escape_and_external_symlink_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sandbox = Path(temporary)
            root = sandbox / "root"
            outside = sandbox / "outside"
            root.mkdir()
            outside.write_text("private", encoding="utf-8")
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._resolve_inside(root, "../outside", "test")
            (root / "link").symlink_to(outside)
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._resolve_inside(root, "link", "test")

    def test_incomplete_sentinel_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            run_id = "123e4567-e89b-42d3-a456-426614174000"
            run_directory = (
                root / ".photobench" / "white-balance-observations" / run_id
            )
            run_directory.mkdir(parents=True)
            run_path = run_directory / "run.json"
            run_path.write_text("{}", encoding="utf-8")
            (run_directory / ".incomplete.json").write_text("{}", encoding="utf-8")
            run = self._minimal_run_header(run_id)
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._validate_run_header(root, run_path, run)

    def test_run_header_requires_canonical_identity_shape_and_time(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            run_id = "123e4567-e89b-42d3-a456-426614174000"
            run_directory = (
                root / ".photobench" / "white-balance-observations" / run_id
            )
            run_directory.mkdir(parents=True)
            run_path = run_directory / "run.json"
            run_path.write_text("{}", encoding="utf-8")
            run = self._minimal_run_header(run_id)
            self.assertEqual(
                ANALYZER._validate_run_header(root, run_path, run), run_directory
            )

            variants = []
            extra = copy.deepcopy(run)
            extra["unregistered"] = True
            variants.append(extra)
            noncanonical_id = copy.deepcopy(run)
            noncanonical_id["runID"] = run_id.upper()
            variants.append(noncanonical_id)
            reversed_time = copy.deepcopy(run)
            reversed_time["startedAtUTC"] = "2026-07-24T00:02:00Z"
            variants.append(reversed_time)
            for variant in variants:
                with self.assertRaises(ANALYZER.ObservationValidationError):
                    ANALYZER._validate_run_header(root, run_path, variant)

            alternate_path = run_directory / "alternate.json"
            alternate_path.write_text("{}", encoding="utf-8")
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._validate_run_header(root, alternate_path, run)

    def test_atomic_json_publication_never_replaces_existing_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "analysis.json"
            ANALYZER.atomic_write_json(path, {"first": 1})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"first": 1})
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER.atomic_write_json(path, {"second": 2})
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), {"first": 1})

    def test_runtime_binary_and_exiftool_are_revalidated_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            release = root / ".build" / "release"
            release.mkdir(parents=True)
            binary = release / "PhotoBenchWhiteBalanceObservation"
            binary.write_bytes(b"release-observation-binary")
            exiftool = root / "tools" / "exiftool"
            exiftool.parent.mkdir()
            exiftool.write_text("#!/bin/sh\nprintf '13.36\\n'\n", encoding="utf-8")
            exiftool.chmod(0o755)
            expected = self.manifest["expectedEnvironment"]
            runtime = {
                "macOSVersion": expected["macOSVersion"],
                "macOSBuild": expected["macOSBuild"],
                "architecture": expected["architecture"],
                "hardwareModel": expected["hardwareModel"],
                "processorCount": 10,
                "physicalMemoryBytes": 16_000_000_000,
                "thermalState": "nominal",
                "lowPowerModeEnabled": False,
                "buildConfiguration": "release",
                "coreImageFrameworkVersion": "1592.80.2",
                "executableSHA256": ANALYZER.sha256_file(binary),
                "metalDevice": {
                    "name": expected["metalDevice"],
                    "registryID": 1,
                    "hasUnifiedMemory": True,
                    "currentAllocatedSize": 0,
                    "recommendedMaxWorkingSetSize": 1,
                },
            }
            run = {
                "runtime": runtime,
                "exifTool": {
                    "path": str(exiftool),
                    "version": "13.36",
                    "sha256": ANALYZER.sha256_file(exiftool),
                },
            }
            self.assertEqual(
                ANALYZER._validate_runtime_and_tools(root, self.manifest, run),
                runtime,
            )

            tampered = copy.deepcopy(run)
            tampered["runtime"]["hardwareModel"] = "different-model"
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._validate_runtime_and_tools(root, self.manifest, tampered)

            binary.write_bytes(b"different-binary")
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._validate_runtime_and_tools(root, self.manifest, run)

            binary.write_bytes(b"release-observation-binary")
            self.assertEqual(
                ANALYZER._validate_runtime_and_tools(root, self.manifest, run),
                runtime,
            )
            exiftool.write_text(
                "#!/bin/sh\n# tampered bytes, same version\nprintf '13.36\\n'\n",
                encoding="utf-8",
            )
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._validate_runtime_and_tools(root, self.manifest, run)

    def test_private_fixture_tracked_by_git_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            subprocess.run(
                ["/usr/bin/git", "init", "--quiet", str(root)],
                check=True,
                capture_output=True,
            )
            private_path = root / "private.RW2"
            private_path.write_bytes(b"private fixture")
            subprocess.run(
                ["/usr/bin/git", "-C", str(root), "add", "private.RW2"],
                check=True,
                capture_output=True,
            )
            manifest = copy.deepcopy(self.manifest)
            manifest["scenes"][0]["raw"]["path"] = "private.RW2"
            with self.assertRaises(ANALYZER.ObservationValidationError):
                ANALYZER._validate_private_inputs_untracked(root, manifest)

    def test_verified_file_record_rejects_unknown_fields(self) -> None:
        record = {
            "role": "fixture.raw",
            "path": "fixture.RW2",
            "sha256": "a" * 64,
            "byteCount": 1,
        }
        ANALYZER._validate_verified_file_record(record, "fixture")
        record["unregistered"] = True
        with self.assertRaises(ANALYZER.ObservationValidationError):
            ANALYZER._validate_verified_file_record(record, "fixture")

    def test_analysis_runtime_is_repeatable_and_hashes_python(self) -> None:
        metrics_module = ANALYZER._load_calibration_module(ROOT)
        before = ANALYZER._capture_analysis_runtime(metrics_module)
        after = ANALYZER._capture_analysis_runtime(metrics_module)
        self.assertEqual(before, after)
        self.assertEqual(
            before["pythonExecutableSHA256"],
            ANALYZER.sha256_file(Path(before["pythonExecutable"])),
        )

    def test_decode_provenance_requires_full_resolution_profile_and_configuration(self) -> None:
        expected = self.manifest["expectedEnvironment"]
        runtime = {
            "macOSVersion": expected["macOSVersion"],
            "macOSBuild": expected["macOSBuild"],
            "architecture": expected["architecture"],
            "hardwareModel": expected["hardwareModel"],
            "coreImageFrameworkVersion": "1592.80.2",
            "metalDevice": {"name": expected["metalDevice"]},
        }
        base = {
            "rawProfile": {
                "id": "panasonic-dc-s5-lightroom-9.3-edr1-v2",
                "boostAmount": 0.9,
                "extendedDynamicRangeAmount": 1.0,
            }
        }
        artifact = {"width": 1_500, "height": 1_000}
        provenance = {
            "processingIdentifier": "core-image-raw8-intent-v2",
            "requestMode": "as-shot-untouched",
            "neutralPropertiesObserved": False,
            "intent": "full-resolution",
            "decoderVersion": "8",
            "supportedDecoderVersions": [],
            "neutralLocationPolicy": "unused",
            "appRAWCalibrationProfileID": base["rawProfile"]["id"],
            "appleCameraProfileObservability": "unavailable-in-public-api",
            "colorSpacePolicy": (
                "CIRAWFilter gamut mapping enabled; downstream extended-linear-sRGB "
                "edits; terminal sRGB output"
            ),
            "macOSVersion": expected["macOSVersion"],
            "macOSBuild": expected["macOSBuild"],
            "architecture": expected["architecture"],
            "hardwareModel": expected["hardwareModel"],
            "metalDevice": expected["metalDevice"],
            "coreImageFrameworkVersion": "1592.80.2",
            "supportedCameraModelsSHA256": "a" * 64,
            "cameraMake": "Panasonic",
            "cameraModel": "DC-S5",
            "nativeWidth": 6_000,
            "nativeHeight": 4_000,
            "outputWidth": 6_000,
            "outputHeight": 4_000,
        }
        contract = ANALYZER._validate_decode_provenance_common(
            provenance,
            artifact,
            self.manifest,
            base,
            {
                "cameraMake": "Panasonic",
                "cameraModel": "DC-S5",
                "width": 6_000,
                "height": 4_000,
            },
            runtime,
            "candidate",
        )
        self.assertEqual(contract[:2], (6_000, 4_000))
        mismatched_capture = {
            "cameraMake": "Panasonic",
            "cameraModel": "different-model",
            "width": 6_000,
            "height": 4_000,
        }
        with self.assertRaises(ANALYZER.ObservationValidationError):
            ANALYZER._validate_decode_provenance_common(
                provenance,
                artifact,
                self.manifest,
                base,
                mismatched_capture,
                runtime,
                "candidate",
            )
        configuration = {
            "exposure": 0,
            "shadowBias": 0,
            "boostAmount": 0.8999999761581421,
            "boostShadowAmount": 1,
            "extendedDynamicRangeAmount": 1,
            "scaleFactor": 1,
            "draftModeEnabled": False,
            "gamutMappingEnabled": True,
        }
        ANALYZER._validate_decode_configuration(configuration, base, "candidate")
        configuration["draftModeEnabled"] = True
        with self.assertRaises(ANALYZER.ObservationValidationError):
            ANALYZER._validate_decode_configuration(configuration, base, "candidate")


if __name__ == "__main__":
    unittest.main()
