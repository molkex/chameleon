import { describe, it, expect } from "vitest"
import { deviceName } from "./devices"

describe("deviceName", () => {
  it("maps a known identifier to a human label", () => {
    expect(deviceName("iPhone17,1")).toBe("iPhone 16 Pro")
    expect(deviceName("iPad16,3")).toBe("iPad Pro 11-inch (M4)")
    expect(deviceName("arm64")).toBe("Simulator (Apple Silicon)")
  })

  it("falls back to the raw identifier when unknown", () => {
    expect(deviceName("iPhone99,9")).toBe("iPhone99,9")
  })

  it("trims surrounding whitespace before lookup", () => {
    expect(deviceName("  iPhone17,1  ")).toBe("iPhone 16 Pro")
  })

  it("returns an em dash for null / undefined / empty / blank", () => {
    expect(deviceName(null)).toBe("—")
    expect(deviceName(undefined)).toBe("—")
    expect(deviceName("")).toBe("—")
    expect(deviceName("   ")).toBe("—")
  })
})
