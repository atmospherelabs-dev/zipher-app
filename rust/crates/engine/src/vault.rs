use std::path::{Path, PathBuf};

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Nonce};
use anyhow::{anyhow, Result};
use secrecy::{ExposeSecret, SecretString};
use zeroize::Zeroize;

const VAULT_FILENAME: &str = "vault.enc";
const SCRYPT_LOG_N: u8 = 18;
const SCRYPT_R: u32 = 8;
const SCRYPT_P: u32 = 1;
const SCRYPT_KEY_LEN: usize = 32;
const SALT_LEN: usize = 32;
const NONCE_LEN: usize = 12;

/// Encrypted seed vault using AES-256-GCM with scrypt-derived key.
///
/// File format (binary):
///   [salt: 32B] [nonce: 12B] [ciphertext+tag: variable]
///
/// The passphrase can be empty for agent/headless mode.
pub struct Vault {
    path: PathBuf,
}

impl Vault {
    pub fn vault_path(data_dir: &str) -> PathBuf {
        PathBuf::from(data_dir).join(VAULT_FILENAME)
    }

    pub fn exists(data_dir: &str) -> bool {
        Self::vault_path(data_dir).exists()
    }

    /// Create a new vault, encrypting the seed phrase.
    pub fn create(data_dir: &str, seed: &SecretString, passphrase: &str) -> Result<Self> {
        let path = Self::vault_path(data_dir);
        if path.exists() {
            return Err(anyhow!("Vault already exists at {}", path.display()));
        }

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }

        let encrypted = encrypt_seed(seed.expose_secret().as_bytes(), passphrase)?;
        std::fs::write(&path, &encrypted)?;

        // Restrict file permissions (owner-only read/write)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        }

        tracing::info!("Vault created at {}", path.display());
        Ok(Self { path })
    }

    /// Open an existing vault (does not decrypt — just verifies it exists).
    pub fn open(data_dir: &str) -> Result<Self> {
        let path = Self::vault_path(data_dir);
        if !path.exists() {
            return Err(anyhow!(
                "No vault found at {}. Run `wallet create` or `wallet restore` first.",
                path.display()
            ));
        }
        Ok(Self { path })
    }

    /// Decrypt the seed phrase from the vault.
    /// The returned SecretString is zeroized on drop.
    pub fn decrypt_seed(&self, passphrase: &str) -> Result<SecretString> {
        let data = std::fs::read(&self.path)
            .map_err(|e| anyhow!("Failed to read vault at {}: {}", self.path.display(), e))?;

        let mut plaintext = decrypt_seed(&data, passphrase)?;
        let seed = String::from_utf8(plaintext.clone())
            .map_err(|_| anyhow!("Vault contains invalid UTF-8"))?;
        plaintext.zeroize();

        Ok(SecretString::new(seed))
    }

    /// Path to the vault file.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

fn derive_key(passphrase: &[u8], salt: &[u8]) -> Result<[u8; SCRYPT_KEY_LEN]> {
    let params = scrypt::Params::new(SCRYPT_LOG_N, SCRYPT_R, SCRYPT_P, SCRYPT_KEY_LEN)
        .map_err(|e| anyhow!("Invalid scrypt params: {}", e))?;

    let mut key = [0u8; SCRYPT_KEY_LEN];
    scrypt::scrypt(passphrase, salt, &params, &mut key)
        .map_err(|e| anyhow!("scrypt failed: {}", e))?;

    Ok(key)
}

fn encrypt_seed(seed: &[u8], passphrase: &str) -> Result<Vec<u8>> {
    use rand::RngCore;

    let mut salt = [0u8; SALT_LEN];
    rand::rngs::OsRng.fill_bytes(&mut salt);

    let mut nonce_bytes = [0u8; NONCE_LEN];
    rand::rngs::OsRng.fill_bytes(&mut nonce_bytes);

    let mut key = derive_key(passphrase.as_bytes(), &salt)?;
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| anyhow!("AES key init: {}", e))?;
    key.zeroize();

    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher.encrypt(nonce, seed)
        .map_err(|e| anyhow!("Encryption failed: {}", e))?;

    let mut output = Vec::with_capacity(SALT_LEN + NONCE_LEN + ciphertext.len());
    output.extend_from_slice(&salt);
    output.extend_from_slice(&nonce_bytes);
    output.extend_from_slice(&ciphertext);

    Ok(output)
}

fn decrypt_seed(data: &[u8], passphrase: &str) -> Result<Vec<u8>> {
    let min_len = SALT_LEN + NONCE_LEN + 16; // 16 = AES-GCM tag
    if data.len() < min_len {
        return Err(anyhow!(
            "Vault file too small ({} bytes, need at least {})",
            data.len(),
            min_len
        ));
    }

    let salt = &data[..SALT_LEN];
    let nonce_bytes = &data[SALT_LEN..SALT_LEN + NONCE_LEN];
    let ciphertext = &data[SALT_LEN + NONCE_LEN..];

    let mut key = derive_key(passphrase.as_bytes(), salt)?;
    let cipher = Aes256Gcm::new_from_slice(&key)
        .map_err(|e| anyhow!("AES key init: {}", e))?;
    key.zeroize();

    let nonce = Nonce::from_slice(nonce_bytes);
    let plaintext = cipher.decrypt(nonce, ciphertext)
        .map_err(|_| anyhow!("Decryption failed — wrong passphrase or corrupted vault"))?;

    Ok(plaintext)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypt_decrypt_roundtrip() {
        let seed = b"abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
        let passphrase = "test-passphrase";

        let encrypted = encrypt_seed(seed, passphrase).unwrap();
        let decrypted = decrypt_seed(&encrypted, passphrase).unwrap();

        assert_eq!(&decrypted, seed);
    }

    #[test]
    fn empty_passphrase_works() {
        let seed = b"some seed phrase here";
        let encrypted = encrypt_seed(seed, "").unwrap();
        let decrypted = decrypt_seed(&encrypted, "").unwrap();
        assert_eq!(&decrypted, seed);
    }

    #[test]
    fn wrong_passphrase_fails() {
        let seed = b"secret seed";
        let encrypted = encrypt_seed(seed, "correct").unwrap();
        let result = decrypt_seed(&encrypted, "wrong");
        assert!(result.is_err());
    }

    #[test]
    fn vault_file_lifecycle() {
        let dir = tempfile::tempdir().unwrap();
        let data_dir = dir.path().to_str().unwrap();

        assert!(!Vault::exists(data_dir));

        let seed = SecretString::new("test seed phrase for vault".to_string());
        Vault::create(data_dir, &seed, "pass123").unwrap();

        assert!(Vault::exists(data_dir));

        let vault = Vault::open(data_dir).unwrap();
        let decrypted = vault.decrypt_seed("pass123").unwrap();
        assert_eq!(decrypted.expose_secret(), "test seed phrase for vault");

        let bad = vault.decrypt_seed("wrong");
        assert!(bad.is_err());
    }

    #[test]
    fn duplicate_create_fails() {
        let dir = tempfile::tempdir().unwrap();
        let data_dir = dir.path().to_str().unwrap();

        let seed = SecretString::new("seed".to_string());
        Vault::create(data_dir, &seed, "").unwrap();
        let result = Vault::create(data_dir, &seed, "");
        assert!(result.is_err());
    }
}
