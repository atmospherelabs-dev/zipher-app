#!/usr/bin/env python3
"""Check the resolved wallet dependencies and its stdio-only MCP contract.

From rust/: cargo metadata --locked --format-version 1 > /tmp/zipher-metadata.json
Then: python3 ../scripts/verify-dependency-security.py /tmp/zipher-metadata.json
Only the Python standard library is required. This checks build inputs, not
installed binaries, and is deliberately narrower than a full advisory audit.
"""

import json
import hashlib
import re
import sys
from pathlib import Path

RSA_VERSION = "0.10.0-rc.20"
RSA_CHECKSUM = "2389407c34c6039d7c8740520ec758090883c5b92df93a5edada2779256bf2e0"


def validate_rsa_source(package, repo_root):
    """Verify the exact published source containing upstream's November fix."""
    if package.get("version") != RSA_VERSION:
        return [f"Unreviewed RSA {package.get('version')!r}; require {RSA_VERSION}."]
    try:
        directory = Path(package["manifest_path"]).parent
        checksum_file = directory / ".cargo-checksum.json"
        if checksum_file.exists():
            checksum = json.loads(checksum_file.read_text())["package"]
        else:
            # Newer Cargo versions do not create .cargo-checksum.json for
            # registry sources. Verify the actual cached registry archive.
            archive = directory.parents[2] / "cache" / directory.parent.name / f"rsa-{RSA_VERSION}.crate"
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
        catalog = json.loads((repo_root / "rust/vendor/reviewed-rsa.json").read_text())
        if checksum != RSA_CHECKSUM or catalog["archive_sha256"] != RSA_CHECKSUM:
            return ["RSA does not match the reviewed published archive."]
        files = catalog["source_sha256"]
        if not files or not {"Cargo.toml", "src/pkcs1v15.rs", "src/private_key.rs"}.issubset(files):
            return ["RSA source integrity catalog is incomplete."]
        actual = {str(path.relative_to(directory)) for path in directory.rglob("*.rs")} | {"Cargo.toml"}
        if actual != set(files):
            return ["RSA contains unreviewed or missing source files."]
        for relative, expected in files.items():
            path = Path(relative)
            if path.is_absolute() or ".." in path.parts:
                return ["RSA source integrity catalog contains an invalid path."]
            if hashlib.sha256((directory / path).read_bytes()).hexdigest() != expected:
                return [f"Reviewed RSA source changed: {relative}."]
    except (OSError, KeyError, ValueError, TypeError):
        return ["Cannot verify the reviewed RSA source and registry checksum."]
    return []


def validate_audit(audit, rsa_verified=False):
    """Keep fresh advisory failures visible, including the stale RSA record."""
    try:
        findings = audit["vulnerabilities"]["list"]
        if not isinstance(findings, list):
            raise TypeError()
        errors = []
        for finding in findings:
            advisory = finding["advisory"]["id"]
            package = finding["package"]
            # RustSec still says patched=[] as of November 4. Source verification
            # is mandatory in validate(); never ignore every version of this CVE.
            if rsa_verified and (advisory, package["name"], package["version"]) == (
                "RUSTSEC-2023-0071", "rsa", RSA_VERSION
            ):
                continue
            errors.append(f"Unresolved advisory: {advisory} {package['name']} {package['version']}.")
        for kind, findings in audit.get("warnings", {}).items():
            if kind != "unmaintained" and findings:
                packages = ", ".join(
                    f"{finding.get('package', {}).get('name', 'unknown')} "
                    f"{finding.get('package', {}).get('version', 'unknown')}"
                    for finding in findings
                )
                errors.append(f"Unresolved audit warning category: {kind}: {packages}.")
        return errors
    except (KeyError, TypeError):
        return ["Audit input must contain a completed cargo-audit JSON report."]


def release_version(value):
    """Accept reviewed release versions, excluding prereleases."""
    if not isinstance(value, str):
        return None
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:\+[0-9A-Za-z.-]+)?", value)
    return tuple(map(int, match.groups())) if match else None


def archive_version(lock):
    """Read only archive's package block in pub's generated lockfile format."""
    block = re.search(r"^  archive:\r?\n(.*?)(?=^  \S|^\S|\Z)", lock, re.M | re.S)
    if not block:
        return None
    versions = re.findall(r"^    version: [\"']?([^\s\"']+)[\"']?\s*$", block[1], re.M)
    return versions[0] if len(versions) == 1 else None


