//! News & research agent — fetches web information for market analysis.
//!
//! Uses Firecrawl search API when `FIRECRAWL_API_KEY` is set.
//! Falls back to market-data-only analysis when unavailable.

use anyhow::Result;
use serde::{Deserialize, Serialize};
use tracing::info;

const FIRECRAWL_API: &str = "https://api.firecrawl.dev/v1";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NewsItem {
    pub title: String,
    pub url: String,
    pub snippet: String,
    /// Full markdown content (only when scrape is enabled)
    pub content: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ResearchReport {
    pub query: String,
    pub items: Vec<NewsItem>,
    pub summary: String,
    pub source: String,
}

// Firecrawl response types
#[derive(Debug, Deserialize)]
struct FirecrawlSearchResponse {
    #[allow(dead_code)]
    success: Option<bool>,
    #[serde(default)]
    data: Vec<FirecrawlSearchResult>,
}

#[derive(Debug, Deserialize)]
struct FirecrawlSearchResult {
    url: Option<String>,
    title: Option<String>,
    description: Option<String>,
    markdown: Option<String>,
}

// ---------------------------------------------------------------------------
// Firecrawl Search Client
// ---------------------------------------------------------------------------

/// Search the web for information related to a topic using Firecrawl.
/// Requires `FIRECRAWL_API_KEY` environment variable.
/// Falls back to a basic summary if Firecrawl is unavailable.
pub async fn search_news(query: &str, limit: usize) -> Result<ResearchReport> {
    let api_key = std::env::var("FIRECRAWL_API_KEY").ok();

    if let Some(key) = api_key {
        search_firecrawl(query, limit, &key).await
    } else {
        info!("FIRECRAWL_API_KEY not set — using market data only");
        Ok(ResearchReport {
            query: query.to_string(),
            items: vec![],
            summary: "No external research available (FIRECRAWL_API_KEY not set). \
                       Analysis based on market data only."
                .to_string(),
            source: "none".to_string(),
        })
    }
}

async fn search_firecrawl(query: &str, limit: usize, api_key: &str) -> Result<ResearchReport> {
    let client = reqwest::Client::new();

    let body = serde_json::json!({
        "query": query,
        "limit": limit.min(10),
        "scrapeOptions": {
            "formats": ["markdown"],
        }
    });

    info!("Searching Firecrawl: \"{}\" (limit {})", query, limit);

    let resp = client
        .post(&format!("{}/search", FIRECRAWL_API))
        .header("Authorization", format!("Bearer {}", api_key))
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| anyhow::anyhow!("Firecrawl request failed: {}", e))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| anyhow::anyhow!("Failed to read Firecrawl response: {}", e))?;

    if !status.is_success() {
        return Err(anyhow::anyhow!(
            "Firecrawl returned {}: {}",
            status,
            &text[..text.len().min(300)]
        ));
    }

    let parsed: FirecrawlSearchResponse = serde_json::from_str(&text)
        .map_err(|e| anyhow::anyhow!("Failed to parse Firecrawl response: {}", e))?;

    let items: Vec<NewsItem> = parsed
        .data
        .into_iter()
        .map(|r| {
            let content = r.markdown.as_ref().map(|md| {
                // Truncate long content to keep context manageable for LLM
                if md.len() > 2000 {
                    format!("{}...", &md[..2000])
                } else {
                    md.clone()
                }
            });

            NewsItem {
                title: r.title.unwrap_or_default(),
                url: r.url.unwrap_or_default(),
                snippet: r.description.unwrap_or_default(),
                content,
            }
        })
        .collect();

    let summary = build_summary(query, &items);

    info!(
        "Firecrawl returned {} results for \"{}\"",
        items.len(),
        query
    );

    Ok(ResearchReport {
        query: query.to_string(),
        items,
        summary,
        source: "firecrawl".to_string(),
    })
}

fn build_summary(query: &str, items: &[NewsItem]) -> String {
    if items.is_empty() {
        return format!("No web results found for \"{}\". The LLM should rely on its own knowledge.", query);
    }

    let mut summary = format!(
        "Found {} sources for \"{}\". Key findings:\n",
        items.len(),
        query
    );

    for (i, item) in items.iter().take(5).enumerate() {
        summary.push_str(&format!(
            "\n[{}] {} — {}\n    Source: {}\n",
            i + 1,
            item.title,
            if item.snippet.len() > 200 {
                format!("{}...", &item.snippet[..200])
            } else {
                item.snippet.clone()
            },
            item.url
        ));
    }

    summary
}

// ---------------------------------------------------------------------------
// Market-specific research queries
// ---------------------------------------------------------------------------

/// Generate search queries for a prediction market topic.
/// Returns multiple queries to get diverse perspectives.
pub fn research_queries_for_market(title: &str) -> Vec<String> {
    vec![
        format!("{} latest news", title),
        format!("{} prediction analysis forecast", title),
        format!("{} odds probability expert opinion", title),
    ]
}
