use crate::error::Result;
use crate::types::{ProviderKind, ResolvedAuth};
use serde::Deserialize;
use std::process::Stdio;
use std::time::Duration;
use tokio::process::Command;

const FETCH_TIMEOUT: Duration = Duration::from_secs(5);

/// October 2026 fallbacks from each provider's public model docs.
/// Live `/v1/models` (or `agent --list-models`) replaces these when reachable.
pub fn fallback_models(kind: ProviderKind) -> &'static [&'static str] {
    match kind {
        ProviderKind::Openai => &[
            "gpt-6-astra",
            "gpt-6.1-sol",
            "gpt-6-luna",
            "gpt-5.2",
            "gpt-4.1",
            "gpt-4o",
        ],
        ProviderKind::Anthropic => &[
            "claude-sonnet-5-5",
            "claude-opus-5-5",
            "claude-fable-5-1",
            "claude-haiku-5-5",
            "claude-sonnet-4-6",
            "claude-opus-4-6",
        ],
        ProviderKind::Cursor => &[
            "auto",
            "composer-2.5",
            "composer-2.5-fast",
            "gpt-6-astra",
            "claude-sonnet-5-5",
            "claude-opus-5-5",
        ],
        ProviderKind::Demo => &["boltbar-demo"],
    }
}

pub fn default_model(kind: ProviderKind) -> &'static str {
    match kind {
        ProviderKind::Openai => "gpt-6-astra",
        ProviderKind::Anthropic => "claude-sonnet-5-5",
        ProviderKind::Cursor => "auto",
        ProviderKind::Demo => "boltbar-demo",
    }
}

pub fn models_for(kind: ProviderKind) -> &'static [&'static str] {
    fallback_models(kind)
}

#[derive(Debug, Deserialize)]
struct OpenAiList {
    #[serde(default)]
    data: Vec<NamedId>,
}

#[derive(Debug, Deserialize)]
struct AnthropicList {
    #[serde(default)]
    data: Vec<NamedId>,
}

#[derive(Debug, Deserialize)]
struct NamedId {
    id: String,
}

pub fn parse_openai_models_json(body: &str) -> Vec<String> {
    let parsed: OpenAiList = serde_json::from_str(body).unwrap_or(OpenAiList { data: vec![] });
    let raw: Vec<String> = parsed
        .data
        .into_iter()
        .map(|m| m.id)
        .filter(|id| is_openai_chat_model(id))
        .collect();
    rank_models(ProviderKind::Openai, dedupe_dated_aliases(raw))
}

pub fn parse_anthropic_models_json(body: &str) -> Vec<String> {
    let parsed: AnthropicList = serde_json::from_str(body).unwrap_or(AnthropicList { data: vec![] });
    let raw: Vec<String> = parsed
        .data
        .into_iter()
        .map(|m| m.id)
        .filter(|id| is_anthropic_chat_model(id))
        .collect();
    rank_models(ProviderKind::Anthropic, raw)
}

/// Cursor `agent --list-models` / `agent models` lines look like
/// `composer-2.5 - Composer 2.5` or a bare id.
pub fn parse_cursor_models_output(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let lower = line.to_ascii_lowercase();
        if (lower.contains("available") || lower.starts_with("name") || lower.starts_with("model"))
            && !line.contains(" - ")
        {
            continue;
        }
        let id = if let Some((left, _)) = line.split_once(" - ") {
            left.trim()
        } else {
            line.split_whitespace().next().unwrap_or("")
        };
        if is_cursor_model_id(id) && !out.iter().any(|existing| existing == id) {
            out.push(id.to_string());
        }
    }
    rank_models(ProviderKind::Cursor, out)
}

pub fn is_openai_chat_model(id: &str) -> bool {
    let id = id.to_ascii_lowercase();
    if id.contains("embed")
        || id.contains("whisper")
        || id.contains("tts")
        || id.contains("dall-e")
        || id.contains("davinci")
        || id.contains("babbage")
        || id.contains("moderation")
        || id.contains("transcribe")
        || id.contains("realtime")
        || id.contains("audio")
        || id.contains("image")
        || id.contains("search-")
        || id.contains("gpt-image")
    {
        return false;
    }
    id.starts_with("gpt-")
        || id.starts_with("o1")
        || id.starts_with("o3")
        || id.starts_with("o4")
        || id.starts_with("chatgpt")
}

pub fn is_anthropic_chat_model(id: &str) -> bool {
    let id = id.to_ascii_lowercase();
    id.starts_with("claude-") && !id.contains("embed")
}

fn is_cursor_model_id(id: &str) -> bool {
    if id.is_empty() || id.len() > 80 {
        return false;
    }
    id.chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
}

