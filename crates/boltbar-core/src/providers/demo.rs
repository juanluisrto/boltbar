use crate::error::{BoltError, Result};
use crate::types::StreamEvent;
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub const DEMO_MARKDOWN: &str = "Boltbar is ready.\n\nSummon this bar with **Opt+Space**. It starts a new conversation every time, streams tokens as they arrive, and renders markdown — including fenced code:\n\n```rust\nfn hello() {\n    println!(\"streaming, token by token\");\n}\n```\n\nDrop images or files onto the window, paste them, or pick from disk. Keys stay in the **macOS Keychain**, never in a settings file.\n";

pub async fn stream_demo(
    tx: mpsc::Sender<StreamEvent>,
    cancel: CancellationToken,
) -> Result<()> {
    for word in tokenize_demo(DEMO_MARKDOWN) {
        if cancel.is_cancelled() {
            return Err(BoltError::Cancelled);
        }
        let _ = tx.send(StreamEvent::Delta { text: word }).await;
        tokio::time::sleep(std::time::Duration::from_millis(18)).await;
    }
    let _ = tx.send(StreamEvent::Done).await;
    Ok(())
}

pub fn tokenize_demo(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut buf = String::new();
    for ch in text.chars() {
        buf.push(ch);
        if ch.is_whitespace() {
            out.push(std::mem::take(&mut buf));
        }
    }
    if !buf.is_empty() {
        out.push(buf);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn demo_tokens_reassemble() {
        let joined: String = tokenize_demo(DEMO_MARKDOWN).concat();
        assert_eq!(joined, DEMO_MARKDOWN);
        assert!(tokenize_demo(DEMO_MARKDOWN).len() > 8);
    }
}
