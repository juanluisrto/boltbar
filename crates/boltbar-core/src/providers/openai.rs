use crate::attachments::{is_image, prompt_suffix_for_text_files};
use crate::error::{BoltError, Result};
use crate::sse::{
    extract_openai_delta, extract_openai_done, extract_responses_delta, responses_is_done, SseParser,
};
use crate::types::{ChatMessage, ChatRequest, ResolvedAuth, Role, StreamEvent};
use futures_util::StreamExt;
use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub fn chat_completions_body(req: &ChatRequest) -> serde_json::Value {
    let suffix = prompt_suffix_for_text_files(&req.attachments);
    let images: Vec<&crate::types::Attachment> = req
        .attachments
        .iter()
        .filter(|a| is_image(&a.mime))
        .collect();

    let messages: Vec<serde_json::Value> = req
        .messages
        .iter()
        .enumerate()
        .map(|(idx, msg)| {
            let is_last_user = idx + 1 == req.messages.len() && msg.role == Role::User;
            let text = if is_last_user {
                format!("{}{suffix}", msg.content)
            } else {
                msg.content.clone()
            };
            if is_last_user && !images.is_empty() {
                let mut parts = vec![serde_json::json!({"type":"text","text": text})];
                for img in &images {
                    parts.push(serde_json::json!({
                        "type": "image_url",
                        "image_url": {
                            "url": format!("data:{};base64,{}", img.mime, img.data_base64)
                        }
                    }));
                }
                serde_json::json!({
                    "role": role_name(msg.role),
                    "content": parts
                })
            } else {
                serde_json::json!({
                    "role": role_name(msg.role),
                    "content": text
                })
            }
        })
        .collect();

    serde_json::json!({
        "model": req.model,
        "stream": true,
        "messages": messages,
        "reasoning_effort": req.effort.as_str()
    })
}

/// Official `/v1/responses` and the ChatGPT Codex backend both require
/// `input` as a list of message items — a concatenated string 400s with
/// `{"detail":"Input must be a list"}`.
pub fn responses_input_items(req: &ChatRequest) -> Vec<serde_json::Value> {
    let suffix = prompt_suffix_for_text_files(&req.attachments);
    let images: Vec<&crate::types::Attachment> = req
        .attachments
        .iter()
        .filter(|a| is_image(&a.mime))
        .collect();

    req.messages
        .iter()
        .enumerate()
        .map(|(idx, msg)| {
            let is_last_user = idx + 1 == req.messages.len() && msg.role == Role::User;
            let text = if is_last_user {
                format!("{}{suffix}", msg.content)
            } else {
                msg.content.clone()
            };
            let text_type = match msg.role {
                Role::Assistant => "output_text",
                Role::System | Role::User => "input_text",
            };
            let mut content = vec![serde_json::json!({
                "type": text_type,
                "text": text
            })];
            if is_last_user {
                for img in &images {
                    content.push(serde_json::json!({
                        "type": "input_image",
                        "image_url": format!("data:{};base64,{}", img.mime, img.data_base64)
                    }));
                }
            }
            serde_json::json!({
                "type": "message",
                "role": role_name(msg.role),
                "content": content
            })
        })
        .collect()
}

pub fn responses_body(req: &ChatRequest) -> serde_json::Value {
    serde_json::json!({
        "model": req.model,
        "stream": true,
        "input": responses_input_items(req),
        "reasoning": { "effort": req.effort.as_str() }
    })
}

fn role_name(role: Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
    }
}

pub fn last_user_text(messages: &[ChatMessage]) -> String {
    messages
        .iter()
        .rev()
        .find(|m| m.role == Role::User)
        .map(|m| m.content.clone())
        .unwrap_or_default()
}

pub async fn stream_openai_responses(
    http: &reqwest::Client,
    req: &ChatRequest,
    auth: &ResolvedAuth,
    tx: mpsc::Sender<StreamEvent>,
    cancel: CancellationToken,
) -> Result<()> {
    let ResolvedAuth::ApiKey(key) = auth else {
        return Err(BoltError::auth("OpenAI Responses API requires an API key"));
    };
    let mut headers = HeaderMap::new();
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {key}"))
            .map_err(|_| BoltError::msg("invalid API key header"))?,
    );
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let resp = http
        .post("https://api.openai.com/v1/responses")
        .headers(headers)
        .json(&responses_body(req))
        .send()
        .await?;
    pump_responses_sse(resp, tx, cancel).await
}

pub async fn stream_chatgpt_responses(
    http: &reqwest::Client,
    req: &ChatRequest,
    token: &str,
    account_id: Option<&str>,
    tx: mpsc::Sender<StreamEvent>,
    cancel: CancellationToken,
) -> Result<()> {
    let mut headers = HeaderMap::new();
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer {token}"))
            .map_err(|_| BoltError::msg("invalid ChatGPT token"))?,
    );
    headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
    headers.insert("OpenAI-Beta", HeaderValue::from_static("responses=v1"));
    headers.insert("originator", HeaderValue::from_static("boltbar"));
    if let Some(id) = account_id {
        if let Ok(val) = HeaderValue::from_str(id) {
            headers.insert("chatgpt-account-id", val);
        }
    }
    let resp = http
        .post("https://chatgpt.com/backend-api/codex/responses")
        .headers(headers)
        .json(&responses_body(req))
        .send()
        .await?;
    pump_responses_sse(resp, tx, cancel).await
}

