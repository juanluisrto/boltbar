use crate::error::Result;
#[cfg(target_os = "macos")]
use crate::error::BoltError;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// Secret storage. On macOS this is the system Keychain. Elsewhere it is
/// process memory so API keys are never written to a file by Boltbar.
pub trait SecretStore: Send + Sync {
    fn get(&self, account: &str) -> Result<Option<String>>;
    fn set(&self, account: &str, secret: &str) -> Result<()>;
    fn delete(&self, account: &str) -> Result<()>;
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub const KEYCHAIN_SERVICE: &str = "com.boltbar.keys";

#[derive(Default, Clone)]
pub struct MemoryStore {
    inner: Arc<Mutex<HashMap<String, String>>>,
}

impl MemoryStore {
    pub fn new() -> Self {
        Self::default()
    }
}

impl SecretStore for MemoryStore {
    fn get(&self, account: &str) -> Result<Option<String>> {
        Ok(self.inner.lock().unwrap().get(account).cloned())
    }

    fn set(&self, account: &str, secret: &str) -> Result<()> {
        self.inner
            .lock()
            .unwrap()
            .insert(account.to_string(), secret.to_string());
        Ok(())
    }

    fn delete(&self, account: &str) -> Result<()> {
        self.inner.lock().unwrap().remove(account);
        Ok(())
    }
}

#[cfg(target_os = "macos")]
pub struct KeychainStore;

#[cfg(target_os = "macos")]
impl SecretStore for KeychainStore {
    fn get(&self, account: &str) -> Result<Option<String>> {
        match security_framework::passwords::get_generic_password(KEYCHAIN_SERVICE, account) {
            Ok(bytes) => {
                let text = String::from_utf8(bytes)
                    .map_err(|_| BoltError::msg("keychain entry is not valid utf-8"))?;
                if text.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(text))
                }
            }
            Err(e) if e.code() == -25300 => Ok(None),
            Err(e) => Err(BoltError::msg(format!("keychain read failed: {e}"))),
        }
    }

    fn set(&self, account: &str, secret: &str) -> Result<()> {
        security_framework::passwords::set_generic_password(
            KEYCHAIN_SERVICE,
            account,
            secret.as_bytes(),
        )
        .map_err(|e| BoltError::msg(format!("keychain write failed: {e}")))
    }

    fn delete(&self, account: &str) -> Result<()> {
        match security_framework::passwords::delete_generic_password(KEYCHAIN_SERVICE, account) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == -25300 => Ok(()),
            Err(e) => Err(BoltError::msg(format!("keychain delete failed: {e}"))),
        }
    }
}

pub fn default_store() -> Arc<dyn SecretStore> {
    #[cfg(target_os = "macos")]
    {
        Arc::new(KeychainStore)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Arc::new(MemoryStore::new())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn memory_store_round_trip() {
        let store = MemoryStore::new();
        assert_eq!(store.get("openai").unwrap(), None);
        store.set("openai", "sk-test").unwrap();
        assert_eq!(store.get("openai").unwrap().as_deref(), Some("sk-test"));
        store.delete("openai").unwrap();
        assert_eq!(store.get("openai").unwrap(), None);
    }
}
