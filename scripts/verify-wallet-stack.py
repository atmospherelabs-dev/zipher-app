#!/usr/bin/env python3
"""Verify the active wallet graph, real NU7 protocol source, and migration-store retention.

Run against `cargo metadata --locked --format-version 1` output. This verifies
build inputs; the engine's schedule/boundary tests verify their runtime behavior.
"""
import json
import re
import sys
from pathlib import Path

metadata = json.loads(Path(sys.argv[1]).read_text())
active = {node['id'] for node in metadata['resolve']['nodes']}
packages = [p for p in metadata['packages'] if p['id'] in active]
forked = {
    'orchard', 'sapling-crypto', 'zcash_keys', 'zcash_primitives', 'zcash_proofs',
    'pasta_curves', 'reddsa', 'redjubjub', 'jubjub', 'bls12_381', 'bellman',
    'halo2_proofs', 'halo2_gadgets', 'halo2_poseidon', 'sinsemilla', 'pairing',
    'zcash_protocol', 'zcash_address', 'zcash_transparent', 'zcash_note_encryption',
    'zip321',
}
errors = []
for package in packages:
    name = package['name']
    if name in forked:
        errors.append(f'Upstream crypto family leaked into the graph: {name}')
    expected = '0.1.0-rc9' if name == 'zakura-pczt' else '4.0.0'
    if name.startswith('zakura-') and package['version'] != expected:
        errors.append(f"Unexpected Zakura version: {name} {package['version']}")

expected_versions = {
    'zcash_client_backend': '0.24.0', 'zcash_client_sqlite': '0.22.0',
    'zcash_pool_migration': '0.2.0', 'zakura-pczt': '0.1.0-rc9',
    'zakura-protocol': '4.0.0', 'zakura-orchard': '4.0.0',
    'zipher-cli': '0.3.1-rc.1', 'zipher-mcp-server': '0.3.1-rc.1',
}
for name, version in expected_versions.items():
    matches = [p for p in packages if p['name'] == name]
    if len(matches) != 1 or matches[0]['version'] != version:
        errors.append(f'Expected exactly one {name} {version}')

vendor = Path(__file__).resolve().parent.parent / 'rust' / 'vendor'
for name in ('zcash_client_backend', 'zcash_client_sqlite', 'zcash_pool_migration'):
    for package in packages:
        if package['name'] == name and Path(package['manifest_path']).resolve() != vendor / name / 'Cargo.toml':
            errors.append(f'{name} must use the reviewed local compatibility patch')

# Inspect the resolved protocol, never an unrelated checkout or transitive old
# copy. Reject the former placeholder branch and unscheduled mainnet/testnet.
protocols = [p for p in packages if p['name'] == 'zakura-protocol']
if len(protocols) == 1:
    source = Path(protocols[0]['manifest_path']).parent / 'src' / 'consensus.rs'
    consensus = source.read_text()
    compact = re.sub(r'\s|_', '', consensus).lower()
    for fragment, label in [
        ('networkupgrade::nu7=>some(blockheight(3543405))', 'mainnet activation'),
        ('networkupgrade::nu7=>some(blockheight(4465026))', 'testnet activation'),
        ('constnu7branchid:u32=0x77190ad9;', 'NU7 consensus branch'),
        ('branchid::nu7=>nu7branchid', 'branch encoding'),
    ]:
        if fragment not in compact:
            errors.append(f'Resolved protocol lacks the reviewed {label}')

registered = (vendor / 'zcash_client_sqlite/src/wallet/init/migrations.rs').read_text()
if 'drop_zip318_pool_migration' in registered:
    errors.append('The active SQLite migration graph would discard ZIP 318 migration state')
if not (vendor / 'zcash_client_sqlite/src/pool_migration/orchard_ironwood.rs').is_file():
    errors.append('The typed Orchard-to-Ironwood migration store is absent')
service = (vendor / 'zcash_client_backend/src/proto/service.rs').read_text()
if not all(token in service for token in ['pub struct StandardFee', 'pub fee_zat: u64', 'pub estimator_version: u32', 'pub async fn get_standard_fee(', '/cash.z.wallet.sdk.rpc.CompactTxStreamer/GetStandardFee']):
    errors.append('Released lightwallet-protocol StandardFee relay is missing or incompatible')
if errors:
    sys.exit('\n'.join(errors))
print('Verified one Common 4.0.0 crypto family, published PCZT rc9, real NU7 activations/branch, StandardFee relay, and retained stable migration store.')
