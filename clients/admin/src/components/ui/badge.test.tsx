import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { Badge } from "./badge"

// Smoke test proving the React Testing Library + jsdom harness works end to end.
describe("Badge", () => {
  it("renders its children", () => {
    render(<Badge>Active</Badge>)
    expect(screen.getByText("Active")).toBeInTheDocument()
  })

  it("defaults to the 'default' variant", () => {
    render(<Badge>Hi</Badge>)
    expect(screen.getByText("Hi")).toHaveAttribute("data-variant", "default")
  })

  it("applies the requested variant and its classes", () => {
    render(<Badge variant="destructive">Banned</Badge>)
    const el = screen.getByText("Banned")
    expect(el).toHaveAttribute("data-variant", "destructive")
    expect(el).toHaveClass("bg-destructive")
  })
})
