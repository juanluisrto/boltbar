import type { Attachment } from "../types";

const MAX_BYTES = 10 * 1024 * 1024;

export async function fileToAttachment(file: File): Promise<Attachment> {
  if (file.size > MAX_BYTES) {
    throw new Error(`${file.name} is larger than 10 MB`);
  }
  const buffer = await file.arrayBuffer();
  return {
    name: file.name,
    mime: file.type || guessMime(file.name),
    data_base64: arrayBufferToBase64(buffer),
  };
}

export function guessMime(name: string): string {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  switch (ext) {
    case "png":
      return "image/png";
    case "jpg":
    case "jpeg":
      return "image/jpeg";
    case "gif":
      return "image/gif";
    case "webp":
      return "image/webp";
    case "svg":
      return "image/svg+xml";
    case "pdf":
      return "application/pdf";
    case "json":
      return "application/json";
    case "md":
    case "txt":
    case "rs":
    case "ts":
    case "tsx":
    case "js":
      return "text/plain";
    default:
      return "application/octet-stream";
  }
}

export function arrayBufferToBase64(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  const chunk = 0x8000;
  let binary = "";
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

export function attachmentPreviewUrl(att: Attachment): string | null {
  if (!att.mime.startsWith("image/")) {
    return null;
  }
  return `data:${att.mime};base64,${att.data_base64}`;
}

export function isImageAttachment(att: Attachment): boolean {
  return att.mime.startsWith("image/");
}
