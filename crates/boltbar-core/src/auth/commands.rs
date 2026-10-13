use std::path::PathBuf;

pub trait CommandProbe: Send + Sync {
    fn find(&self, name: &str) -> Option<PathBuf>;
}

pub struct SystemCommands;

impl CommandProbe for SystemCommands {
    fn find(&self, name: &str) -> Option<PathBuf> {
        which::which(name).ok()
    }
}

#[derive(Default, Clone)]
pub struct FakeCommands {
    pub present: Vec<String>,
}

impl CommandProbe for FakeCommands {
    fn find(&self, name: &str) -> Option<PathBuf> {
        self.present
            .iter()
            .find(|n| n == &name)
            .map(|n| PathBuf::from(n))
    }
}

pub fn first_present(probe: &dyn CommandProbe, names: &[&str]) -> Option<(String, PathBuf)> {
    for name in names {
        if let Some(path) = probe.find(name) {
            return Some(((*name).to_string(), path));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_first_available_binary() {
        let probe = FakeCommands {
            present: vec!["cursor-agent".into()],
        };
        let found = first_present(&probe, &["agent", "cursor-agent"]).unwrap();
        assert_eq!(found.0, "cursor-agent");
    }
}