pub async fn pump_openai_sse(
    resp: reqwest::Response,
    tx: mpsc::Sender<StreamEvent>,
    cancel: CancellationToken,
) -> Result<()> {
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
        let text = String::from_utf8_lossy(&chunk);
        for ev in parser.push(&text) {
            if extract_openai_done(&ev.data) {
                let _ = tx.send(StreamEvent::Done).await;
                return Ok(());
            }
            if let Some(delta) = extract_openai_delta(&ev.data) {
                let _ = tx.send(StreamEvent::Delta { text: delta }).await;
            }
        }
    }
    let _ = tx.send(StreamEvent::Done).await;
    Ok(())
}

pub async fn pump_responses_sse(
    resp: reqwest::Response,
    tx: mpsc::Sender<StreamEvent>,
    cancel: CancellationToken,
) -> Result<()> {
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
        let text = String::from_utf8_lossy(&chunk);
        for ev in parser.push(&text) {
            if responses_is_done(&ev.data) {
                let _ = tx.send(StreamEvent::Done).await;
                return Ok(());
            }
            if let Some(delta) = extract_responses_delta(&ev.data) {
                let _ = tx.send(StreamEvent::Delta { text: delta }).await;
            } else if let Some(delta) = extract_openai_delta(&ev.data) {
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
    fn vision_parts_only_on_last_user_message() {
        let img = Attachment {
            name: "cat.png".into(),
            mime: "image/png".into(),
            data_base64: base64::engine::general_purpose::STANDARD.encode(b"img"),
        };
        let req = ChatRequest {
            provider: ProviderKind::Openai,
            model: "gpt-4o".into(),
            messages: vec![ChatMessage {
                role: Role::User,
                content: "what is this?".into(),
            }],
            attachments: vec![img],
            effort: crate::types::ThinkingEffort::Medium,
        };
        let body = chat_completions_body(&req);
        let content = &body["messages"][0]["content"];
        assert!(content.is_array());
        assert_eq!(content[1]["type"], "image_url");
    }

    #[test]
    fn text_files_are_appended_to_prompt() {
        let file = Attachment {
            name: "note.txt".into(),
            mime: "text/plain".into(),
            data_base64: base64::engine::general_purpose::STANDARD.encode(b"secret notes"),
        };
        let req = ChatRequest {
            provider: ProviderKind::Openai,
            model: "gpt-6-astra".into(),
            messages: vec![ChatMessage {
                role: Role::User,
                content: "summarize".into(),
            }],
            attachments: vec![file],
            effort: crate::types::ThinkingEffort::High,
        };
        let body = chat_completions_body(&req);
        let text = body["messages"][0]["content"].as_str().unwrap();
        assert!(text.contains("secret notes"));
        assert_eq!(body["reasoning_effort"], "high");
    }

    fn sample(text: &str) -> ChatRequest {
        ChatRequest {
            provider: ProviderKind::Openai,
            model: "gpt-6.1-sol".into(),
            messages: vec![ChatMessage {
                role: Role::User,
                content: text.into(),
            }],
            attachments: vec![],
            effort: crate::types::ThinkingEffort::Medium,
        }
    }

    #[test]
    fn official_and_chatgpt_responses_send_input_as_message_list() {
        let req = sample("quien gobierna en ceuta");
        let official = responses_body(&req);
        let chatgpt = responses_body(&req);
        assert_eq!(official, chatgpt);
        assert!(
            official["input"].is_array(),
            "input must be a list, got {}",
            official["input"]
        );
        assert_eq!(official["input"][0]["type"], "message");
        assert_eq!(official["input"][0]["role"], "user");
        assert_eq!(official["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(
            official["input"][0]["content"][0]["text"],
            "quien gobierna en ceuta"
        );
        assert_eq!(official["reasoning"]["effort"], "medium");
        assert!(!official["input"].is_string());
    }

    #[test]
    fn responses_input_keeps_history_as_list_items() {
        let req = ChatRequest {
            provider: ProviderKind::Openai,
            model: "gpt-6.1-sol".into(),
            messages: vec![
                ChatMessage {
                    role: Role::User,
                    content: "hola".into(),
                },
                ChatMessage {
                    role: Role::Assistant,
                    content: "hola!".into(),
                },
                ChatMessage {
                    role: Role::User,
                    content: "quien gobierna en ceuta".into(),
                },
            ],
            attachments: vec![],
            effort: crate::types::ThinkingEffort::Low,
        };
        let input = responses_input_items(&req);
        assert_eq!(input.len(), 3);
        assert_eq!(input[1]["role"], "assistant");
        assert_eq!(input[1]["content"][0]["type"], "output_text");
        assert!(responses_body(&req)["input"].is_array());
    }

    #[test]
    fn cursor_openai_compatible_path_still_uses_messages_array() {
        let body = chat_completions_body(&sample("hi"));
        assert!(body["messages"].is_array());
        assert_eq!(body["messages"][0]["role"], "user");
        assert_eq!(body["messages"][0]["content"], "hi");
    }
}
