/** Close dangling fenced code blocks so mid-stream markdown still renders. */
export function closeOpenFences(markdown: string): string {
  const fence = /^(`{3,}|~{3,})/;
  let open = 0;
  for (const line of markdown.split(/\r?\n/)) {
    if (fence.test(line.trim())) {
      open += 1;
    }
  }
  if (open % 2 === 1) {
    return `${markdown}\n\`\`\``;
  }
  return markdown;
}

export function isBlank(text: string): boolean {
  return text.trim().length === 0;
}
