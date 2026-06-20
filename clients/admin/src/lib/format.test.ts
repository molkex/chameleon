import { describe, it, expect } from "vitest"
import { countryFlag, relativeTime, jsonParseError } from "./format"

describe("countryFlag", () => {
  it("maps a 2-letter ISO code to its flag emoji", () => {
    expect(countryFlag("RU")).toBe("🇷🇺")
    expect(countryFlag("US")).toBe("🇺🇸")
    expect(countryFlag("NL")).toBe("🇳🇱")
  })
  it("is case-insensitive", () => {
    expect(countryFlag("ru")).toBe("🇷🇺")
  })
  it("returns empty for invalid input", () => {
    expect(countryFlag("")).toBe("")
    expect(countryFlag("X")).toBe("")
    expect(countryFlag("USA")).toBe("")
  })
})

describe("relativeTime", () => {
  it("renders compact RU buckets", () => {
    expect(relativeTime(new Date(Date.now() - 30 * 1000).toISOString())).toBe("только что")
    expect(relativeTime(new Date(Date.now() - 5 * 60_000).toISOString())).toBe("5м")
    expect(relativeTime(new Date(Date.now() - 2 * 3_600_000).toISOString())).toBe("2ч")
    expect(relativeTime(new Date(Date.now() - 3 * 86_400_000).toISOString())).toBe("3д")
  })
  it("returns em dash for empty / unparseable", () => {
    expect(relativeTime("")).toBe("—")
    expect(relativeTime("not-a-date")).toBe("—")
  })
})

describe("jsonParseError", () => {
  it("returns null for empty / whitespace (no value)", () => {
    expect(jsonParseError("")).toBeNull()
    expect(jsonParseError("   ")).toBeNull()
  })
  it("returns null for valid JSON", () => {
    expect(jsonParseError('{"a":1}')).toBeNull()
    expect(jsonParseError('[{"name":"NL"}]')).toBeNull()
  })
  it("returns an error message for malformed JSON", () => {
    expect(jsonParseError("{bad")).toBeTruthy()
    expect(jsonParseError("not json")).toBeTruthy()
    expect(jsonParseError('[{"name":}]')).toBeTruthy()
  })
})
