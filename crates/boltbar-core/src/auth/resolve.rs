use super::claude::{self, ClaudeAuth};
use super::codex::{self, CodexAuth, CodexAuthMode};
use super::commands::{first_present, CommandProbe};
use super::cursor;
use super::secrets::SecretStore;
use crate::error::Result;
use crate::types::{AuthKind, AuthStatus, ProviderKind, ResolvedAuth};
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub struct AuthPaths {
    pub codex_auth: PathBuf,
    pub claude_credentials: PathBuf,
    pub cursor_auth: PathBuf,
}

impl Default for AuthPaths {
    fn default() -> Self {
        Self {
            codex_auth: codex::default_auth_path(),
            claude_credentials: claude::default_credentials_path(),
            cursor_auth: cursor::default_auth_path(),
        }
    }
}

pub struct Resolver<'a> {
    pub secrets: &'a dyn SecretStore,
    pub paths: &'a AuthPaths,
    pub commands: &'a dyn CommandProbe,
    pub env: EnvSnapshot,
}

#[derive(Clone, Debug, Default)]
pub struct EnvSnapshot {
    pub openai_api_key: Option<String>,
    pub anthropic_api_key: Option<String>,
    pub claude_oauth: Option<String>,
    pub cursor_api_key: Option<String>,
}

impl EnvSnapshot {
    pub fn from_process() -> Self {
        Self {
            openai_api_key: std::env::var("OPENAI_API_KEY").ok().filter(|s| !s.is_empty()),
            anthropic_api_key: std::env::var("ANTHROPIC_API_KEY")
                .ok()
                .filter(|s| !s.is_empty()),
            claude_oauth: std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
                .ok()
                .filter(|s| !s.is_empty()),
            cursor_api_key: std::env::var("CURSOR_API_KEY").ok().filter(|s| !s.is_empty()),
        }
    }
}