pub fn dedupe_dated_aliases(ids: Vec<String>) -> Vec<String> {
    let aliases: Vec<String> = ids
        .iter()
        .filter(|id| !is_dated_snapshot(id))
        .cloned()
        .collect();
    ids.into_iter()
        .filter(|id| {
            if !is_dated_snapshot(id) {
                return true;
            }
            let stem = dated_stem(id);
            !aliases.iter().any(|alias| alias == &stem || alias == id)
        })
        .collect()
}

fn is_dated_snapshot(id: &str) -> bool {
    let bytes = id.as_bytes();
    if bytes.len() < 11 {
        return false;
    }
    let tail = &id[id.len().saturating_sub(10)..];
    let b = tail.as_bytes();
    b.len() == 10
        && b[4] == b'-'
        && b[7] == b'-'
        && b[0..4].iter().all(|c| c.is_ascii_digit())
        && b[5..7].iter().all(|c| c.is_ascii_digit())
        && b[8..10].iter().all(|c| c.is_ascii_digit())
}

fn dated_stem(id: &str) -> String {
    if is_dated_snapshot(id) && id.len() > 11 {
        id[..id.len() - 11].to_string()
    } else {
        id.to_string()
    }
}

pub fn rank_models(kind: ProviderKind, mut ids: Vec<String>) -> Vec<String> {
    if ids.is_empty() {
        return fallback_models(kind)
            .iter()
            .map(|s| (*s).to_string())
            .collect();
    }
    for fallback in fallback_models(kind) {
        if !ids.iter().any(|id| id == fallback) {
            ids.push((*fallback).to_string());
        }
    }
    let preferred = fallback_models(kind);
    ids.sort_by(|a, b| {
        let ia = preferred.iter().position(|p| p == a).unwrap_or(500);
        let ib = preferred.iter().position(|p| p == b).unwrap_or(500);
        ia.cmp(&ib).then_with(|| a.cmp(b))
    });
    ids
}

pub fn merge_with_fallback(kind: ProviderKind, live: Vec<String>) -> Vec<String> {
    if live.is_empty() {
        return fallback_models(kind)
            .iter()
            .map(|s| (*s).to_string())
            .collect();
    }
    rank_models(kind, live)
}

pub async fn fetch_models(
    http: &reqwest::Client,
    kind: ProviderKind,
    auth: Option<&ResolvedAuth>,
    cursor_base_url: Option<&str>,
) -> Vec<String> {
    let live = match kind {
        ProviderKind::Demo => {
            return fallback_models(kind)
                .iter()
                .map(|s| (*s).to_string())
                .collect();
        }
        ProviderKind::Openai => fetch_openai(http, auth).await.unwrap_or_default(),
        ProviderKind::Anthropic => fetch_anthropic(http, auth).await.unwrap_or_default(),
        ProviderKind::Cursor => fetch_cursor(http, auth, cursor_base_url).await.unwrap_or_default(),
    };
    merge_with_fallback(kind, live)
}

async fn fetch_openai(http: &reqwest::Client, auth: Option<&ResolvedAuth>) -> Result<Vec<String>> {
    let key = match auth {
        Some(ResolvedAuth::ApiKey(key)) | Some(ResolvedAuth::Bearer { token: key, .. }) => key,
        _ => return Ok(Vec::new()),
    };
    let req = http
        .get("https://api.openai.com/v1/models")
        .bearer_auth(key);
    let body = timed_text(req).await?;
    Ok(parse_openai_models_json(&body))
}

async fn fetch_anthropic(http: &reqwest::Client, auth: Option<&ResolvedAuth>) -> Result<Vec<String>> {
    let mut req = http
        .get("https://api.anthropic.com/v1/models")
        .header("anthropic-version", "2023-06-01");
    match auth {
        Some(ResolvedAuth::ApiKey(key)) => {
            req = req.header("x-api-key", key);
        }
        Some(ResolvedAuth::Bearer { token, .. }) => {
            req = req
                .header("authorization", format!("Bearer {token}"))
                .header("anthropic-beta", "oauth-2025-04-20");
        }
        _ => return Ok(Vec::new()),
    }
    let body = timed_text(req).await?;
    Ok(parse_anthropic_models_json(&body))
}

async fn fetch_cursor(
    http: &reqwest::Client,
    auth: Option<&ResolvedAuth>,
    cursor_base_url: Option<&str>,
) -> Result<Vec<String>> {
    if let Some(base) = cursor_base_url.filter(|s| !s.is_empty()) {
        if let Some(key) = match auth {
            Some(ResolvedAuth::ApiKey(key)) => Some(key.as_str()),
            Some(ResolvedAuth::Bearer { token, .. }) => Some(token.as_str()),
            _ => None,
        } {
            let url = format!("{}/models", base.trim_end_matches('/'));
            let req = http.get(url).bearer_auth(key);
            if let Ok(body) = timed_text(req).await {
                let parsed = parse_openai_models_json(&body);
                if !parsed.is_empty() {
                    return Ok(parsed);
                }
            }
        }
    }
    if let Some(ResolvedAuth::Cli { program, extra_env }) = auth {
        return fetch_cursor_cli(program, extra_env).await;
    }
    fetch_cursor_cli_on_path().await
}

