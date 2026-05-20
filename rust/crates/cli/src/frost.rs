use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;

use crate::{print_ok, Config};

#[derive(Serialize)]
struct FrostSelfTestResult {
    threshold: String,
    group_public_key_hex: String,
    signature_hex: String,
}

fn pkg(id: u16, package: &str) -> (u16, String) {
    (id, package.to_string())
}

pub async fn cmd_frost_self_test(cfg: &Config) -> Result<()> {
    let p1 = zipher_engine::frost::frost_dkg_init(1, 3, 2)?;
    let p2 = zipher_engine::frost::frost_dkg_init(2, 3, 2)?;
    let p3 = zipher_engine::frost::frost_dkg_init(3, 3, 2)?;

    let r2_1 = zipher_engine::frost::frost_dkg_round2(
        p1.secret_package,
        BTreeMap::from([
            pkg(2, &p2.round1_package),
            pkg(3, &p3.round1_package),
        ]),
    )?;
    let r2_2 = zipher_engine::frost::frost_dkg_round2(
        p2.secret_package,
        BTreeMap::from([
            pkg(1, &p1.round1_package),
            pkg(3, &p3.round1_package),
        ]),
    )?;
    let r2_3 = zipher_engine::frost::frost_dkg_round2(
        p3.secret_package,
        BTreeMap::from([
            pkg(1, &p1.round1_package),
            pkg(2, &p2.round1_package),
        ]),
    )?;

    let c1 = zipher_engine::frost::frost_dkg_round3(
        r2_1.secret_package,
        BTreeMap::from([
            pkg(2, &p2.round1_package),
            pkg(3, &p3.round1_package),
        ]),
        BTreeMap::from([
            pkg(2, r2_2.round2_packages.get(&1).unwrap()),
            pkg(3, r2_3.round2_packages.get(&1).unwrap()),
        ]),
    )?;
    let c2 = zipher_engine::frost::frost_dkg_round3(
        r2_2.secret_package,
        BTreeMap::from([
            pkg(1, &p1.round1_package),
            pkg(3, &p3.round1_package),
        ]),
        BTreeMap::from([
            pkg(1, r2_1.round2_packages.get(&2).unwrap()),
            pkg(3, r2_3.round2_packages.get(&2).unwrap()),
        ]),
    )?;

    let s1 = zipher_engine::frost::frost_sign_round1(c1.key_package.clone())?;
    let s2 = zipher_engine::frost::frost_sign_round1(c2.key_package.clone())?;
    let signing_package = zipher_engine::frost::frost_create_signing_package(
        "ab".repeat(32),
        BTreeMap::from([
            (1, s1.signing_commitments.clone()),
            (2, s2.signing_commitments.clone()),
        ]),
    )?;
    let randomizer =
        zipher_engine::frost::frost_create_randomizer(c1.public_key_package.clone())?;

    let share1 = zipher_engine::frost::frost_sign_round2(
        signing_package.clone(),
        s1.signing_nonces,
        c1.key_package,
        randomizer.randomizer_point_hex.clone(),
    )?;
    let share2 = zipher_engine::frost::frost_sign_round2(
        signing_package.clone(),
        s2.signing_nonces,
        c2.key_package,
        randomizer.randomizer_point_hex,
    )?;
    let sig = zipher_engine::frost::frost_aggregate(
        signing_package,
        BTreeMap::from([(1, share1), (2, share2)]),
        c1.public_key_package,
        randomizer.randomizer_hex,
    )?;

    let out = FrostSelfTestResult {
        threshold: "2 of 3".to_string(),
        group_public_key_hex: c1.group_public_key_hex,
        signature_hex: sig.signature_hex,
    };
    print_ok(out, cfg.human, |r| {
        println!("FROST self-test OK");
        println!("threshold: {}", r.threshold);
        println!("group public key: {}", r.group_public_key_hex);
        println!("signature: {}", r.signature_hex);
    });
    Ok(())
}
