use crate::types::ProviderKind;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const DEFAULT_HOTKEY: &str = "alt+space";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Settings {
    pub provider: ProviderKind,
    #[serde(default)]
    pub models: HashMap<String, String>,
    #[serde(default = "default_hotkey")]
    pub hotkey: String,
    #[serde(default = "default_input_height")]
    pub input_height: u32,
    /// Optional OpenAI-compatible base URL for the Cursor provider.
    #[serde(default)]
    pub cursor_base_url: Option<String>,
}

fn default_hotkey() -> String {
    DEFAULT_HOTKEY.into()
}

fn default_input_height() -> u32 {
    72
}

impl Default for Settings {
    fn default() -> Self {
        let mut models = HashMap::new();
        models.insert("openai".into(), default_model(ProviderKind::Openai).into());
        models.insert(
            "anthropic".into(),
            default_model(ProviderKind::Anthropic).into(),
        );
        models.insert("cursor".into(), default_model(ProviderKind::Cursor).into());
        models.insert("demo".into(), default_model(ProviderKind::Demo).into());
        Self {
            provider: ProviderKind::Demo,
            models,
            hotkey: default_hotkey(),
            input_height: default_input_height(),
            cursor_base_url: None,
        }
    }
}

impl Settings {
    pub fn model_for(&self, provider: ProviderKind) -> String {
        self.models
            .get(provider.as_str())
            .cloned()
            .unwrap_or_else(|| default_model(provider).to_string())
    }

    pub fn set_model(&mut self, provider: ProviderKind, model: impl Into<String>) {
        self.models.insert(provider.as_str().into(), model.into());
    }
}

pub fn default_model(kind: ProviderKind) -> &'static str {
    match kind {
        ProviderKind::Openai => "gpt-4.1",
        ProviderKind::Anthropic => "claude-sonnet-4-6",
        ProviderKind::Cursor => "auto",
        ProviderKind::Demo => "boltbar-demo",
    }
}

pub fn models_for(kind: ProviderKind) -> &'static [&'static str] {
    match kind {
        ProviderKind::Openai => &[
            "gpt-4.1",
            "gpt-4.1-mini",
            "gpt-4o",
            "gpt-4o-mini",
            "o4-mini",
            "o3",
        ],
        ProviderKind::Anthropic => &[
            "claude-sonnet-4-6",
            "claude-opus-4-6",
            "claude-haiku-4-5",
            "claude-sonnet-4-5",
            "claude-3-5-haiku-latest",
        ],
        ProviderKind::Cursor => &["auto"],
        ProviderKind::Demo => &["boltbar-demo"],
    }
}

pub fn settings_path(app_data_dir: &Path) -> PathBuf {
    app_data_dir.join("settings.json")
}

pub fn load_settings(app_data_dir: &Path) -> Settings {
    let path = settings_path(app_data_dir);
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Settings::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

pub fn save_settings(app_data_dir: &Path, settings: &Settings) -> crate::error::Result<()> {
    std::fs::create_dir_all(app_data_dir)?;
    let path = settings_path(app_data_dir);
    let raw = serde_json::to_string_pretty(settings)?;
    std::fs::write(path, raw)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_settings_json() {
        let dir = std::env::temp_dir().join(format!("boltbar-settings-{}", uuid::Uuid::new_v4()));
        let mut s = Settings::default();
        s.provider = ProviderKind::Openai;
        s.set_model(ProviderKind::Openai, "gpt-4o-mini");
        save_settings(&dir, &s).unwrap();
        let loaded = load_settings(&dir);
        assert_eq!(loaded.provider, ProviderKind::Openai);
        assert_eq!(loaded.model_for(ProviderKind::Openai), "gpt-4o-mini");
        let _ = std::fs::remove_dir_all(dir);
    }
}
