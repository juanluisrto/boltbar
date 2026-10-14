use crate::attachments::{is_image, prompt_suffix_for_text_files};
use crate::error::{BoltError, Result};
use crate::sse::{extract_anthropic_delta, SseParser};
use crate::types::{ChatRequest, ResolvedAuth, Role, StreamEvent};
use futures_util::StreamExt;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

const ANTHROPIC_VERSION: &str = "2023-06-01";
const OAUTH_BETA: &str = "oauth-2025-04-20";

pub fn messages_body(req: &ChatRequest) -> serde_json::Value {
    let suffix = prompt_suffix_for_text_files(&req.attachments);
    let images: Vec<&crate::types::Attachment> = req
        .attachments
        .iter()
        .filter(|a| is_image(&a.mime))
        .collect();

    let mut system = String::new();
    let mut messages = Vec::new();
    let total = req.messages.len();
    for (idx, msg) in req.messages.iter().enumerate() {
        match msg.role {
            Role::System => {
                if !system.is_empty() {
                    system.push('\n');
                }
                system.push_str(&msg.content);
            }
            Role::User | Role::Assistant => {
                let is_last_user = idx + 1 == total && msg.role == Role::User;
                let text = if is_last_user {
                    format!("{}{suffix}", msg.content)
                } else {
                    msg.content.clone()
                };
                if is_last_user && !images.is_empty() {
                    let mut parts = vec![serde_json::json!({"type":"text","text": text})];
                    for img in &images {
                        let media = match img.mime.as_str() {
                            "image/png" | "image/jpeg" | "image/gif" | "image/webp" => {
                                img.mime.as_str()
                            }
                            _ => "image/png",
                        };
                        parts.push(serde_json::json!({
                            "type": "image",
                            "source": {
                                "type": "base64",
                                "media_type": media,
                                "data": img.data_base64
                            }
                        }));
                    }
                    messages.push(serde_json::json!({
                        "role": if msg.role == Role::User { "user" } else { "assistant" },
                        "content": parts
                    }));
                } else {
                    messages.push(serde_json::json!({
                        "role": if msg.role == Role::User { "user" } else { "assistant" },
                        "content": text
                    }));
                }
            }
        }
    }

    let mut body = serde_json::json!({
        "model": req.model,
        "max_tokens": 8192,
        "stream": true,
        "messages": messages,
        "thinking": { "type": "adaptive" },
        "output_config": { "effort": req.effort.as_str() }
    });
    if !system.is_empty() {
        body["system"] = serde_json::Value::String(system);
    }
    body
}

pub async fn stream_messages(
    http: &reqwest::Client,
    req: &ChatRequest,
    auth: &ResolvedAuth,
    tx: mpsc::Sender<StreamEvent>,
    cancel: CancellationToken,
) -> Result<()> {
    let mut headers = HeaderMap::new();
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert(
        "anthropic-version",
        HeaderValue::from_static(ANTHROPIC_VERSION),
    );
    match auth {
        ResolvedAuth::ApiKey(key) => {
            headers.insert(
                "x-api-key",
                HeaderValue::from_str(key).map_err(|_| BoltError::msg("invalid API key"))?,
            );
        }
        ResolvedAuth::Bearer { token, .. } => {
            headers.insert(
                AUTHORIZATION,
                HeaderValue::from_str(&format!("Bearer {token}"))
                    .map_err(|_| BoltError::msg("invalid OAuth token"))?,
            );
            headers.insert("anthropic-beta", HeaderValue::from_static(OAUTH_BETA));
        }
        ResolvedAuth::Cli { .. } => {
            return Err(BoltError::auth("Claude CLI transport should be used instead"));
        }
    }

    let resp = http
        .post("https://api.anthropic.com/v1/messages")
        .headers(headers)
        .json(&messages_body(req))
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status().as_u16();
        let body = resp.text().await.unwrap_or_default();
        return Err(BoltError::Http { status, body });
    }

    let mut stream = resp.bytes_stream();
    let mut parser = SseParser::new();
    while let Some(chunk) = stream.next().await {
        if cancel.is_cancelled() {
            return Err(BoltError::Cancelled);
        }
        let chunk = chunk?;
        for ev in parser.push_bytes(&chunk) {
            if ev.event == "message_stop" {
                let _ = tx.send(StreamEvent::Done).await;
                return Ok(());
            }
            if let Some(delta) = extract_anthropic_delta(&ev.event, &ev.data) {
                let _ = tx.send(StreamEvent::Delta { text: delta }).await;
            }
        }
    }
    let _ = tx.send(StreamEvent::Done).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Attachment, ChatMessage, ProviderKind};
    use base64::Engine;

    #[test]
    fn splits_system_and_inlines_images() {
        let img = Attachment {
            name: "x.png".into(),
            mime: "image/png".into(),
            data_base64: base64::engine::general_purpose::STANDARD.encode(b"img"),
        };
        let req = ChatRequest {
            provider: ProviderKind::Anthropic,
            model: "claude-sonnet-5-5".into(),
            messages: vec![
                ChatMessage {
                    role: Role::System,
                    content: "be brief".into(),
                },
                ChatMessage {
                    role: Role::User,
                    content: "describe".into(),
                },
            ],
            attachments: vec![img],
            effort: crate::types::ThinkingEffort::Low,
        };
        let body = messages_body(&req);
        assert_eq!(body["system"], "be brief");
        assert_eq!(body["messages"][0]["content"][1]["type"], "image");
        assert_eq!(body["output_config"]["effort"], "low");
        assert_eq!(body["thinking"]["type"], "adaptive");
    }

    #[test]
    fn anthropic_messages_body_is_a_list() {
        let req = ChatRequest {
            provider: ProviderKind::Anthropic,
            model: "claude-sonnet-5-5".into(),
            messages: vec![ChatMessage {
                role: Role::User,
                content: "quien gobierna en ceuta".into(),
            }],
            attachments: vec![],
            effort: crate::types::ThinkingEffort::Medium,
        };
        let body = messages_body(&req);
        assert!(body["messages"].is_array());
        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["messages"][0]["content"], "quien gobierna en ceuta");
        assert_eq!(body["output_config"]["effort"], "medium");
    }
}
