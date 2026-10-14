//! Bounded real-provider smoke/TTFT probe. Prints no credential or response content.
use boltbar_core::{auth::{AuthPaths, secrets::default_store}, Engine};
use boltbar_core::types::{ChatMessage, ChatRequest, ProviderKind, Role, StreamEvent, ThinkingEffort};
use std::time::{Duration, Instant};

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let provider = match args.get(1).map(String::as_str) {
        Some("anthropic") => ProviderKind::Anthropic,
        Some("cursor") => ProviderKind::Cursor,
        Some("demo") => ProviderKind::Demo,
        _ => ProviderKind::Openai,
    };
    let model = args.get(2).cloned().unwrap_or_else(|| "gpt-6.1-sol".into());
    let engine = Engine::new(default_store(), AuthPaths::default()).unwrap();
    let auth = engine.auth_status(provider);
    println!("auth: {}", auth.label);
    let request = ChatRequest { provider, model, messages: vec![ChatMessage {
        role: Role::User,
        content: "Do not use any tools or access any files. Write the numbers from 1 to 40, separated by spaces, and nothing else.".into(),
    }], attachments: vec![], effort: ThinkingEffort::Low };
    let (tx, mut rx) = tokio::sync::mpsc::channel(64);
    let started = Instant::now();
    let job = tokio::spawn(async move { engine.stream_chat(request, tx).await; });
    let mut first = None;
    let mut deltas = 0;
    let result = tokio::time::timeout(Duration::from_secs(60), async {
        while let Some(event) = rx.recv().await {
            match event {
                StreamEvent::Delta { text } if !text.is_empty() => { first.get_or_insert(started.elapsed().as_millis()); deltas += 1; },
                StreamEvent::Error { message } => { println!("error: {message}"); return false; },
                StreamEvent::Done => return true,
                _ => {},
            }
        }
        false
    }).await;
    job.abort();
    println!("{}", serde_json::json!({"provider":provider,"ttft_ms":first,"total_ms":started.elapsed().as_millis(),"deltas":deltas,"completed":result.unwrap_or(false)}));
}
