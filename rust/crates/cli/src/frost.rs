use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;

use crate::{ensure_data_dir, print_ok, Config};
use crate::helpers::auto_open;

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
    let (c1, c2, _) = local_2_of_3_dkg()?;

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

fn local_2_of_3_dkg() -> Result<(
    zipher_engine::frost::FrostDkgCompleteResult,
    zipher_engine::frost::FrostDkgCompleteResult,
    zipher_engine::frost::FrostDkgCompleteResult,
)> {
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
    let c3 = zipher_engine::frost::frost_dkg_round3(
        r2_3.secret_package,
        BTreeMap::from([
            pkg(1, &p1.round1_package),
            pkg(2, &p2.round1_package),
        ]),
        BTreeMap::from([
            pkg(1, r2_1.round2_packages.get(&3).unwrap()),
            pkg(2, r2_2.round2_packages.get(&3).unwrap()),
        ]),
    )?;

    Ok((c1, c2, c3))
}

#[derive(Serialize)]
struct FrostWalletCreateResult {
    threshold: String,
    group_public_key_hex: String,
    ufvk: String,
    address: String,
    data_dir: String,
    public_key_package: String,
    participant_1_key_package: String,
    participant_2_key_package: String,
    participant_3_key_package: String,
}

pub async fn cmd_frost_wallet_create(cfg: &Config, birthday: u32) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    crate::helpers::ensure_sapling_params(&cfg.data_dir).await?;

    let (c1, c2, c3) = local_2_of_3_dkg()?;
    let view = zipher_engine::frost::frost_create_view_from_group_key(
        c1.group_public_key_hex.clone(),
        cfg.network,
    )?;

    zipher_engine::wallet::restore_from_ufvk(
        &cfg.data_dir,
        &cfg.server_url,
        cfg.network,
        &view.ufvk,
        birthday,
        None,
    )
    .await?;
    zipher_engine::wallet::close().await;

    let out = FrostWalletCreateResult {
        threshold: "2 of 3".to_string(),
        group_public_key_hex: c1.group_public_key_hex,
        ufvk: view.ufvk,
        address: view.address,
        data_dir: cfg.data_dir.clone(),
        public_key_package: c1.public_key_package,
        participant_1_key_package: c1.key_package,
        participant_2_key_package: c2.key_package,
        participant_3_key_package: c3.key_package,
    };
    print_ok(out, cfg.human, |r| {
        println!("FROST wallet created/imported as watch-only.");
        println!("threshold: {}", r.threshold);
        println!("address: {}", r.address);
        println!("ufvk: {}", r.ufvk);
        println!("data dir: {}", r.data_dir);
        println!();
        println!("Store these FROST key packages securely; they are shares:");
        println!("public key package: {}", r.public_key_package);
        println!("participant 1: {}", r.participant_1_key_package);
        println!("participant 2: {}", r.participant_2_key_package);
        println!("participant 3: {}", r.participant_3_key_package);
    });
    Ok(())
}

#[derive(Serialize)]
struct FrostSpendResult {
    txid: Option<String>,
    signed_pczt_hex: String,
    broadcast: bool,
}

pub async fn cmd_frost_spend(
    cfg: &Config,
    to: String,
    amount: u64,
    key1: String,
    key2: String,
    public_key_package: String,
    memo: Option<String>,
    broadcast: bool,
) -> Result<()> {
    ensure_data_dir(&cfg.data_dir)?;
    auto_open(cfg).await?;
    let synced = zipher_engine::query::get_synced_height().await.unwrap_or(0);
    let latest = zipher_engine::wallet::fetch_latest_height(&cfg.server_url)
        .await
        .unwrap_or(synced as u64) as u32;
    zipher_engine::sync::set_progress(synced, latest).await;

    zipher_engine::send::propose_send(&to, amount, memo, false).await?;
    let pczt = zipher_engine::send::create_pczt().await?;
    let req = zipher_engine::frost::frost_pczt_signing_request(pczt.clone())?;
    if req.orchard_actions.is_empty() {
        return Err(anyhow::anyhow!("PCZT did not contain Orchard actions to sign"));
    }

    let mut signatures = BTreeMap::new();
    for action in req.orchard_actions {
        let s1 = zipher_engine::frost::frost_sign_round1(key1.clone())?;
        let s2 = zipher_engine::frost::frost_sign_round1(key2.clone())?;
        let signing_package = zipher_engine::frost::frost_create_signing_package(
            action.sighash_hex,
            BTreeMap::from([
                (s1.participant_id, s1.signing_commitments.clone()),
                (s2.participant_id, s2.signing_commitments.clone()),
            ]),
        )?;
        let share1 = zipher_engine::frost::frost_sign_round2(
            signing_package.clone(),
            s1.signing_nonces.clone(),
            key1.clone(),
            action.randomizer_point_hex.clone(),
        )?;
        let share2 = zipher_engine::frost::frost_sign_round2(
            signing_package.clone(),
            s2.signing_nonces.clone(),
            key2.clone(),
            action.randomizer_point_hex,
        )?;
        let sig = zipher_engine::frost::frost_aggregate(
            signing_package,
            BTreeMap::from([
                (s1.participant_id, share1),
                (s2.participant_id, share2),
            ]),
            public_key_package.clone(),
            action.randomizer_hex,
        )?;
        signatures.insert(action.action_index, sig.signature_hex);
    }

    let signed = zipher_engine::frost::frost_pczt_apply_signatures(pczt, signatures)?;
    let txid = if broadcast {
        Some(zipher_engine::send::store_and_broadcast_signed_pczt(&signed).await?)
    } else {
        None
    };

    let out = FrostSpendResult {
        txid,
        signed_pczt_hex: hex::encode(&signed),
        broadcast,
    };
    print_ok(out, cfg.human, |r| {
        if let Some(txid) = &r.txid {
            println!("FROST transaction broadcast: {}", txid);
        } else {
            println!("FROST signed PCZT ready.");
            println!("{}", r.signed_pczt_hex);
        }
    });
    Ok(())
}
