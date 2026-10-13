use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderKind {
    Openai,
    Anthropic,
    Cursor,
    Demo,
}

impl ProviderKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Openai => "openai",
            Self::Anthropic => "anthropic",
            Self::Cursor => "cursor",
            Self::Demo => "demo",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Openai => "OpenAI",
            Self::Anthropic => "Anthropic",
            Self::Cursor => "Cursor",
            Self::Demo => "Demo",
        }
    }

    pub fn all() -> &'static [ProviderKind] {
        &[Self::Openai, Self::Anthropic, Self::Cursor, Self::Demo]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    System,
    User,
    Assistant,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub role: Role,
    pub content: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Attachment {
    pub name: String,
    pub mime: String,
    pub data_base64: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ThinkingEffort {
    Low,
    #[default]
    Medium,
    High,
}

impl ThinkingEffort {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Low => "low",
            Self::Medium => "medium",
            Self::High => "high",
        }
    }

    pub fn all() -> &'static [ThinkingEffort] {
        &[Self::Low, Self::Medium, Self::High]
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ChatRequest {
    pub provider: ProviderKind,
    pub model: String,
    pub messages: Vec<ChatMessage>,
    #[serde(default)]
    pub attachments: Vec<Attachment>,
    #[serde(default)]
    pub effort: ThinkingEffort,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StreamEvent {
    Delta { text: String },
    Done,
    Error { message: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AuthKind {
    ApiKey,
    Env,
    CliApiKey,
    CliOauth,
    CliBinary,
    Missing,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthStatus {
    pub provider: ProviderKind,
    pub kind: AuthKind,
    pub label: String,
    pub ready: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderInfo {
    pub id: ProviderKind,
    pub name: String,
    pub models: Vec<String>,
    pub default_model: String,
    pub supports_attachments: bool,
    pub auth: AuthStatus,
}

#[derive(Debug, Clone)]
pub enum ResolvedAuth {
    ApiKey(String),
    Bearer {
        token: String,
        account_id: Option<String>,
    },
    Cli {
        program: String,
        extra_env: Vec<(String, String)>,
    },
}

impl ResolvedAuth {
    pub fn is_cli(&self) -> bool {
        matches!(self, Self::Cli { .. })
    }
}
