use crate::types::Attachment;

pub const MAX_ATTACHMENT_BYTES: usize = 10 * 1024 * 1024;
pub const MAX_ATTACHMENTS: usize = 6;

pub fn is_image(mime: &str) -> bool {
    mime.starts_with("image/")
}

pub fn is_text_like(mime: &str, name: &str) -> bool {
    if mime.starts_with("text/")
        || mime == "application/json"
        || mime == "application/xml"
        || mime == "application/javascript"
        || mime == "application/typescript"
        || mime == "application/x-sh"
        || mime == "application/toml"
    {
        return true;
    }
    matches!(
        extension(name).as_str(),
        "txt"
            | "md"
            | "markdown"
            | "json"
            | "jsonl"
            | "csv"
            | "tsv"
            | "toml"
            | "yaml"
            | "yml"
            | "xml"
            | "html"
            | "css"
            | "js"
            | "ts"
            | "tsx"
            | "jsx"
            | "rs"
            | "py"
            | "go"
            | "rb"
            | "java"
            | "kt"
            | "swift"
            | "c"
            | "h"
            | "cc"
            | "cpp"
            | "hpp"
            | "sh"
            | "zsh"
            | "bash"
            | "sql"
            | "graphql"
            | "env"
            | "log"
    )
}

pub fn extension(name: &str) -> String {
    name.rsplit('.')
        .next()
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default()
}

pub fn decoded_bytes(att: &Attachment) -> Result<Vec<u8>, base64::DecodeError> {
    use base64::Engine;
    let cleaned: String = att.data_base64.chars().filter(|c| !c.is_whitespace()).collect();
    base64::engine::general_purpose::STANDARD.decode(cleaned)
}

pub fn decoded_text(att: &Attachment) -> Option<String> {
    let bytes = decoded_bytes(att).ok()?;
    String::from_utf8(bytes).ok()
}

pub fn validate_attachments(attachments: &[Attachment]) -> Result<(), String> {
    if attachments.len() > MAX_ATTACHMENTS {
        return Err(format!(
            "at most {MAX_ATTACHMENTS} attachments are allowed per message"
        ));
    }
    for att in attachments {
        let bytes = decoded_bytes(att).map_err(|_| format!("could not decode {}", att.name))?;
        if bytes.len() > MAX_ATTACHMENT_BYTES {
            return Err(format!(
                "{} is larger than {} MB",
                att.name,
                MAX_ATTACHMENT_BYTES / (1024 * 1024)
            ));
        }
    }
    Ok(())
}

pub fn prompt_suffix_for_text_files(attachments: &[Attachment]) -> String {
    let mut out = String::new();
    for att in attachments {
        if is_image(&att.mime) {
            continue;
        }
        if let Some(text) = decoded_text(att) {
            out.push_str(&format!(
                "\n\n--- attached file: {} ---\n{}\n--- end {} ---\n",
                att.name, text, att.name
            ));
        } else {
            out.push_str(&format!(
                "\n\n[Binary attachment {} ({}) was not inlined. Use a vision-capable model for images.]\n",
                att.name, att.mime
            ));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn att(name: &str, mime: &str, raw: &[u8]) -> Attachment {
        Attachment {
            name: name.into(),
            mime: mime.into(),
            data_base64: base64::engine::general_purpose::STANDARD.encode(raw),
        }
    }

    #[test]
    fn classifies_images_and_source_files() {
        assert!(is_image("image/png"));
        assert!(is_text_like("text/plain", "notes.txt"));
        assert!(is_text_like("application/octet-stream", "main.rs"));
        assert!(!is_text_like("application/pdf", "doc.pdf"));
    }

    #[test]
    fn rejects_too_many_or_huge_attachments() {
        let ok = att("a.txt", "text/plain", b"hi");
        assert!(validate_attachments(&[ok.clone()]).is_ok());
        let many: Vec<_> = (0..MAX_ATTACHMENTS + 1)
            .map(|i| att(&format!("{i}.txt"), "text/plain", b"x"))
            .collect();
        assert!(validate_attachments(&many).is_err());
    }

    #[test]
    fn inlines_text_and_skips_images() {
        let files = vec![
            att("a.rs", "text/plain", b"fn main() {}"),
            att("pic.png", "image/png", b"\x89PNG"),
        ];
        let suffix = prompt_suffix_for_text_files(&files);
        assert!(suffix.contains("fn main() {}"));
        assert!(!suffix.contains("PNG"));
    }
}
