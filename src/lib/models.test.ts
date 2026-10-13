import { describe, expect, it } from "vitest";
import { fileKindLabel, modelDisplayName } from "./models";

describe("modelDisplayName", () => {
  it("formats current flagship ids", () => {
    expect(modelDisplayName("gpt-6-astra")).toBe("GPT-6 Astra");
    expect(modelDisplayName("gpt-6.1-sol")).toBe("GPT-6.1 Sol");
    expect(modelDisplayName("claude-sonnet-5-5")).toBe("Claude Sonnet 5.5");
    expect(modelDisplayName("claude-fable-5-1")).toBe("Claude Fable 5.1");
    expect(modelDisplayName("composer-2.5")).toBe("Composer 2.5");
    expect(modelDisplayName("auto")).toBe("Auto");
  });
});

describe("fileKindLabel", () => {
  it("uses a short type badge", () => {
    expect(fileKindLabel("brief.pdf", "application/pdf")).toBe("PDF");
    expect(fileKindLabel("notes.md", "text/markdown")).toBe("MD");
  });
});
