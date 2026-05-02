use std::path::PathBuf;
use std::sync::Mutex;

use anyhow::{Context, Result};
use candle_core::quantized::gguf_file;
use candle_core::{Device, Tensor};
use candle_transformers::generation::{LogitsProcessor, Sampling};
use candle_transformers::models::quantized_llama as qlm;
use tokenizers::Tokenizer;

static MODEL: Mutex<Option<LoadedModel>> = Mutex::new(None);

struct LoadedModel {
    model: qlm::ModelWeights,
    tokenizer: Tokenizer,
    device: Device,
}

/// Load a GGUF model and its tokenizer from disk.
/// Call once; subsequent `infer` calls reuse the loaded weights.
pub fn load_model(model_path: &str, tokenizer_path: &str) -> Result<()> {
    let device = Device::Cpu;

    let mut file = std::fs::File::open(model_path)
        .with_context(|| format!("Cannot open model: {model_path}"))?;
    let mut content = gguf_file::Content::read(&mut file)
        .map_err(|e| anyhow::anyhow!("GGUF parse error: {e}"))?;

    // candle's quantized_llama expects metadata keys prefixed with "llama."
    // but Qwen, Mistral, etc. use their own prefix (e.g. "qwen2.", "mistral.").
    // Remap to "llama." so the loader works with any compatible architecture.
    let arch = content
        .metadata
        .get("general.architecture")
        .and_then(|v| v.to_string().ok())
        .cloned()
        .unwrap_or_default();
    if !arch.is_empty() && arch != "llama" {
        let prefix = format!("{}.", arch);
        let remapped: std::collections::HashMap<String, gguf_file::Value> = content
            .metadata
            .drain()
            .map(|(k, v)| {
                if let Some(rest) = k.strip_prefix(&prefix) {
                    (format!("llama.{rest}"), v)
                } else {
                    (k, v)
                }
            })
            .collect();
        content.metadata = remapped;
    }

    // Qwen/Mistral GGUFs omit rope.dimension_count — synthesize from head_dim.
    if !content.metadata.contains_key("llama.rope.dimension_count") {
        let emb = content
            .metadata
            .get("llama.embedding_length")
            .and_then(|v| v.to_u32().ok())
            .unwrap_or(0);
        let heads = content
            .metadata
            .get("llama.attention.head_count")
            .and_then(|v| v.to_u32().ok())
            .unwrap_or(1);
        if emb > 0 && heads > 0 {
            content.metadata.insert(
                "llama.rope.dimension_count".to_string(),
                gguf_file::Value::U32(emb / heads),
            );
        }
    }

    let model = qlm::ModelWeights::from_gguf(content, &mut file, &device)
        .map_err(|e| anyhow::anyhow!("Model load error: {e}"))?;

    let tokenizer = Tokenizer::from_file(tokenizer_path)
        .map_err(|e| anyhow::anyhow!("Tokenizer load error: {e}"))?;

    let mut guard = MODEL
        .lock()
        .map_err(|e| anyhow::anyhow!("Lock error: {e}"))?;
    *guard = Some(LoadedModel {
        model,
        tokenizer,
        device,
    });

    Ok(())
}

/// Unload the model, freeing memory.
pub fn unload_model() -> Result<()> {
    let mut guard = MODEL
        .lock()
        .map_err(|e| anyhow::anyhow!("Lock error: {e}"))?;
    *guard = None;
    Ok(())
}

/// Check whether a model is currently loaded.
pub fn is_model_loaded() -> bool {
    MODEL.lock().map(|g| g.is_some()).unwrap_or(false)
}