impl Resolver<'_> {
    pub fn status(&self, provider: ProviderKind) -> AuthStatus {
        match self.resolve(provider) {
            Ok((auth, status)) => match auth {
                ResolvedAuth::ApiKey(_) | ResolvedAuth::Bearer { .. } | ResolvedAuth::Cli { .. } => {
                    status
                }
            },
            Err(err) => AuthStatus {
                provider,
                kind: AuthKind::Missing,
                label: err.to_string(),
                ready: false,
            },
        }
    }

    pub fn resolve(&self, provider: ProviderKind) -> Result<(ResolvedAuth, AuthStatus)> {
        match provider {
            ProviderKind::Demo => Ok((
                ResolvedAuth::ApiKey("demo".into()),
                AuthStatus {
                    provider,
                    kind: AuthKind::ApiKey,
                    label: "Built-in demo (no login required)".into(),
                    ready: true,
                },
            )),
            ProviderKind::Openai => self.resolve_openai(),
            ProviderKind::Anthropic => self.resolve_anthropic(),
            ProviderKind::Cursor => self.resolve_cursor(),
        }
    }

    fn resolve_openai(&self) -> Result<(ResolvedAuth, AuthStatus)> {
        if let Some(key) = self.secrets.get("openai")?.filter(|s| !s.is_empty()) {
            return Ok(api(
                ProviderKind::Openai,
                AuthKind::ApiKey,
                key,
                "API key stored in the macOS Keychain",
            ));
        }
        if let Some(key) = self.env.openai_api_key.clone() {
            return Ok(api(
                ProviderKind::Openai,
                AuthKind::Env,
                key,
                "OPENAI_API_KEY environment variable",
            ));
        }
        if let Some(file) = codex::load_from_path(&self.paths.codex_auth) {
            if let Some(key) = file.api_key.clone() {
                return Ok(api(
                    ProviderKind::Openai,
                    AuthKind::CliApiKey,
                    key,
                    "API key from Codex CLI ~/.codex/auth.json",
                ));
            }
            if file.mode == CodexAuthMode::Chatgpt {
                if let Some(cli) = first_present(self.commands, &["codex"]) {
                    return Ok(cli_status(
                        ProviderKind::Openai,
                        cli.1.to_string_lossy().into_owned(),
                        "Codex CLI (ChatGPT subscription login)",
                    ));
                }
                if let Some((token, account)) = chatgpt_usable(&file) {
                    return Ok((
                        ResolvedAuth::Bearer {
                            token,
                            account_id: account,
                        },
                        AuthStatus {
                            provider: ProviderKind::Openai,
                            kind: AuthKind::CliOauth,
                            label: "ChatGPT tokens from Codex CLI (unofficial Responses API)"
                                .into(),
                            ready: true,
                        },
                    ));
                }
                return Err(crate::error::BoltError::auth(
                    "Codex CLI is logged into ChatGPT, but the access token looks expired. Run `codex` once to refresh, or add an OpenAI API key.",
                ));
            }
        }
        if let Some(cli) = first_present(self.commands, &["codex"]) {
            return Ok(cli_status(
                ProviderKind::Openai,
                cli.1.to_string_lossy().into_owned(),
                "Codex CLI on PATH (will use its own login)",
            ));
        }
        Err(crate::error::BoltError::auth(
            "No OpenAI credentials. Add an API key in Settings, export OPENAI_API_KEY, or run `codex login`.",
        ))
    }

    fn resolve_anthropic(&self) -> Result<(ResolvedAuth, AuthStatus)> {
        if let Some(key) = self.secrets.get("anthropic")?.filter(|s| !s.is_empty()) {
            return Ok(api(
                ProviderKind::Anthropic,
                AuthKind::ApiKey,
                key,
                "API key stored in the macOS Keychain",
            ));
        }
        if let Some(key) = self.env.anthropic_api_key.clone() {
            return Ok(api(
                ProviderKind::Anthropic,
                AuthKind::Env,
                key,
                "ANTHROPIC_API_KEY environment variable",
            ));
        }
        if let Some(token) = self.env.claude_oauth.clone() {
            return Ok((
                ResolvedAuth::Bearer {
                    token,
                    account_id: None,
                },
                AuthStatus {
                    provider: ProviderKind::Anthropic,
                    kind: AuthKind::CliOauth,
                    label: "CLAUDE_CODE_OAUTH_TOKEN (claude setup-token)".into(),
                    ready: true,
                },
            ));
        }
        if let Some(file) = claude_credentials(self) {
            if claude::access_token_fresh(&file) {
                return Ok((
                    ResolvedAuth::Bearer {
                        token: file.access_token,
                        account_id: None,
                    },
                    AuthStatus {
                        provider: ProviderKind::Anthropic,
                        kind: AuthKind::CliOauth,
                        label: "Claude Code subscription token (read-only, not refreshed)".into(),
                        ready: true,
                    },
                ));
            }
            if let Some(cli) = first_present(self.commands, &["claude"]) {
                return Ok(cli_status(
                    ProviderKind::Anthropic,
                    cli.1.to_string_lossy().into_owned(),
                    "Claude Code CLI (stored OAuth token is expired; CLI will refresh)",
                ));
            }
            return Err(crate::error::BoltError::auth(
                "Claude Code credentials are expired. Open `claude` once so it can refresh, or add an Anthropic API key. Boltbar will not refresh Claude tokens itself (refresh tokens are single-use).",
            ));
        }
        if let Some(cli) = first_present(self.commands, &["claude"]) {
            return Ok(cli_status(
                ProviderKind::Anthropic,
                cli.1.to_string_lossy().into_owned(),
                "Claude Code CLI on PATH (will use its own login)",
            ));
        }
        Err(crate::error::BoltError::auth(
            "No Anthropic credentials. Add an API key in Settings, export ANTHROPIC_API_KEY, or run `claude` login.",
        ))
    }

    fn resolve_cursor(&self) -> Result<(ResolvedAuth, AuthStatus)> {
        if let Some(cli) = first_present(self.commands, &["agent", "cursor-agent"]) {
            let extra = if let Some(key) = self
                .secrets
                .get("cursor")?
                .filter(|s| !s.is_empty())
                .or_else(|| self.env.cursor_api_key.clone())
            {
                vec![("CURSOR_API_KEY".into(), key)]
            } else {
                Vec::new()
            };
            return Ok((
                ResolvedAuth::Cli {
                    program: cli.1.to_string_lossy().into_owned(),
                    extra_env: extra,
                },
                AuthStatus {
                    provider: ProviderKind::Cursor,
                    kind: AuthKind::CliBinary,
                    label: format!(
                        "Cursor CLI `{}` (subscription login or CURSOR_API_KEY)",
                        cli.0
                    ),
                    ready: true,
                },
            ));
        }
        if let Some(key) = self
            .secrets
            .get("cursor")?
            .filter(|s| !s.is_empty())
            .or_else(|| self.env.cursor_api_key.clone())
        {
            return Ok((
                ResolvedAuth::ApiKey(key),
                AuthStatus {
                    provider: ProviderKind::Cursor,
                    kind: AuthKind::ApiKey,
                    label: "Cursor API key (needs a custom OpenAI-compatible base URL; there is no public Cursor chat API)".into(),
                    ready: true,
                },
            ));
        }
        if cursor::load_from_path(&self.paths.cursor_auth).is_some() {
            return Err(crate::error::BoltError::auth(
                "Cursor CLI login was found, but Cursor does not publish a chat-completions API. Install the `agent` / `cursor-agent` CLI so Boltbar can reuse that login, or set an OpenAI-compatible Cursor proxy URL.",
            ));
        }
        Err(crate::error::BoltError::auth(
            "No Cursor credentials. Install the Cursor CLI and run `agent login`, add a CURSOR_API_KEY plus a custom base URL, or pick another provider.",
        ))
    }
}

