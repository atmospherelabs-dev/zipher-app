#!/usr/bin/env python3
"""Check `cargo metadata --locked --format-version 1` JSON for one crypto family."""
import json
import sys
from pathlib import Path

metadata = json.loads(Path(sys.argv[1]).read_text())
active = {node["id"] for node in metadata["resolve"]["nodes"]}
packages = [p for p in metadata["packages"] if p["id"] in active]
forked = {
    "orchard", "sapling-crypto", "zcash_keys", "zcash_primitives", "zcash_proofs",
    "pasta_curves", "reddsa", "redjubjub", "jubjub", "bls12_381", "bellman",
    "halo2_proofs", "halo2_gadgets", "halo2_poseidon", "sinsemilla", "pairing",
}
errors = []
for package in packages:
    name = package["name"]
    if name in forked:
        errors.append(f"Upstream crypto family leaked into the graph: {name}")
    if name.startswith("zakura-") and package["version"] != "1.2.0":
        errors.append(f"Unexpected Zakura version: {name} {package['version']}")

for name, version in {
    "zcash_client_backend": "0.24.0", "zcash_client_sqlite": "0.22.0",
    "zcash_pool_migration": "0.1.0", "pczt": "0.9.3", "zcash_protocol": "0.10.6",
    "zipher-cli": "0.3.0", "zipher-mcp-server": "0.3.0",
}.items():
    matches = [p for p in packages if p["name"] == name]
    if len(matches) != 1 or matches[0]["version"] != version:
        errors.append(f"Expected exactly one {name} {version}")

if not any(p['name'] == 'zakura-orchard' for p in packages):
    errors.append('Zakura is absent')

vendor = Path(__file__).resolve().parent.parent / 'rust' / 'vendor'
for name in ('zcash_client_backend', 'zcash_client_sqlite', 'zcash_pool_migration', 'pczt'):
    for package in packages:
        if package['name'] == name and Path(package['manifest_path']).resolve() != vendor / name / 'Cargo.toml':
            errors.append(f'{name} must use the reviewed local compatibility patch')
if errors:
    sys.exit("\n".join(errors))
print("Verified one Zakura Common 1.2.0 crypto family and the stable wallet SDK.")
