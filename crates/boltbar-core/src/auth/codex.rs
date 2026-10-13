use serde::Deserialize;
use std::path::{Path, PathBuf};

/// Parsed `~/.codex/auth.json` from the official Codex CLI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexAuth {
    pub mode: CodexAuthMode,
    pub api_key: Option<String>,
    pub access_token: Option<String>,
    pub refresh_token: Option<String>,
    pub account_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexAuthMode {
    ApiKey,
    Chatgpt,
    Unknown,
}

#[derive(Debug, Deserialize)]
struct CodexAuthFile {
    #[serde(default)]
    auth_mode: Option<String>,
    #[serde(default, rename = "OPENAI_API_KEY")]
    openai_api_key: Option<String>,
    #[serde(default)]
    tokens: Option<CodexTokens>,
}

#[derive(Debug, Deserialize)]
struct CodexTokens {
    #[serde(default)]
    access_token: Option<String>,
    #[serde(default)]
    refresh_token: Option<String>,
    #[serde(default)]
    account_id: Option<String>,
}

pub fn default_auth_path() -> PathBuf {
    if let Ok(home) = std::env::var("CODEX_HOME") {
        return PathBuf::from(home).join("auth.json");
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".codex")
        .join("auth.json")
}

pub fn parse_auth_json(raw: &str) -> Option<CodexAuth> {
    let file: CodexAuthFile = serde_json::from_str(raw).ok()?;
    let mode = match file
        .auth_mode
        .as_deref()
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "apikey" => CodexAuthMode::ApiKey,
        "chatgpt" => CodexAuthMode::Chatgpt,
        _ if file.openai_api_key.as_deref().is_some_and(|k| !k.is_empty()) => {
            CodexAuthMode::ApiKey
        }
        _ if file.tokens.is_some() => CodexAuthMode::Chatgpt,
        _ => CodexAuthMode::Unknown,
    };
    let tokens = file.tokens;
    Some(CodexAuth {
        mode,
        api_key: file
            .openai_api_key
            .filter(|s| !s.is_empty() && s != "null"),
        access_token: tokens.as_ref().and_then(|t| t.access_token.clone()),
        refresh_token: tokens.as_ref().and_then(|t| t.refresh_token.clone()),
        account_id: tokens.as_ref().and_then(|t| t.account_id.clone()),
    })
}

pub fn load_from_path(path: &Path) -> Option<CodexAuth> {
    let raw = std::fs::read_to_string(path).ok()?;
    parse_auth_json(&raw)
}

pub fn jwt_unexpired(token: &str) -> bool {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() < 2 {
        return true;
    }
    let payload = parts[1];
    let padded = match payload.len() % 4 {
        2 => format!("{payload}=="),
        3 => format!("{payload}="),
        _ => payload.to_string(),
    };
    use base64::Engine;
    let Ok(bytes) = base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(payload).or_else(
        |_| base64::engine::general_purpose::STANDARD.decode(padded.replace('-', "+").replace('_', "/")),
    ) else {
        return true;
    };
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
        return true;
    };
    let Some(exp) = value.get("exp").and_then(|v| v.as_u64()) else {
        return true;
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    exp > now + 60
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_apikey_mode() {
        let auth = parse_auth_json(
            r#"{
            "auth_mode": "ApiKey",
            "OPENAI_API_KEY": "sk-test-123"
        }"#,
        )
        .unwrap();
        assert_eq!(auth.mode, CodexAuthMode::ApiKey);
        assert_eq!(auth.api_key.as_deref(), Some("sk-test-123"));
    }

    #[test]
    fn parses_chatgpt_mode() {
        let auth = parse_auth_json(
            r#"{
            "auth_mode": "chatgpt",
            "OPENAI_API_KEY": null,
            "tokens": {
                "id_token": "id",
                "access_token": "access",
                "refresh_token": "refresh",
                "account_id": "11111111-1111-1111-1111-111111111111"
            }
        }"#,
        )
        .unwrap();
        assert_eq!(auth.mode, CodexAuthMode::Chatgpt);
        assert_eq!(auth.access_token.as_deref(), Some("access"));
        assert_eq!(
            auth.account_id.as_deref(),
            Some("11111111-1111-1111-1111-111111111111")
        );
    }

    #[test]
    fn jwt_expiry_detects_past_exp() {
        // {"exp": 1}  — expired in 1970
        let payload = base64::Engine::encode(
            &base64::engine::general_purpose::URL_SAFE_NO_PAD,
            br#"{"exp":1}"#,
        );
        let token = format!("x.{payload}.sig");
        assert!(!jwt_unexpired(&token));
    }
}