/// Run inference on the loaded model.
///
/// `prompt`: the full prompt (system + user) to send
/// `max_tokens`: maximum number of tokens to generate
/// `temperature`: sampling temperature (0.0 = greedy)
///
/// Returns the generated text (excluding the prompt).
pub fn infer(prompt: &str, max_tokens: u32, temperature: f64) -> Result<String> {
    let mut guard = MODEL
        .lock()
        .map_err(|e| anyhow::anyhow!("Lock error: {e}"))?;
    let loaded = guard
        .as_mut()
        .ok_or_else(|| anyhow::anyhow!("No model loaded — call load_model first"))?;

    let encoding = loaded
        .tokenizer
        .encode(prompt, true)
        .map_err(|e| anyhow::anyhow!("Tokenize error: {e}"))?;
    let prompt_tokens = encoding.get_ids().to_vec();

    let sampling = if temperature <= 0.0 {
        Sampling::ArgMax
    } else {
        Sampling::TopKThenTopP {
            k: 40,
            p: 0.95,
            temperature,
        }
    };
    let mut logits_processor = LogitsProcessor::from_sampling(42, sampling);

    let mut all_tokens = prompt_tokens.clone();
    let mut generated = Vec::new();

    // Feed the prompt
    let input = Tensor::new(prompt_tokens.as_slice(), &loaded.device)?.unsqueeze(0)?;
    let logits = loaded.model.forward(&input, 0)?;
    let logits = logits.squeeze(0)?;
    let next_token = logits_processor.sample(&logits)?;
    all_tokens.push(next_token);
    generated.push(next_token);

    let eos_token = loaded
        .tokenizer
        .token_to_id("</s>")
        .or_else(|| loaded.tokenizer.token_to_id("<|im_end|>"))
        .or_else(|| loaded.tokenizer.token_to_id("<|endoftext|>"))
        .unwrap_or(2);

    let im_end_token = loaded.tokenizer.token_to_id("<|im_end|>");

    // Auto-regressive generation
    for i in 0..max_tokens.saturating_sub(1) {
        let last = *generated.last().unwrap_or(&0);
        if last == eos_token || im_end_token.map_or(false, |t| last == t) {
            break;
        }
        let input = Tensor::new(&[*generated.last().unwrap()], &loaded.device)?.unsqueeze(0)?;
        let pos = prompt_tokens.len() + i as usize;
        let logits = loaded.model.forward(&input, pos)?;
        let logits = logits.squeeze(0)?;
        let next_token = logits_processor.sample(&logits)?;
        all_tokens.push(next_token);
        generated.push(next_token);
    }

    let text = loaded
        .tokenizer
        .decode(&generated, true)
        .map_err(|e| anyhow::anyhow!("Decode error: {e}"))?;

    let clean = text
        .trim()
        .trim_end_matches("<|im_end|>")
        .trim_end_matches("</s>")
        .trim();
    Ok(clean.to_string())
}

