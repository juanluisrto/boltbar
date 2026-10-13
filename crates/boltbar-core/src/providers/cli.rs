use crate::attachments::prompt_suffix_for_text_files;
use crate::error::{BoltError, Result};
use crate::types::{ChatRequest, ProviderKind, ResolvedAuth, Role, StreamEvent};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::Command;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

/// Official CLI subscription path. Codex, Claude Code, and Cursor Agent all
/// expose NDJSON streams we can map onto token-ish deltas.
pub async fn stream_cli(
    req: &ChatRequest,
    auth: &ResolvedAuth,
    tx: mpsc::Sender<StreamEvent>,
    cancel: CancellationToken,
) -> Result<()> {
    let ResolvedAuth::Cli { program, extra_env } = auth else {
        return Err(BoltError::auth("CLI transport requires a CLI credential"));
    };

    let prompt = build_prompt(req);
    let mut cmd = Command::new(program);
    cmd.kill_on_drop(true)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    match req.provider {
        ProviderKind::Openai => {
            cmd.args([
                "exec",
                "--json",
                "--skip-git-repo-check",
                "-s",
                "read-only",
                "-m",
                &req.model,
                "-",
            ]);
        }
        ProviderKind::Anthropic => {
            cmd.args(["-p", "--output-format", "stream-json"]);
            cmd.arg(&prompt);
        }
        ProviderKind::Cursor => {
            cmd.args([
                "-p",
                "--output-format",
                "stream-json",
                "--stream-partial-output",
            ]);
            cmd.arg(&prompt);
        }
        ProviderKind::Demo => {
            return Err(BoltError::msg("demo provider does not use a CLI"));
        }
    }

    for (k, v) in extra_env {
        cmd.env(k, v);
    }

    let mut child = cmd.spawn().map_err(|e| {
        BoltError::msg(format!(
            "failed to start {program}: {e}. Is the official CLI installed and on PATH?"
        ))
    })?;

    if matches!(req.provider, ProviderKind::Openai) {
        if let Some(mut stdin) = child.stdin.take() {
            use tokio::io::AsyncWriteExt;
            stdin.write_all(prompt.as_bytes()).await?;
            stdin.shutdown().await?;
        }
    }

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| BoltError::msg("CLI produced no stdout"))?;
    let mut lines = BufReader::new(stdout).lines();
    let mut emitted = 0usize;

    loop {
        tokio::select! {
            _ = cancel.cancelled() => {
                let _ = child.start_kill();
                return Err(BoltError::Cancelled);
            }
            line = lines.next_line() => {
                let Some(line) = line? else { break; };
                if line.trim().is_empty() {
                    continue;
                }
                for text in parse_cli_line(req.provider, &line) {
                    emitted += text.len();
                    let _ = tx.send(StreamEvent::Delta { text }).await;
                }
            }
        }
    }

    let status = child.wait().await?;
    if !status.success() && emitted == 0 {
        let mut err = String::new();
        if let Some(stderr) = child.stderr.take() {
            let mut reader = BufReader::new(stderr);
            let mut buf = String::new();
            let _ = reader.read_line(&mut buf).await;
            err = buf;
        }
        return Err(BoltError::msg(format!(
            "{} exited with status {status}: {err}",
            program
        )));
    }
    let _ = tx.send(StreamEvent::Done).await;
    Ok(())
}

pub fn build_prompt(req: &ChatRequest) -> String {
    let mut out = String::new();
    for msg in &req.messages {
        match msg.role {
            Role::System => {
                out.push_str("System: ");
                out.push_str(&msg.content);
                out.push('\n');
            }
            Role::User => {
                out.push_str(&msg.content);
                out.push('\n');
            }
            Role::Assistant => {
                out.push_str("Assistant: ");
                out.push_str(&msg.content);
                out.push('\n');
            }
        }
    }
    out.push_str(&prompt_suffix_for_text_files(&req.attachments));
    out.trim().to_string()
}

pub fn parse_cli_line(provider: ProviderKind, line: &str) -> Vec<String> {
    match provider {
        ProviderKind::Openai => parse_codex_line(line).into_iter().collect(),
        ProviderKind::Anthropic => parse_claude_line(line).into_iter().collect(),
        ProviderKind::Cursor => parse_cursor_line(line).into_iter().collect(),
        ProviderKind::Demo => Vec::new(),
    }
}

pub fn parse_codex_line(line: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let kind = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
    match kind {
        "item.completed" | "item.updated" | "item.delta" => {
            let item = value.get("item")?;
            let item_type = item
                .get("type")
                .or_else(|| item.get("item_type"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if item_type == "agent_message" || item_type == "message" {
                item.get("text")
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                    .map(|s| s.to_string())
            } else {
                None
            }
        }
        _ => value
            .pointer("/item/text")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string()),
    }
}

pub fn parse_claude_line(line: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let kind = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if kind == "content_block_delta" {
        return value
            .pointer("/delta/text")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());
    }
    if let Some(text) = value.pointer("/message/content/0/text").and_then(|v| v.as_str()) {
        if !text.is_empty() && kind == "assistant" {
            return Some(text.to_string());
        }
    }
    None
}

pub fn parse_cursor_line(line: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    let kind = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if kind == "assistant" {
        if let Some(text) = value
            .pointer("/message/content/0/text")
            .or_else(|| value.get("text"))
            .and_then(|v| v.as_str())
        {
            if !text.is_empty() {
                return Some(text.to_string());
            }
        }
    }
    if kind == "stream_event" {
        return value
            .pointer("/event/delta/text")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_codex_agent_message() {
        let line = r#"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"Repo looks fine."}}"#;
        assert_eq!(parse_codex_line(line).as_deref(), Some("Repo looks fine."));
    }

    #[test]
    fn parses_claude_delta_and_cursor_partial() {
        let claude = r#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#;
        assert_eq!(parse_claude_line(claude).as_deref(), Some("Hi"));
        let cursor = r#"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"#;
        assert_eq!(parse_cursor_line(cursor).as_deref(), Some("Hello"));
        let partial = r#"{"type":"stream_event","event":{"delta":{"text":"!"}}}"#;
        assert_eq!(parse_cursor_line(partial).as_deref(), Some("!"));
    }

    #[test]
    fn builds_prompt_with_history() {
        let req = ChatRequest {
            provider: ProviderKind::Openai,
            model: "gpt-4.1".into(),
            messages: vec![
                crate::types::ChatMessage {
                    role: Role::System,
                    content: "short".into(),
                },
                crate::types::ChatMessage {
                    role: Role::User,
                    content: "hi".into(),
                },
            ],
            attachments: vec![],
        };
        let prompt = build_prompt(&req);
        assert!(prompt.contains("System: short"));
        assert!(prompt.contains("hi"));
    }
}
