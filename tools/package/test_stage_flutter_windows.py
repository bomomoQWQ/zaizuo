"""纯本地假 Release 回归；不调用 Flutter/Git/网络，不读取真实运行目录。

python -B -m unittest discover -s tools/package -p test_stage_flutter_windows.py -v
"""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "stage_flutter_windows", Path(__file__).with_name("stage-flutter-windows.py"))
pack = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pack)
REF = "a" * 40


class StageFlutterWindowsTest(unittest.TestCase):
    def setUp(self):
        # 不默认写入 APPDATA / 用户 Temp；fixture 只在项目隔离 .local 内。
        self.base = pack.absolute(Path(__file__).parents[2] / ".local")
        pack.checked(self.base, directory=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="stage-fixture-", dir=self.base)
        self.root = pack.absolute(Path(self.temporary.name))
        self.assertEqual(self.root.parent, self.base)
        self.assertTrue(self.root.name.startswith("stage-fixture-"))
        self.release = self.root / pack.RELEASE
        self.release.mkdir(parents=True)
        for name in pack.RUNTIME_FILES:
            self.put(self.release / name, b"fake-runtime-" + name.encode("ascii"))
        self.put(self.release / "data/app.so", b"current-fake-aot-ui-test9")
        self.put(self.release / "data/icudtl.dat", b"fake-icu")
        self.put(self.release / "data/flutter_assets/AssetManifest.bin", b"fake-manifest")
        self.put(self.release / "data/flutter_assets/assets/hello.txt", b"fake-asset")
        self.put(self.release / "data/flutter_assets" / Path(*pack.PUBLIC_CA),
                 b"-----BEGIN CERTIFICATE-----\nfake-public-ca\n-----END CERTIFICATE-----\n")
        self.put(self.release / "data/flutter_assets/empty-asset", b"")
        for source in pack.DOCUMENTS:
            self.put(self.root / source, b"fake-notice")
        self.put(self.root / ".local/flutter/bin/cache/artifacts/engine/windows-x64/LICENSE.windows_flutter.md",
                 b"fake-release-flutter-license")
        # 诱饵不进入 pack allowlist；不含真实资料。
        self.put(self.release / "zaizuo-data/profile/NEVER-COPY.txt", b"fake-private-marker")
        self.put(self.release / "git-credentials/NEVER-COPY.txt", b"fake-secret-marker")

    def tearDown(self):
        pack.checked(self.root, directory=True)
        self.assertEqual(self.root.parent, self.base)
        self.assertTrue(self.root.name.startswith("stage-fixture-"))
        self.temporary.cleanup()

    @staticmethod
    def put(path: Path, data: bytes):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def build(self):
        result = pack.stage_windows(self.root, "ui-test9", "ui-test9", REF)
        return result, self.root / result["stage"], self.root / result["archive"]

    def verification_inputs(self, stage):
        sources = pack.collect_sources(self.root)
        build = json.loads((stage / "BUILD.json").read_text(encoding="utf-8"))
        copied = {name: record["sha256"] for name, record in build["copied_files"].items()}
        return sources, copied

    def test_exact_source_stage_zip_and_checksums_without_user_dirs(self):
        result, stage, archive = self.build()
        self.assertEqual(result["app_so_sha256"], pack.file_hash(self.release / "data/app.so"))
        sources, copied = self.verification_inputs(stage)
        verified = pack.verify_package(stage, archive, sources, copied)
        self.assertEqual(result["verified_file_count"], len(verified))
        self.assertIn("data/app.so", verified)
        self.assertIn("LICENSE.windows_flutter.md", verified)
        self.assertIn("TESTING.md", verified)
        self.assertIn("SELF-TEST.md", verified)
        self.assertFalse(any("zaizuo-data" in n or "git-credentials" in n for n in verified))
        with zipfile.ZipFile(archive) as bundle:
            self.assertEqual(len(bundle.infolist()), len(verified))
            self.assertEqual(bundle.read(f"{stage.name}/data/app.so"), b"current-fake-aot-ui-test9")
        manifest = (stage / "SHA256SUMS").read_text(encoding="utf-8")
        self.assertNotIn("  SHA256SUMS\n", manifest)
        build = json.loads((stage / "BUILD.json").read_text(encoding="utf-8"))
        self.assertFalse(build["compilation_performed"])
        self.assertEqual(build["source_ref"], REF)
        self.assertNotIn(str(self.root), json.dumps(build))
        self.assertEqual((archive.parent / (archive.name + ".sha256")).read_text(),
                         f"{pack.file_hash(archive)}  {archive.name}\n")
        self.assertFalse(any(p.name.startswith(f".{stage.name}-verify-") for p in stage.parent.iterdir()))

    def test_existing_stage_archive_or_digest_refuses_without_overwrite(self):
        output = self.root / "dist/packages"
        output.mkdir(parents=True)
        name = "zaizuo-client-ui-test9-windows-x64"
        for suffix in ("", ".zip", ".zip.sha256"):
            with self.subTest(suffix=suffix):
                target = output / (name + suffix)
                self.put(target, b"keep-existing")
                try:
                    with self.assertRaisesRegex(pack.PackagingError, "output_already_exists"):
                        self.build()
                    self.assertEqual(target.read_bytes(), b"keep-existing")
                finally:
                    # 此 target 是刚创建的 fixture 文件，绝对位置已经核查。
                    self.assertEqual(target.parent, output)
                    target.unlink()

    def test_source_tamper_is_detected(self):
        _, stage, archive = self.build()
        sources, copied = self.verification_inputs(stage)
        self.put(self.release / "data/app.so", b"another-aot")
        with self.assertRaisesRegex(pack.PackagingError, "source_hash_mismatch"):
            pack.verify_package(stage, archive, sources, copied)

    def test_stage_tamper_is_detected(self):
        _, stage, archive = self.build()
        sources, copied = self.verification_inputs(stage)
        self.put(stage / "data/app.so", b"stale-aot")
        with self.assertRaisesRegex(pack.PackagingError, "stage_hash_mismatch"):
            pack.verify_package(stage, archive, sources, copied)

    def test_archive_tamper_is_detected(self):
        _, stage, archive = self.build()
        sources, copied = self.verification_inputs(stage)
        with zipfile.ZipFile(archive) as bundle:
            entries = {i.filename: bundle.read(i) for i in bundle.infolist()}
        member = f"{stage.name}/data/app.so"
        entries[member] = b"x" * len(entries[member])
        # 仅改本测试已创建的假 archive，不触及已有真实包。
        with zipfile.ZipFile(archive, "w") as bundle:
            for name, data in entries.items():
                bundle.writestr(name, data)
        with self.assertRaisesRegex(pack.PackagingError, "archive_hash_mismatch"):
            pack.verify_package(stage, archive, sources, copied)

    def test_archive_extra_entry_or_traversal_is_rejected(self):
        _, stage, archive = self.build()
        sources, copied = self.verification_inputs(stage)
        with zipfile.ZipFile(archive, "a") as bundle:
            bundle.writestr("../outside.txt", b"never-extract")
        with self.assertRaisesRegex(pack.PackagingError, "archive_file_set_mismatch"):
            pack.verify_package(stage, archive, sources, copied)
        self.assertFalse((self.root / "outside.txt").exists())

    def test_secret_name_in_assets_is_rejected_before_stage(self):
        self.put(self.release / "data/flutter_assets/profile/private.txt", b"fake")
        with self.assertRaisesRegex(pack.PackagingError, "private_material_name_forbidden"):
            self.build()
        self.assertFalse((self.root / "dist").exists())

    def test_public_ca_cannot_contain_private_pem(self):
        self.put(self.release / "data/flutter_assets" / Path(*pack.PUBLIC_CA),
                 b"-----BEGIN CERTIFICATE-----\nfake\n-----BEGIN PRIVATE KEY-----\n")
        with self.assertRaisesRegex(pack.PackagingError, "public_ca_invalid"):
            self.build()
        self.assertFalse((self.root / "dist").exists())

    def test_output_symlink_is_rejected_without_writing_its_target(self):
        target = self.root / "link-target"
        target.mkdir()
        link = self.root / "dist"
        try:
            os.symlink(target, link, target_is_directory=True)
        except (OSError, NotImplementedError):
            self.skipTest("fixture host does not permit symlink creation")
        try:
            with self.assertRaisesRegex(pack.PackagingError, "links_or_reparse_points_forbidden"):
                self.build()
            self.assertEqual(list(target.iterdir()), [])
        finally:
            self.assertEqual(link.parent, self.root)
            link.unlink()

    def test_unexpected_binary_or_data_entry_is_rejected(self):
        binary = self.release / "unexpected.dll"
        self.put(binary, b"fake")
        with self.assertRaisesRegex(pack.PackagingError, "unsupported_runtime_binary"):
            self.build()
        self.assertEqual(binary.parent, self.release)
        binary.unlink()
        self.put(self.release / "data/profile/private.txt", b"fake")
        with self.assertRaisesRegex(pack.PackagingError, "unexpected_data_entry"):
            self.build()

    def test_required_runtime_and_release_license_are_mandatory(self):
        runtime = self.release / "libgit2.dll"
        self.assertEqual(runtime.parent, self.release)
        runtime.unlink()
        with self.assertRaisesRegex(pack.PackagingError, "required_input_missing"):
            self.build()
        self.put(runtime, b"fake")
        notice = self.root / ".local/flutter/bin/cache/artifacts/engine/windows-x64/LICENSE.windows_flutter.md"
        self.assertTrue(notice.is_relative_to(self.root))
        notice.unlink()
        self.put(notice.parent.parent / "windows-x64-debug/LICENSE.windows_flutter.md", b"debug-only")
        with self.assertRaisesRegex(pack.PackagingError, "flutter_release_license_missing"):
            self.build()

    def test_symlink_is_rejected(self):
        link = self.release / "data/flutter_assets/linked.txt"
        try:
            os.symlink(self.release / "data/app.so", link)
        except (OSError, NotImplementedError):
            self.skipTest("fixture host does not permit symlink creation")
        with self.assertRaisesRegex(pack.PackagingError, "links_or_reparse_points_forbidden"):
            self.build()

    def test_invalid_version_or_ref_fails_before_output(self):
        for version, reference in (("../escape", REF), ("ui-test9", "HEAD"),
                                   ("ui-test9", "a" * 7)):
            with self.subTest(version=version, reference=reference):
                with self.assertRaises(pack.PackagingError):
                    pack.stage_windows(self.root, version, "ui-test9", reference)
        self.assertFalse((self.root / "dist").exists())

    def test_cli_reports_only_safe_relative_outputs_and_codes(self):
        stdout, stderr = io.StringIO(), io.StringIO()
        args = ["--project-root", str(self.root), "--version", "ui-test9",
                "--build-label", "ui-test9", "--source-ref", REF]
        with redirect_stdout(stdout), redirect_stderr(stderr):
            code = pack.main(args)
        self.assertEqual(code, 0)
        self.assertEqual(stderr.getvalue(), "")
        self.assertNotIn(str(self.root), stdout.getvalue())
        result = json.loads(stdout.getvalue())
        self.assertTrue(result["archive"].startswith("dist/packages/"))
        with redirect_stdout(io.StringIO()), redirect_stderr(stderr):
            code = pack.main(args)
        self.assertEqual(code, 1)
        self.assertIn("packaging_failed: output_already_exists", stderr.getvalue())
        self.assertNotIn(str(self.root), stderr.getvalue())

    def test_explicit_source_ref_does_not_spawn_git(self):
        with patch.object(pack.subprocess, "run", side_effect=AssertionError("must not call git")):
            self.build()


if __name__ == "__main__":
    unittest.main()
