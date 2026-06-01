import { describe, it, expect } from "vitest"
import { cn } from "./utils"

describe("cn", () => {
  it("joins truthy class names", () => {
    expect(cn("a", "b")).toBe("a b")
  })

  it("drops falsy / conditional values", () => {
    expect(cn("a", false, null, undefined, "", "b")).toBe("a b")
    expect(cn("base", { active: true, hidden: false })).toBe("base active")
  })

  it("merges conflicting tailwind utilities (last wins)", () => {
    expect(cn("p-2", "p-4")).toBe("p-4")
    expect(cn("text-sm text-lg")).toBe("text-lg")
  })
})
