import { describe, expect, it } from "vitest";
import { closeOpenFences, isBlank } from "./markdown";

describe("closeOpenFences", () => {
  it("closes a dangling fence so streaming markdown still renders", () => {
    const raw = "hello\n```rust\nfn x() {";
    expect(closeOpenFences(raw)).toBe(`${raw}\n\`\`\``);
  });

  it("leaves balanced fences alone", () => {
    const raw = "```js\n1\n```";
    expect(closeOpenFences(raw)).toBe(raw);
  });
});

describe("isBlank", () => {
  it("treats whitespace as empty", () => {
    expect(isBlank("  \n")).toBe(true);
    expect(isBlank("hi")).toBe(false);
  });
});
