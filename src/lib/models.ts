function titleWords(id: string): string {
  return id
    .split("-")
    .map((part) => {
      if (/^\d+(?:\.\d+)*$/.test(part)) {
        return part;
      }
      if (part.length === 0) {
        return part;
      }
      return part.charAt(0).toUpperCase() + part.slice(1);
    })
    .join(" ")
    .replace(/(\d) (\d)(?!\d)/g, "$1.$2");
}

/** Human labels for provider model IDs (gpt-6-astra → GPT-6 Astra). */
export function modelDisplayName(id: string): string {
  if (id === "auto") {
    return "Auto";
  }
  if (id === "boltbar-demo") {
    return "Demo";
  }
  if (id.toLowerCase().startsWith("gpt-")) {
    return `GPT-${titleWords(id.slice(4))}`;
  }
  return titleWords(id);
}

export function fileKindLabel(name: string, mime: string): string {
  const ext = name.split(".").pop()?.toUpperCase() ?? "";
  if (mime === "application/pdf" || ext === "PDF") {
    return "PDF";
  }
  if (ext && ext.length <= 5) {
    return ext;
  }
  if (mime.startsWith("text/")) {
    return "TXT";
  }
  return "FILE";
}
