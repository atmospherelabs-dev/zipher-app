"""Regression tests for the dependency security gate, without Cargo or network."""

import copy
import hashlib
import json
import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "dependency_security", Path(__file__).resolve().parents[1] / "verify-dependency-security.py"
)
GUARD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARD)


def graph():
    packages = [
        {"id": "rustls@0.23.46", "name": "rustls", "version": "0.23.46"},
        {"id": "rmcp@1.8.0", "name": "rmcp", "version": "1.8.0"},
    ]
    return {
        "packages": packages,
        "resolve": {"nodes": [
            {"id": package["id"], "features": ["server", "transport-io"] if package["name"] == "rmcp" else []}
            for package in packages
        ]},
    }


class DependencySecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.metadata = graph()
        self.write_archive("4.5.2")

    def write_archive(self, version):
        (self.root / "pubspec.lock").write_text(
            'packages:\n  archive:\n    dependency: transitive\n'
            f'    version: "{version}"\n  args:\n    version: "9.0.0"\n'
        )

    def check(self):
        return GUARD.validate(self.metadata, self.root)

    def test_accepts_reviewed_graph(self):
        self.assertEqual(self.check(), [])

    def test_rejects_old_rustls_even_when_safe_version_also_resolves(self):
        self.metadata["packages"].append({"id": "old-rustls", "name": "rustls", "version": "0.23.37"})
        self.metadata["resolve"]["nodes"].append({"id": "old-rustls", "features": []})
        self.assertTrue(any("rustls '0.23.37'" in error for error in self.check()))

    def test_rejects_old_rmcp(self):
        self.metadata["packages"][1]["version"] = "1.3.0"
        self.assertTrue(any("rmcp '1.3.0'" in error for error in self.check()))

    def test_rejects_http_feature_on_matching_rmcp_node_only(self):
        self.metadata["resolve"]["nodes"][0]["features"] = ["transport-streamable-http-server"]
        self.assertEqual(self.check(), [])
        self.metadata["resolve"]["nodes"][1]["features"] += ["transport-streamable-http-server"]
        self.assertTrue(any("stdio-only" in error for error in self.check()))

    def test_rejects_missing_rmcp_features(self):
        del self.metadata["resolve"]["nodes"][1]["features"]
        self.assertTrue(any("feature list" in error for error in self.check()))

    def test_optional_rust_zip_must_be_patched(self):
        self.metadata["packages"].append({"id": "zip", "name": "zip", "version": "8.6.0"})
        self.metadata["resolve"]["nodes"].append({"id": "zip", "features": []})
        self.assertTrue(any("zip '8.6.0'" in error for error in self.check()))
        self.metadata["packages"][-1]["version"] = "9.0.0"
        self.assertEqual(self.check(), [])

    def test_rejects_old_archive_and_prerelease(self):
        for version in ("4.0.7", "4.5.1", "4.5.2-rc.1", "5.0.0"):
            with self.subTest(version=version):
                self.write_archive(version)
                self.assertTrue(any("Dart archive" in error for error in self.check()))

    def test_does_not_take_archive_version_from_neighbor_package(self):
        (self.root / "pubspec.lock").write_text('packages:\n  archive:\n    dependency: transitive\n  args:\n    version: "4.5.2"\n')
        self.assertTrue(any("Dart archive" in error for error in self.check()))

    def test_requires_resolved_dependencies(self):
        self.metadata["resolve"]["nodes"] = []
        self.assertTrue(any("required rustls" in error for error in self.check()))
        self.assertTrue(any("required rmcp" in error for error in self.check()))
        self.metadata.pop("resolve")
        self.assertTrue(any("resolved dependency graph" in error for error in self.check()))

    def test_rejects_obsolete_root_workspace_or_lock(self):
        for name in ("Cargo.toml", "Cargo.lock"):
            with self.subTest(name=name):
                (self.root / name).touch()
                self.assertTrue(any(f"root {name}" in error for error in self.check()))
                (self.root / name).unlink()

    def test_rejects_unreviewed_dependency_major(self):
        metadata = copy.deepcopy(self.metadata)
        for index, version in ((0, "0.24.0"), (1, "2.0.0")):
            with self.subTest(version=version):
                self.metadata = copy.deepcopy(metadata)
                self.metadata["packages"][index]["version"] = version
                self.assertTrue(self.check())

    def test_rejects_old_bigint_even_with_a_fixed_copy(self):
        for version in ("0.7.10", "0.5.5"):
            self.metadata["packages"].append({"id": version, "name": "crypto-bigint", "version": version})
            self.metadata["resolve"]["nodes"].append({"id": version, "features": []})
        self.assertTrue(any("crypto-bigint '0.5.5'" in error for error in self.check()))

    def test_rsa_requires_the_reviewed_source_and_detects_corruption(self):
        directory = self.root / "rsa"
        (directory / "src").mkdir(parents=True)
        (self.root / "rust/vendor").mkdir(parents=True)
        files = {"Cargo.toml": b"reviewed features", "src/pkcs1v15.rs": b"reviewed padding", "src/private_key.rs": b"reviewed blinding"}
        for relative, content in files.items():
            (directory / relative).write_bytes(content)
        (directory / ".cargo-checksum.json").write_text(json.dumps({"package": GUARD.RSA_CHECKSUM}))
        (self.root / "rust/vendor/reviewed-rsa.json").write_text(json.dumps({
            "archive_sha256": GUARD.RSA_CHECKSUM,
            "source_sha256": {name: hashlib.sha256(value).hexdigest() for name, value in files.items()},
        }))
        package = {"name": "rsa", "version": GUARD.RSA_VERSION, "manifest_path": str(directory / "Cargo.toml")}
        self.assertEqual(GUARD.validate_rsa_source(package, self.root), [])
        (directory / "src/pkcs1v15.rs").write_text("changed source")
        self.assertTrue(GUARD.validate_rsa_source(package, self.root))
        package["version"] = "0.9.10"
        self.assertTrue(GUARD.validate_rsa_source(package, self.root))

    def test_audit_exception_requires_verified_exact_rsa_source(self):
        audit = {"vulnerabilities": {"list": [{
            "advisory": {"id": "RUSTSEC-2023-0071"},
            "package": {"name": "rsa", "version": GUARD.RSA_VERSION},
        }]}}
        self.assertTrue(GUARD.validate_audit(audit))
        self.assertEqual(GUARD.validate_audit(audit, rsa_verified=True), [])
        audit["vulnerabilities"]["list"][0]["package"]["version"] = "0.9.10"
        self.assertTrue(GUARD.validate_audit(audit, rsa_verified=True))

    def test_fresh_audit_blocks_new_findings_and_unsound_warnings(self):
        self.assertTrue(GUARD.validate_audit({"error": "database unavailable"}))
        audit = {"vulnerabilities": {"list": []}, "warnings": {"unsound": [{}]}}
        self.assertTrue(GUARD.validate_audit(audit))
        audit["warnings"] = {"yanked": [{"package": {"name": "chacha20", "version": "0.10.1"}}]}
        self.assertIn("yanked: chacha20 0.10.1", GUARD.validate_audit(audit)[0])
        audit = {"vulnerabilities": {"list": [{"advisory": {"id": "NEW"},
                 "package": {"name": "other", "version": "1.0.0"}}]}}
        self.assertTrue(GUARD.validate_audit(audit, rsa_verified=True))

    def test_adapter_gate_detects_extra_source_and_stale_lockfiles(self):
        vendor = self.root / "rust/vendor"
        directory = vendor / "ows-signer"
        directory.mkdir(parents=True)
        manifest = directory / "Cargo.toml"
        manifest.write_text("reviewed adapter")
        patch = vendor / "adapter.patch"
        patch.write_text("reviewed patch")
        (vendor / "security-adapters.json").write_text(json.dumps({"adapters": [{
            "name": "ows-signer", "version": "1.0.0", "patch": "adapter.patch",
            "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
            "source_sha256": {"Cargo.toml": hashlib.sha256(manifest.read_bytes()).hexdigest()},
        }]}))
        self.metadata["packages"].append({"id": "adapter", "name": "ows-signer",
            "version": "1.0.0", "manifest_path": str(manifest)})
        self.metadata["resolve"]["nodes"].append({"id": "adapter", "features": []})
        self.assertEqual(self.check(), [])
        (directory / "build.rs").write_text("unreviewed")
        self.assertTrue(any("unreviewed" in error for error in self.check()))
        (directory / "build.rs").unlink()
        (directory / "Cargo.lock").touch()
        self.assertTrue(any("standalone" in error for error in self.check()))


if __name__ == "__main__":
    unittest.main()
