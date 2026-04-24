use anyhow::Result;
use serde::{Deserialize, Serialize};

use ows_signer::chains::bitcoin::BitcoinSigner;
use ows_signer::chains::evm::EvmSigner;
use ows_signer::chains::solana::SolanaSigner;
use ows_signer::curve::Curve;
use ows_signer::hd::HdDeriver;
use ows_signer::mnemonic::Mnemonic;
use ows_signer::traits::ChainSigner;

/// Addresses derived from a single BIP-39 seed across multiple chains.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MultiChainAddresses {
    pub evm: String,
    pub solana: String,
    pub bitcoin: String,
}

fn parse_mnemonic(seed_phrase: &str) -> Result<Mnemonic> {
    Mnemonic::from_phrase(seed_phrase)
        .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {}", e))
}

fn derive_address_for<S: ChainSigner>(
    signer: &S,
    mnemonic: &Mnemonic,
    curve: Curve,
) -> Result<String> {
    let path = signer.default_derivation_path(0);
    let secret_key = HdDeriver::derive_from_mnemonic(mnemonic, "", &path, curve)
        .map_err(|e| anyhow::anyhow!("HD derivation failed: {}", e))?;
    signer
        .derive_address(secret_key.expose())
        .map_err(|e| anyhow::anyhow!("Address derivation failed: {}", e))
}

/// Derive an EVM (BSC/ETH) address from a BIP-39 seed phrase.
/// Uses BIP-44 path m/44'/60'/0'/0/0.
pub fn derive_evm_address(seed_phrase: &str) -> Result<String> {
    let mnemonic = parse_mnemonic(seed_phrase)?;
    derive_address_for(&EvmSigner, &mnemonic, Curve::Secp256k1)
}

/// Derive a Solana address from a BIP-39 seed phrase.
/// Uses BIP-44 path m/44'/501'/0'/0'.
pub fn derive_solana_address(seed_phrase: &str) -> Result<String> {
    let mnemonic = parse_mnemonic(seed_phrase)?;
    derive_address_for(&SolanaSigner, &mnemonic, Curve::Ed25519)
}

/// Derive a Bitcoin native segwit (bech32) address from a BIP-39 seed phrase.
/// Uses BIP-84 path m/84'/0'/0'/0/0.
pub fn derive_bitcoin_address(seed_phrase: &str) -> Result<String> {
    let mnemonic = parse_mnemonic(seed_phrase)?;
    derive_address_for(&BitcoinSigner::mainnet(), &mnemonic, Curve::Secp256k1)
}

/// Derive addresses for EVM, Solana, and Bitcoin from a single seed phrase.
pub fn derive_all_addresses(seed_phrase: &str) -> Result<MultiChainAddresses> {
    let mnemonic = parse_mnemonic(seed_phrase)?;
    Ok(MultiChainAddresses {
        evm: derive_address_for(&EvmSigner, &mnemonic, Curve::Secp256k1)?,
        solana: derive_address_for(&SolanaSigner, &mnemonic, Curve::Ed25519)?,
        bitcoin: derive_address_for(&BitcoinSigner::mainnet(), &mnemonic, Curve::Secp256k1)?,
    })
}

/// Sign an unsigned EVM transaction and return the broadcast-ready signed bytes.
///
/// `seed_phrase`: BIP-39 mnemonic
/// `unsigned_tx_bytes`: The unsigned EIP-1559 (type 0x02) transaction envelope
///
/// Returns the fully signed transaction bytes ready for eth_sendRawTransaction.
pub fn sign_evm_tx(seed_phrase: &str, unsigned_tx_bytes: &[u8]) -> Result<Vec<u8>> {
    let mnemonic = ows_signer::mnemonic::Mnemonic::from_phrase(seed_phrase)
        .map_err(|e| anyhow::anyhow!("Invalid seed phrase: {}", e))?;

    let signer = EvmSigner;
    let path = signer.default_derivation_path(0);

    let secret_key = HdDeriver::derive_from_mnemonic(&mnemonic, "", &path, Curve::Secp256k1)
        .map_err(|e| anyhow::anyhow!("HD derivation failed: {}", e))?;

    let sig_output = signer
        .sign_transaction(secret_key.expose(), unsigned_tx_bytes)
        .map_err(|e| anyhow::anyhow!("Transaction signing failed: {}", e))?;

    let signed_bytes = signer
        .encode_signed_transaction(unsigned_tx_bytes, &sig_output)
        .map_err(|e| anyhow::anyhow!("Signed tx encoding failed: {}", e))?;

    Ok(signed_bytes)
}

/// Sign an unsigned EVM transaction, broadcast it to an RPC endpoint, and return the tx hash.
pub async fn sign_and_broadcast_evm_tx(
    seed_phrase: &str,
    unsigned_tx_bytes: &[u8],
    rpc_url: &str,
) -> Result<String> {
    let signed_bytes = sign_evm_tx(seed_phrase, unsigned_tx_bytes)?;
    let signed_hex = format!("0x{}", hex::encode(&signed_bytes));

    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_sendRawTransaction",
        "params": [signed_hex],
        "id": 1,
    });

    let resp: serde_json::Value = client
        .post(rpc_url)
        .json(&body)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("RPC send failed: {}", e))?
        .json()
        .await
        .map_err(|e| anyhow::anyhow!("RPC parse failed: {}", e))?;

    if let Some(error) = resp.get("error") {
        return Err(anyhow::anyhow!(
            "RPC error: {}",
            error.get("message").and_then(|m| m.as_str()).unwrap_or("unknown")
        ));
    }

    resp["result"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| anyhow::anyhow!("No tx hash in RPC response"))
}
