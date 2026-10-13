use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorAuth {
    pub access_token: String,
}

#[derive(Debug, Deserialize)]
struct AuthFile {
    #[serde(default, rename = "accessToken")]
    access_token: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

pub fn default_auth_path() -> PathBuf {
    if let Some(cfg) = dirs::config_dir() {
        let candidate = cfg.join("cursor").join("auth.json");
        if candidate.exists() {
            return candidate;
        }
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".config")
        .join("cursor")
        .join("auth.json")
}

pub fn parse_auth_json(raw: &str) -> Option<CursorAuth> {
    let file: AuthFile = serde_json::from_str(raw).ok()?;
    let token = file
        .access_token
        .or(file.token)
        .filter(|s| !s.is_empty())?;
    Some(CursorAuth {
        access_token: token,
    })
}

pub fn load_from_path(path: &Path) -> Option<CursorAuth> {
    let raw = std::fs::read_to_string(path).ok()?;
    parse_auth_json(&raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cursor_cli_auth() {
        let auth = parse_auth_json(r#"{"accessToken":"jwt-workos"}"#).unwrap();
        assert_eq!(auth.access_token, "jwt-workos");
    }
}
