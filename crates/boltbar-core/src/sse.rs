/// Incremental Server-Sent Events parser for OpenAI- and Anthropic-style streams.
#[derive(Default)]
pub struct SseParser {
    buf: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SseEvent {
    pub event: String,
    pub data: String,
}

impl SseParser {
    pub fn new() -> Self {
        Self { buf: String::new() }
    }

    pub fn push(&mut self, chunk: &str) -> Vec<SseEvent> {
        self.buf.push_str(chunk);
        let mut out = Vec::new();
        while let Some(idx) = self.buf.find("\n\n") {
            let raw = self.buf[..idx].to_string();
            self.buf = self.buf[idx + 2..].to_string();
            if let Some(ev) = parse_block(&raw) {
                out.push(ev);
            }
        }
        // Also accept CRLF-delimited blocks.
        if out.is_empty() {
            if let Some(idx) = self.buf.find("\r\n\r\n") {
                let raw = self.buf[..idx].to_string();
                self.buf = self.buf[idx + 4..].to_string();
                if let Some(ev) = parse_block(&raw) {
                    out.push(ev);
                }
            }
        }
        out
    }
}

fn parse_block(block: &str) -> Option<SseEvent> {
    let mut event = String::from("message");
    let mut data_lines: Vec<&str> = Vec::new();
    for line in block.lines() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() || line.starts_with(':') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("event:") {
            event = rest.trim().to_string();
        } else if let Some(rest) = line.strip_prefix("data:") {
            data_lines.push(rest.strip_prefix(' ').unwrap_or(rest));
        }
    }
    if data_lines.is_empty() {
        return None;
    }
    Some(SseEvent {
        event,
        data: data_lines.join("\n"),
    })
}

pub fn extract_openai_delta(data: &str) -> Option<String> {
    if data.trim() == "[DONE]" {
        return None;
    }
    let value: serde_json::Value = serde_json::from_str(data).ok()?;
    if let Some(text) = value
        .pointer("/choices/0/delta/content")
        .and_then(|v| v.as_str())
    {
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }
    if let Some(text) = value.pointer("/delta").and_then(|v| v.as_str()) {
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }
    None
}

pub fn extract_openai_done(data: &str) -> bool {
    data.trim() == "[DONE]"
        || data.contains("\"finish_reason\"")
            && value_finish_reason(data).is_some_and(|r| r != "null" && !r.is_empty())
}

fn value_finish_reason(data: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(data).ok()?;
    value
        .pointer("/choices/0/finish_reason")
        .and_then(|v| {
            if v.is_null() {
                None
            } else {
                v.as_str().map(|s| s.to_string())
            }
        })
}

pub fn extract_anthropic_delta(event: &str, data: &str) -> Option<String> {
    if event != "content_block_delta" && event != "message" {
        return None;
    }
    let value: serde_json::Value = serde_json::from_str(data).ok()?;
    if let Some(text) = value.pointer("/delta/text").and_then(|v| v.as_str()) {
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }
    None
}

pub fn extract_responses_delta(data: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(data).ok()?;
    let kind = value.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if kind == "response.output_text.delta" || kind == "response.output_text.delta.delta" {
        if let Some(text) = value.get("delta").and_then(|v| v.as_str()) {
            if !text.is_empty() {
                return Some(text.to_string());
            }
        }
    }
    if let Some(text) = value.pointer("/delta/text").and_then(|v| v.as_str()) {
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }
    None
}

pub fn responses_is_done(data: &str) -> bool {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
        return false;
    };
    matches!(
        value.get("type").and_then(|v| v.as_str()),
        Some("response.completed") | Some("response.done")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_chunked_openai_sse() {
        let mut p = SseParser::new();
        let first = p.push("data: {\"choices\":[{\"delta\":{\"content\":\"Hel");
        assert!(first.is_empty());
        let events = p.push("lo\"}}]}\n\ndata: [DONE]\n\n");
        assert_eq!(events.len(), 2);
        assert_eq!(extract_openai_delta(&events[0].data).as_deref(), Some("Hello"));
        assert!(extract_openai_done(&events[1].data));
    }

    #[test]
    fn parses_anthropic_text_delta() {
        let data = r#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#;
        assert_eq!(
            extract_anthropic_delta("content_block_delta", data).as_deref(),
            Some("Hi")
        );
    }

    #[test]
    fn parses_responses_api_delta() {
        let data = r#"{"type":"response.output_text.delta","delta":"tok"}"#;
        assert_eq!(extract_responses_delta(data).as_deref(), Some("tok"));
        assert!(responses_is_done(r#"{"type":"response.completed"}"#));
    }
}
