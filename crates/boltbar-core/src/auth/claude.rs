use serde::Deserialize;
use std::path::{Path, PathBuf};

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
const CLAUDE_KEYCHAIN_SERVICE: &str = "Claude Code-credentials";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaudeAuth {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub expires_at_ms: Option<u64>,
    pub subscription_type: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CredentialsFile {
    #[serde(default, rename = "claudeAiOauth")]
    claude_ai_oauth: Option<OauthBlock>,
    #[serde(default, rename = "accessToken")]
    access_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OauthBlock {
    #[serde(default, rename = "accessToken")]
    access_token: Option<String>,
    #[serde(default, rename = "refreshToken")]
    refresh_token: Option<String>,
    #[serde(default, rename = "expiresAt")]
    expires_at: Option<u64>,
    #[serde(default, rename = "subscriptionType")]
    subscription_type: Option<String>,
}

pub fn default_credentials_path() -> PathBuf {
    if let Ok(dir) = std::env::var("CLAUDE_CONFIG_DIR") {
        return PathBuf::from(dir).join(".credentials.json");
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".claude")
        .join(".credentials.json")
}

pub fn parse_credentials_json(raw: &str) -> Option<ClaudeAuth> {
    let file: CredentialsFile = serde_json::from_str(raw).ok()?;
    if let Some(oauth) = file.claude_ai_oauth {
        let token = oauth.access_token.filter(|s| !s.is_empty())?;
        return Some(ClaudeAuth {
            access_token: token,
            refresh_token: oauth.refresh_token,
            expires_at_ms: oauth.expires_at,
            subscription_type: oauth.subscription_type,
        });
    }
    let token = file.access_token.filter(|s| !s.is_empty())?;
    Some(ClaudeAuth {
        access_token: token,
        refresh_token: None,
        expires_at_ms: None,
        subscription_type: None,
    })
}

pub fn load_from_path(path: &Path) -> Option<ClaudeAuth> {
    let raw = std::fs::read_to_string(path).ok()?;
    parse_credentials_json(&raw)
}

/// Claude Code on macOS stores OAuth JSON in the Keychain. Boltbar reads it
/// but never writes or refreshes it (refresh tokens are single-use).
pub fn load_from_claude_keychain() -> Option<ClaudeAuth> {
    #[cfg(target_os = "macos")]
    {
        let bytes =
            security_framework::passwords::get_generic_password(CLAUDE_KEYCHAIN_SERVICE, "user")
                .or_else(|_| {
                    security_framework::passwords::get_generic_password(
                        CLAUDE_KEYCHAIN_SERVICE,
                        "",
                    )
                })
                .ok()?;
        let raw = String::from_utf8(bytes).ok()?;
        parse_credentials_json(&raw)
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

pub fn access_token_fresh(auth: &ClaudeAuth) -> bool {
    let Some(exp) = auth.expires_at_ms else {
        return true;
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    exp > now + 60_000
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_claude_ai_oauth_block() {
        let auth = parse_credentials_json(
            r#"{
            "claudeAiOauth": {
                "accessToken": "at-123",
                "refreshToken": "rt-123",
                "expiresAt": 9999999999999,
                "subscriptionType": "pro"
            }
        }"#,
        )
        .unwrap();
        assert_eq!(auth.access_token, "at-123");
        assert_eq!(auth.subscription_type.as_deref(), Some("pro"));
        assert!(access_token_fresh(&auth));
    }

    #[test]
    fn expired_token_is_not_fresh() {
        let auth = ClaudeAuth {
            access_token: "x".into(),
            refresh_token: None,
            expires_at_ms: Some(1),
            subscription_type: None,
        };
        assert!(!access_token_fresh(&auth));
    }
}
