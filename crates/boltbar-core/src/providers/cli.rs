use crate::attachments::prompt_suffix_for_text_files;
use crate::error::{BoltError, Result};
use crate::types::{ChatRequest, ProviderKind, ResolvedAuth, Role, StreamEvent};
use std::process::Stdio;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
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

    if req.attachments.iter().any(|a| crate::attachments::is_image(&a.mime)) {
        return Err(BoltError::msg("Image attachments require an API key transport; this CLI transport supports text files only."));
    }
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
                "-c",
                &format!("model_reasoning_effort=\"{}\"", req.effort.as_str()),
                "-m",
                &req.model,
                "-",
            ]);
        }
        ProviderKind::Anthropic => {
            cmd.args(["-p", "--verbose", "--include-partial-messages", "--output-format", "stream-json",
                "--model", &req.model, "--effort", req.effort.as_str(), "--tools", ""]);
            cmd.arg("--").arg(&prompt);
        }
        ProviderKind::Cursor => {
            cmd.args([
                "-p",
                "--output-format",
                "stream-json",
                "--stream-partial-output",
                "--mode",
                "ask",
                "--model",
                &req.model,
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

    if req.provider != ProviderKind::Openai { cmd.stdin(Stdio::null()); }
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

    // Drain concurrently: a full stderr pipe otherwise deadlocks the child.
    let stderr = child.stderr.take();
    let stderr_task = tokio::spawn(async move {
        let mut saved = Vec::new();
        if let Some(mut stderr) = stderr {
            let mut buffer = [0u8; 4096];
            while let Ok(n) = stderr.read(&mut buffer).await {
                if n == 0 { break; }
                let room = 8192usize.saturating_sub(saved.len());
                saved.extend_from_slice(&buffer[..n.min(room)]);
            }
        }
        String::from_utf8_lossy(&saved).into_owned()
    });
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| BoltError::msg("CLI produced no stdout"))?;
    let mut lines = BufReader::new(stdout).lines();
    let mut emitted = 0usize;
    let mut saw_partial = false;

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
                let value: serde_json::Value = serde_json::from_str(&line).unwrap_or_default();
                let kind = value["type"].as_str().unwrap_or("");
                if kind == "stream_event" || kind == "content_block_delta" { saw_partial = true; }
                if saw_partial && kind == "assistant" { continue; }
                if kind == "result" && value["is_error"].as_bool() == Some(true) {
                    return Err(BoltError::msg("CLI reported an error. Check its login and model availability."));
                }
                for text in parse_cli_line(req.provider, &line) {
                    emitted += text.len();
                    let _ = tx.send(StreamEvent::Delta { text }).await;
                }
            }
        }
    }

    let status = child.wait().await?;
    let err = stderr_task.await.unwrap_or_default();
    if !status.success() {
        return Err(BoltError::msg(format!("CLI exited with {status}: {}", err.trim())));
    }
    if emitted == 0 { return Err(BoltError::msg("CLI completed without a text response")); }
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
    if kind == "stream_event" {
        return value.pointer("/event/delta/text").and_then(|v| v.as_str())
            .filter(|s| !s.is_empty()).map(str::to_owned);
    }
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
    fn parses_actual_claude_partial_envelope() {
        assert_eq!(parse_claude_line(r#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"café"}}}"#).as_deref(), Some("café"));
    }

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
            model: "gpt-6-astra".into(),
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
            effort: crate::types::ThinkingEffort::Medium,
        };
        let prompt = build_prompt(&req);
        assert!(prompt.contains("System: short"));
        assert!(prompt.contains("hi"));
    }

    #[test]
    fn cli_prompt_is_plain_text_not_a_responses_input_string() {
        let req = ChatRequest {
            provider: ProviderKind::Openai,
            model: "gpt-6.1-sol".into(),
            messages: vec![crate::types::ChatMessage {
                role: Role::User,
                content: "quien gobierna en ceuta".into(),
            }],
            attachments: vec![],
            effort: crate::types::ThinkingEffort::Medium,
        };
        let prompt = build_prompt(&req);
        assert_eq!(prompt, "quien gobierna en ceuta");
    }
}
