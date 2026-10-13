use crate::error::{BoltError, Result};
use crate::providers::openai::{chat_completions_body, pump_openai_sse};
use crate::types::{ChatRequest, ResolvedAuth, StreamEvent};
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

/// Cursor has no public chat-completions API. This path is only used when the
/// user configured an OpenAI-compatible proxy base URL plus an API key.
pub async fn stream_openai_compatible(
    http: &reqwest::Client,
    base_url: &str,
    req: &ChatRequest,
    auth: &ResolvedAuth,
    tx: mpsc::Sender<StreamEvent>,
    cancel: CancellationToken,
) -> Result<()> {
    let key = match auth {
        ResolvedAuth::ApiKey(key) => key.clone(),
        ResolvedAuth::Bearer { token, .. } => token.clone(),
        ResolvedAuth::Cli { .. } => {
            return Err(BoltError::auth("CLI transport should be used for Cursor CLI"));
        }
    };
    let url = format!("{}/chat/completions", base_url.trim_end_matches('/'));
    let mut headers = HeaderMap::new();
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {key}"))
            .map_err(|_| BoltError::msg("invalid Cursor API key"))?,
    );
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let resp = http
        .post(url)
        .headers(headers)
        .json(&chat_completions_body(req))
        .send()
        .await?;
    pump_openai_sse(resp, tx, cancel).await
}