/// Structured intent prompt for the LLM.
/// Uses ChatML format (SmolLM2's native format) with few-shot examples
/// to force structured JSON output.
///
/// The user_input may include context lines (e.g., recent markets shown)
/// prefixed before the actual user message to help resolve ambiguous references.
pub fn build_intent_prompt(user_input: &str) -> String {
    format!(
        r#"<|im_start|>system
You classify user requests into JSON. Reply with ONLY a JSON object, nothing else.
Types: balance, send, swap, shield, market_search, market_discover, bet, bet_polymarket, portfolio, sell, sweep, help, unknown.
Amounts are USD unless "ZEC" is said. Only include "direction" for bets if the user specifies yes/no.
Use "bet" for Myriad markets (numeric IDs). Use "bet_polymarket" when context is Polymarket — set "runner_index" to the row number shown.
If context about recent markets or actions is provided, use it to resolve references like "the first one" or "that market".<|im_end|>
<|im_start|>user
what's my balance<|im_end|>
<|im_start|>assistant
{{"type":"balance"}}<|im_end|>
<|im_start|>user
send $10 to u1abc123<|im_end|>
<|im_start|>assistant
{{"type":"send","amount":10,"address":"u1abc123"}}<|im_end|>
<|im_start|>user
find good bets<|im_end|>
<|im_start|>assistant
{{"type":"market_discover"}}<|im_end|>
<|im_start|>user
find promising markets<|im_end|>
<|im_start|>assistant
{{"type":"market_discover"}}<|im_end|>
<|im_start|>user
bet $5 yes on market #27498<|im_end|>
<|im_start|>assistant
{{"type":"bet","amount":5,"market_id":27498,"direction":"yes"}}<|im_end|>
<|im_start|>user
bet $6 on market 166757<|im_end|>
<|im_start|>assistant
{{"type":"bet","amount":6,"market_id":166757}}<|im_end|>
<|im_start|>user
search markets about bitcoin<|im_end|>
<|im_start|>assistant
{{"type":"market_search","query":"bitcoin"}}<|im_end|>
<|im_start|>user
bet 2$ yess on market 22033<|im_end|>
<|im_start|>assistant
{{"type":"bet","amount":2,"market_id":22033,"direction":"yes"}}<|im_end|>
<|im_start|>user
bet $10 no on market #5555<|im_end|>
<|im_start|>assistant
{{"type":"bet","amount":10,"market_id":5555,"direction":"no"}}<|im_end|>
<|im_start|>user
swap $20 to USDT<|im_end|>
<|im_start|>assistant
{{"type":"swap","amount":20,"from":"ZEC","to":"USDT"}}<|im_end|>
<|im_start|>user
my bets<|im_end|>
<|im_start|>assistant
{{"type":"portfolio"}}<|im_end|>
<|im_start|>user
sell market #27498<|im_end|>
<|im_start|>assistant
{{"type":"sell","market_id":27498}}<|im_end|>
<|im_start|>user
sweep usdt back to zec<|im_end|>
<|im_start|>assistant
{{"type":"sweep"}}<|im_end|>
<|im_start|>user
Recent markets shown: #166757 "ZEC to hit $420 in April?" (Yes 31%, No 69%), #120473 "Crude Oil next move: Pump to $120 or Dump to $55?"
User: bet $5 on the zec one<|im_end|>
<|im_start|>assistant
{{"type":"bet","amount":5,"market_id":166757}}<|im_end|>
<|im_start|>user
Recent markets shown: #120473 "Oil price", #161675 "BTC pump or dump"
User: bet on the first one yes<|im_end|>
<|im_start|>assistant
{{"type":"bet","market_id":120473,"direction":"yes"}}<|im_end|>
<|im_start|>user
Polymarket events:
1. "Democratic Presidential Nominee 2028" → Gavin Newsom 27%, Kamala Harris 6%
2. "2026 FIFA World Cup Winner" → France 17%, USA 1%
User: bet $5 on democracy if presidential nominee, Gavin newsom<|im_end|>
<|im_start|>assistant
{{"type":"bet_polymarket","amount":5,"runner_index":1,"runner_label":"Gavin Newsom","direction":"yes"}}<|im_end|>
<|im_start|>user
Polymarket events:
1. "Will Bitcoin hit $200k?" → Yes 35%, No 65%
2. "F1 Drivers Champion" → Max Verstappen 40%, Lando Norris 25%
User: bet $10 on the first one yes<|im_end|>
<|im_start|>assistant
{{"type":"bet_polymarket","amount":10,"runner_index":1,"direction":"yes"}}<|im_end|>
<|im_start|>user
{user_input}<|im_end|>
<|im_start|>assistant
"#
    )
}

/// Return the recommended model filename and expected size.
pub fn recommended_model() -> (&'static str, &'static str, u64) {
    (
        "smollm2-1.7b-instruct-q4_k_m.gguf",
        "SmolLM2 1.7B Instruct (Q4_K_M)",
        1_060_000_000,
    )
}

/// Return the expected paths for model + tokenizer in the given app directory.
pub fn model_paths(app_dir: &str) -> (PathBuf, PathBuf) {
    let dir = PathBuf::from(app_dir).join("llm");
    let model = dir.join("model.gguf");
    let tokenizer = dir.join("tokenizer.json");
    (model, tokenizer)
}
