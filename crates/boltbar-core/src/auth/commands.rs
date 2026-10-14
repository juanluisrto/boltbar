use std::path::PathBuf;

pub trait CommandProbe: Send + Sync {
    fn find(&self, name: &str) -> Option<PathBuf>;
}

pub struct SystemCommands;

impl CommandProbe for SystemCommands {
    fn find(&self, name: &str) -> Option<PathBuf> {
        which::which(name).ok().or_else(|| {
            let mut dirs = vec![PathBuf::from("/opt/homebrew/bin"), PathBuf::from("/usr/local/bin")];
            if let Some(home) = dirs::home_dir() {
                dirs.push(home.join(".local/bin"));
                dirs.push(home.join(".cargo/bin"));
            }
            dirs.into_iter().map(|dir| dir.join(name)).find(|path| {
                #[cfg(unix)] {
                    use std::os::unix::fs::PermissionsExt;
                    path.metadata().map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
                }
                #[cfg(not(unix))] { path.is_file() }
            })
        })
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
