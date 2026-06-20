import { describe, it, expect, vi, afterEach } from "vitest"
import { api } from "./api"

// PRODUCT-MATURITY-LOOP D11: request() must not call res.json() on a 204
// No Content response (DeleteServer), which would throw and surface as a
// false "delete failed" toast even though the request succeeded.

function mockFetch(res: Partial<Response> & { status: number }) {
  const full = {
    ok: res.status >= 200 && res.status < 300,
    json: async () => ({}),
    text: async () => "",
    ...res,
  } as Response
  vi.stubGlobal("fetch", vi.fn(async () => full))
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("api.request", () => {
  it("resolves without throwing on 204 No Content (DELETE)", async () => {
    mockFetch({ status: 204, json: async () => { throw new Error("Unexpected end of JSON input") } })
    await expect(api.del("/admin/servers/1")).resolves.toBeUndefined()
  })

  it("parses and returns the body on a normal 200", async () => {
    mockFetch({ status: 200, json: async () => ({ status: "ok" }) })
    await expect(api.post("/admin/servers", { key: "x" })).resolves.toEqual({ status: "ok" })
  })

  it("throws on a non-ok status with the server detail", async () => {
    mockFetch({ status: 400, text: async () => "bad request" })
    await expect(api.get("/admin/whatever")).rejects.toThrow("bad request")
  })

  it("masks 5xx bodies behind a generic message", async () => {
    mockFetch({ status: 500, text: async () => "stack trace leak" })
    await expect(api.get("/admin/whatever")).rejects.toThrow("Server error. Please try again.")
  })
})
