use serde::Serialize;

#[derive(Default, Serialize)]
pub struct WalletBalance {
    pub transparent: u64,
    pub sapling: u64,
    pub orchard: u64,
    pub unconfirmed_sapling: u64,
    pub unconfirmed_orchard: u64,
    pub unconfirmed_transparent: u64,
    pub total_transparent: u64,
    pub total_sapling: u64,
    pub total_orchard: u64,
}

#[derive(Serialize)]
pub struct AddressInfo {
    pub address: String,
    pub has_transparent: bool,
    pub has_sapling: bool,
    pub has_orchard: bool,
}

#[derive(Serialize)]
pub struct EngineTransactionRecord {
    pub txid: String,
    pub height: u32,
    pub timestamp: u32,
    pub value: i64,
    pub kind: String,
    pub fee: Option<u64>,
    pub memo: Option<String>,
    pub expired_unmined: bool,
}
