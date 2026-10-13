use thiserror::Error;

#[derive(Debug, Error)]
pub enum BoltError {
    #[error("{0}")]
    Message(String),

    #[error("{0}")]
    Auth(String),

    #[error("http {status}: {body}")]
    Http { status: u16, body: String },

    #[error(transparent)]
    Io(#[from] std::io::Error),

    #[error(transparent)]
    Json(#[from] serde_json::Error),

    #[error(transparent)]
    HttpClient(#[from] reqwest::Error),

    #[error("cancelled")]
    Cancelled,
}

impl BoltError {
    pub fn msg(text: impl Into<String>) -> Self {
        Self::Message(text.into())
    }

    pub fn auth(text: impl Into<String>) -> Self {
        Self::Auth(text.into())
    }
}

pub type Result<T> = std::result::Result<T, BoltError>;