async fn fetch_cursor_cli(
    program: &str,
    extra_env: &[(String, String)],
) -> Result<Vec<String>> {
    for args in [vec!["--list-models"], vec!["models"]] {
        let mut cmd = Command::new(program);
        cmd.args(&args)
            .kill_on_drop(true)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        for (k, v) in extra_env {
            cmd.env(k, v);
        }
        if let Ok(out) = timed_output(cmd).await {
            if out.status.success() {
                let text = String::from_utf8_lossy(&out.stdout);
                let parsed = parse_cursor_models_output(&text);
                if !parsed.is_empty() {
                    return Ok(parsed);
                }
            }
        }
    }
    Ok(Vec::new())
}

async fn fetch_cursor_cli_on_path() -> Result<Vec<String>> {
    let program = which::which("agent")
        .or_else(|_| which::which("cursor-agent"))
        .ok();
    let Some(program) = program else {
        return Ok(Vec::new());
    };
    fetch_cursor_cli(&program.to_string_lossy(), &[]).await
}

async fn timed_text(req: reqwest::RequestBuilder) -> Result<String> {
    let resp = tokio::time::timeout(FETCH_TIMEOUT, req.send())
        .await
        .map_err(|_| crate::error::BoltError::msg("models request timed out"))??;
    if !resp.status().is_success() {
        return Err(crate::error::BoltError::Http {
            status: resp.status().as_u16(),
            body: resp.text().await.unwrap_or_default(),
        });
    }
    Ok(tokio::time::timeout(FETCH_TIMEOUT, resp.text())
        .await
        .map_err(|_| crate::error::BoltError::msg("models body timed out"))??)
}

async fn timed_output(mut cmd: Command) -> Result<std::process::Output> {
    Ok(tokio::time::timeout(FETCH_TIMEOUT, cmd.output())
        .await
        .map_err(|_| crate::error::BoltError::msg("cursor model list timed out"))??)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn openai_filters_non_chat_and_drops_dated_duplicates() {
        let body = r#"{
            "data": [
                {"id": "gpt-6-astra"},
                {"id": "gpt-6-astra-2026-04-30"},
                {"id": "whisper-1"},
                {"id": "text-embedding-3-large"},
                {"id": "gpt-5.2"},
                {"id": "dall-e-3"}
            ]
        }"#;
        let ids = parse_openai_models_json(body);
        assert!(ids.contains(&"gpt-6-astra".into()));
        assert!(ids.contains(&"gpt-5.2".into()));
        assert!(!ids.iter().any(|id| id.contains("whisper")));
        assert!(!ids.iter().any(|id| id.contains("2026-04-30")));
        assert_eq!(ids[0], "gpt-6-astra");
    }

    #[test]
    fn anthropic_keeps_claude_chat_ids() {
        let body = r#"{
            "data": [
                {"id": "claude-fable-5-1", "display_name": "Claude Fable 5.1"},
                {"id": "claude-sonnet-5-5"},
                {"id": "claude-embed-v1"}
            ]
        }"#;
        let ids = parse_anthropic_models_json(body);
        assert!(ids.contains(&"claude-sonnet-5-5".into()));
        assert!(ids.contains(&"claude-fable-5-1".into()));
        assert!(!ids.iter().any(|id| id.contains("embed")));
        assert_eq!(ids[0], "claude-sonnet-5-5");
    }

    #[test]
    fn cursor_parses_id_dash_display_and_bare_ids() {
        let text = "\
Available models
auto - Auto
composer-2.5 - Composer 2.5
composer-2.5-fast - Composer 2.5 Fast (default)
gpt-6-astra
";
        let ids = parse_cursor_models_output(text);
        assert_eq!(ids[0], "auto");
        assert!(ids.contains(&"composer-2.5".into()));
        assert!(ids.contains(&"composer-2.5-fast".into()));
        assert!(ids.contains(&"gpt-6-astra".into()));
    }

    #[test]
    fn empty_live_list_uses_oct_2026_fallbacks() {
        let openai = merge_with_fallback(ProviderKind::Openai, vec![]);
        assert_eq!(openai[0], "gpt-6-astra");
        let anthropic = merge_with_fallback(ProviderKind::Anthropic, vec![]);
        assert_eq!(anthropic[0], "claude-sonnet-5-5");
        assert!(anthropic.contains(&"claude-fable-5-1".into()));
    }

    #[test]
    fn flagship_defaults_match_docs() {
        assert_eq!(default_model(ProviderKind::Openai), "gpt-6-astra");
        assert_eq!(default_model(ProviderKind::Anthropic), "claude-sonnet-5-5");
        assert_eq!(default_model(ProviderKind::Cursor), "auto");
    }
}