def validate(metadata, repo_root):
    errors = []
    try:
        nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
        packages = [package for package in metadata["packages"] if package["id"] in nodes]
    except (KeyError, TypeError):
        return ["Cargo metadata must contain the resolved dependency graph; omit --no-deps."]

    for required in ("rustls", "rmcp"):
        if not any(package.get("name") == required for package in packages):
            errors.append(f"Resolved graph is missing required {required}.")

    adapted = {"ows-signer", "ows-lib", "tor-llcrypto", "tor-key-forge", "tor-keymgr", "ssh-key"}
    resolved_adapters = [package for package in packages if package.get("name") in adapted]
    if resolved_adapters:
        try:
            vendor = repo_root / "rust/vendor"
            records = {item["name"]: item for item in json.loads((vendor / "security-adapters.json").read_text())["adapters"]}
            for package in resolved_adapters:
                name = package["name"]
                record = records[name]
                directory = vendor / name
                if (directory / "Cargo.lock").exists():
                    errors.append(f"Unexpected standalone {name} lockfile; rust/Cargo.lock is authoritative.")
                actual = {str(path.relative_to(directory)) for path in directory.rglob("*.rs")} | {"Cargo.toml"}
                if actual != set(record["source_sha256"]):
                    errors.append(f"{name} contains unreviewed or missing source files.")
                if (Path(package["manifest_path"]).resolve() != (directory / "Cargo.toml").resolve()
                        or package["version"] != record["version"]):
                    errors.append(f"{name} must use the reviewed security adapter.")
                if hashlib.sha256((vendor / record["patch"]).read_bytes()).hexdigest() != record["patch_sha256"]:
                    errors.append(f"Reviewed {name} compatibility patch changed.")
                for relative, expected in record["source_sha256"].items():
                    if hashlib.sha256((directory / relative).read_bytes()).hexdigest() != expected:
                        errors.append(f"Reviewed adapter source changed: {name}/{relative}.")
        except (OSError, KeyError, ValueError, TypeError):
            errors.append("Cannot verify the reviewed crypto compatibility adapters.")

    bounds = {
        "rustls": ((0, 23, 46), (0, 24, 0)),
        "rmcp": ((1, 8, 0), (2, 0, 0)),
        "zip": ((9, 0, 0), None),
        "crypto-bigint": ((0, 7, 10), (0, 8, 0)),
    }
    for package in packages:
        name = package.get("name")
        if name == "rsa":
            errors.extend(validate_rsa_source(package, repo_root))
        if name not in bounds:
            continue
        raw_version = package.get("version", "")
        version = release_version(raw_version)
        floor, ceiling = bounds[name]
        if version is None or version < floor or (ceiling is not None and version >= ceiling):
            expected = ">=" + ".".join(map(str, floor))
            if ceiling is not None:
                expected += ", <" + ".".join(map(str, ceiling))
            errors.append(f"Unreviewed {name} {raw_version!r}; require release {expected}.")
        if name == "rmcp":
            features = nodes[package["id"]].get("features")
            if not isinstance(features, list) or not all(isinstance(feature, str) for feature in features):
                errors.append("Resolved rmcp feature list is missing or invalid.")
            elif any(feature == "server-side-http" or feature.startswith("transport-streamable-http-server")
                     for feature in features):
                errors.append("rmcp HTTP server transport is enabled; Zipher MCP must remain stdio-only.")

    try:
        raw_archive = archive_version((repo_root / "pubspec.lock").read_text())
    except OSError:
        raw_archive = None
    version = release_version(raw_archive) if raw_archive is not None else None
    if version is None or not (4, 5, 2) <= version < (5, 0, 0):
        errors.append(f"Unreviewed Dart archive {raw_archive!r}; require release >=4.5.2, <5.0.0.")

    for obsolete in ("Cargo.toml", "Cargo.lock"):
        if (repo_root / obsolete).exists():
            errors.append(f"Obsolete root {obsolete} is present; rust/ is the authoritative Cargo workspace.")
    return errors


def main(argv):
    if len(argv) not in (2, 3):
        sys.exit(f"Usage: {Path(argv[0]).name} cargo-metadata.json [cargo-audit.json]")
    try:
        metadata = json.loads(Path(argv[1]).read_text())
    except (OSError, ValueError) as error:
        sys.exit(f"Cannot read Cargo metadata: {error}")
    errors = validate(metadata, Path(__file__).resolve().parent.parent)
    if len(argv) == 3:
        try:
            active = {node["id"] for node in metadata["resolve"]["nodes"]}
            rsa_verified = any(
                package["name"] == "rsa" and package["id"] in active
                and not validate_rsa_source(package, Path(__file__).resolve().parent.parent)
                for package in metadata["packages"]
            )
            audit = json.loads(Path(argv[2]).read_text())
            errors.extend(validate_audit(audit, rsa_verified=rsa_verified))
        except (OSError, ValueError, KeyError, TypeError) as error:
            errors.append(f"Cannot read fresh audit report: {error}")
    if errors:
        sys.exit("\n".join(errors))
    if len(argv) == 3 and audit["vulnerabilities"]["list"]:
        print("RustSec still lists RSA's older advisory as unpatched; the exact published November fix, source hashes and registry checksum were verified.")
    print("Verified reviewed rustls/rmcp/archive versions, safe optional Rust zip, stdio-only MCP, and the authoritative rust/ workspace.")


if __name__ == "__main__":
    main(sys.argv)