fn claude_credentials(resolver: &Resolver<'_>) -> Option<ClaudeAuth> {
    claude::load_from_claude_keychain()
        .or_else(|| claude::load_from_path(&resolver.paths.claude_credentials))
}

fn chatgpt_usable(file: &CodexAuth) -> Option<(String, Option<String>)> {
    let token = file.access_token.clone()?;
    if !codex::jwt_unexpired(&token) {
        return None;
    }
    Some((token, file.account_id.clone()))
}

fn api(
    provider: ProviderKind,
    kind: AuthKind,
    key: String,
    label: &str,
) -> (ResolvedAuth, AuthStatus) {
    (
        ResolvedAuth::ApiKey(key),
        AuthStatus {
            provider,
            kind,
            label: label.into(),
            ready: true,
        },
    )
}

fn cli_status(provider: ProviderKind, program: String, label: &str) -> (ResolvedAuth, AuthStatus) {
    (
        ResolvedAuth::Cli {
            program,
            extra_env: Vec::new(),
        },
        AuthStatus {
            provider,
            kind: AuthKind::CliBinary,
            label: label.into(),
            ready: true,
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::commands::FakeCommands;
    use crate::auth::secrets::MemoryStore;

    fn paths_in(tmp: &std::path::Path) -> AuthPaths {
        AuthPaths {
            codex_auth: tmp.join("codex.json"),
            claude_credentials: tmp.join("claude.json"),
            cursor_auth: tmp.join("cursor.json"),
        }
    }

    #[test]
    fn keychain_beats_env_and_cli_file() {
        let store = MemoryStore::new();
        store.set("openai", "sk-keychain").unwrap();
        let tmp = std::env::temp_dir().join(format!("bb-auth-{}", uuid::Uuid::new_v4()));
        let _ = std::fs::create_dir_all(&tmp);
        std::fs::write(
            tmp.join("codex.json"),
            r#"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-file"}"#,
        )
        .unwrap();
        let paths = paths_in(&tmp);
        let commands = FakeCommands::default();
        let resolver = Resolver {
            secrets: &store,
            paths: &paths,
            commands: &commands,
            env: EnvSnapshot {
                openai_api_key: Some("sk-env".into()),
                ..EnvSnapshot::default()
            },
        };
        let (auth, status) = resolver.resolve(ProviderKind::Openai).unwrap();
        assert_eq!(status.kind, AuthKind::ApiKey);
        match auth {
            ResolvedAuth::ApiKey(k) => assert_eq!(k, "sk-keychain"),
            _ => panic!("expected api key"),
        }
        let _ = std::fs::remove_dir_all(tmp);
    }

    #[test]
    fn openai_falls_back_to_codex_cli_for_chatgpt_login() {
        let store = MemoryStore::new();
        let tmp = std::env::temp_dir().join(format!("bb-auth-{}", uuid::Uuid::new_v4()));
        let _ = std::fs::create_dir_all(&tmp);
        std::fs::write(
            tmp.join("codex.json"),
            r#"{"auth_mode":"chatgpt","tokens":{"access_token":"not-a-jwt","account_id":"acc"}}"#,
        )
        .unwrap();
        let paths = paths_in(&tmp);
        let commands = FakeCommands {
            present: vec!["codex".into()],
        };
        let resolver = Resolver {
            secrets: &store,
            paths: &paths,
            commands: &commands,
            env: EnvSnapshot::default(),
        };
        let (auth, status) = resolver.resolve(ProviderKind::Openai).unwrap();
        assert_eq!(status.kind, AuthKind::CliBinary);
        assert!(matches!(auth, ResolvedAuth::Cli { .. }));
        let _ = std::fs::remove_dir_all(tmp);
    }

    #[test]
    fn cursor_without_cli_is_not_ready_even_if_auth_json_exists() {
        let store = MemoryStore::new();
        let tmp = std::env::temp_dir().join(format!("bb-auth-{}", uuid::Uuid::new_v4()));
        let _ = std::fs::create_dir_all(&tmp);
        std::fs::write(tmp.join("cursor.json"), r#"{"accessToken":"jwt"}"#).unwrap();
        let paths = paths_in(&tmp);
        let commands = FakeCommands::default();
        let resolver = Resolver {
            secrets: &store,
            paths: &paths,
            commands: &commands,
            env: EnvSnapshot::default(),
        };
        assert!(resolver.resolve(ProviderKind::Cursor).is_err());
        let _ = std::fs::remove_dir_all(tmp);
    }

    #[test]
    fn demo_is_always_ready() {
        let store = MemoryStore::new();
        let paths = AuthPaths::default();
        let commands = FakeCommands::default();
        let resolver = Resolver {
            secrets: &store,
            paths: &paths,
            commands: &commands,
            env: EnvSnapshot::default(),
        };
        assert!(resolver.status(ProviderKind::Demo).ready);
    }
}
