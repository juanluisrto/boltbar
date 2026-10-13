use crate::attachments::validate_attachments;
use crate::auth::commands::SystemCommands;
use crate::auth::resolve::{AuthPaths, EnvSnapshot, Resolver};
use crate::auth::secrets::SecretStore;
use crate::error::{BoltError, Result};
use crate::providers::{anthropic, cli, cursor, demo, openai};
use crate::settings::{models_for, Settings};
use crate::types::{
    AuthStatus, ProviderInfo, ProviderKind, ResolvedAuth, StreamEvent,
};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::{mpsc, Mutex};
use tokio_util::sync::CancellationToken;

#[derive(Clone)]
pub struct Engine {
    pub http: reqwest::Client,
    pub secrets: Arc<dyn SecretStore>,
    pub paths: AuthPaths,
    pub cursor_base_url: Arc<StdMutex<Option<String>>>,
    cancel: Arc<Mutex<Option<CancellationToken>>>,
}

impl Engine {
    pub fn new(secrets: Arc<dyn SecretStore>, paths: AuthPaths) -> Result<Self> {
        let http = reqwest::Client::builder()
            .user_agent("boltbar/0.1")
            .build()?;
        Ok(Self {
            http,
            secrets,
            paths,
            cursor_base_url: Arc::new(StdMutex::new(None)),
            cancel: Arc::new(Mutex::new(None)),
        })
    }

    pub fn providers(&self, settings: &Settings) -> Vec<ProviderInfo> {
        ProviderKind::all()
            .iter()
            .copied()
            .map(|id| ProviderInfo {
                id,
                name: id.label().into(),
                models: models_for(id).iter().map(|s| (*s).to_string()).collect(),
                default_model: settings.model_for(id),
                supports_attachments: !matches!(id, ProviderKind::Demo),
                auth: self.auth_status(id),
            })
            .collect()
    }

    pub fn auth_status(&self, provider: ProviderKind) -> AuthStatus {
        let commands = SystemCommands;
        let resolver = Resolver {
            secrets: self.secrets.as_ref(),
            paths: &self.paths,
            commands: &commands,
            env: EnvSnapshot::from_process(),
        };
        resolver.status(provider)
    }

    pub fn resolve(&self, provider: ProviderKind) -> Result<(ResolvedAuth, AuthStatus)> {
        let commands = SystemCommands;
        let resolver = Resolver {
            secrets: self.secrets.as_ref(),
            paths: &self.paths,
            commands: &commands,
            env: EnvSnapshot::from_process(),
        };
        resolver.resolve(provider)
    }

    pub async fn cancel_active(&self) {
        if let Some(token) = self.cancel.lock().await.take() {
            token.cancel();
        }
    }

    pub async fn stream_chat(&self, req: crate::types::ChatRequest, tx: mpsc::Sender<StreamEvent>) {
        if let Err(err) = validate_attachments(&req.attachments) {
            let _ = tx.send(StreamEvent::Error { message: err }).await;
            return;
        }
        let cancel = CancellationToken::new();
        {
            let mut slot = self.cancel.lock().await;
            if let Some(prev) = slot.take() {
                prev.cancel();
            }
            *slot = Some(cancel.clone());
        }

        let result = self.dispatch(&req, tx.clone(), cancel).await;
        if let Err(err) = result {
            match err {
                BoltError::Cancelled => {
                    let _ = tx.send(StreamEvent::Done).await;
                }
                other => {
                    let _ = tx
                        .send(StreamEvent::Error {
                            message: other.to_string(),
                        })
                        .await;
                }
            }
        }
    }

    async fn dispatch(
        &self,
        req: &crate::types::ChatRequest,
        tx: mpsc::Sender<StreamEvent>,
        cancel: CancellationToken,
    ) -> Result<()> {
        if req.provider == ProviderKind::Demo {
            return demo::stream_demo(tx, cancel).await;
        }

        let (auth, _) = self.resolve(req.provider)?;
        if matches!(auth, ResolvedAuth::Cli { .. }) {
            return cli::stream_cli(req, &auth, tx, cancel).await;
        }

        match req.provider {
            ProviderKind::Openai => match &auth {
                ResolvedAuth::ApiKey(_) => {
                    openai::stream_chat_completions(&self.http, req, &auth, tx, cancel).await
                }
                ResolvedAuth::Bearer { token, account_id } => {
                    openai::stream_chatgpt_responses(
                        &self.http,
                        req,
                        token,
                        account_id.as_deref(),
                        tx,
                        cancel,
                    )
                    .await
                }
                ResolvedAuth::Cli { .. } => unreachable!(),
            },
            ProviderKind::Anthropic => {
                anthropic::stream_messages(&self.http, req, &auth, tx, cancel).await
            }
            ProviderKind::Cursor => {
                let base = self.cursor_base_url.lock().unwrap().clone();
                let Some(base) = base.filter(|s| !s.is_empty()) else {
                    return Err(BoltError::auth(
                        "Cursor has no public chat API. Install the Cursor CLI (`agent`) or set a custom OpenAI-compatible base URL in Settings.",
                    ));
                };
                cursor::stream_openai_compatible(&self.http, &base, req, &auth, tx, cancel).await
            }
            ProviderKind::Demo => demo::stream_demo(tx, cancel).await,
        }
    }
}
