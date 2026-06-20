// Shared display + validation helpers (PRODUCT-MATURITY-LOOP D17/D15, 2026-06-21).
// Extracted from byte-identical copies that lived in dashboard.tsx / users.tsx /
// inbox.tsx so they can't drift apart.

/** countryFlag turns a 2-letter ISO country code into its flag emoji. */
export function countryFlag(code: string): string {
  if (!code || code.length !== 2) return "";
  const base = 0x1f1e6;
  const A = "A".charCodeAt(0);
  return (
    String.fromCodePoint(base + code.toUpperCase().charCodeAt(0) - A) +
    String.fromCodePoint(base + code.toUpperCase().charCodeAt(1) - A)
  );
}

/** relativeTime renders a compact RU "time ago" label (только что / 5м / 3ч / 2д). */
export function relativeTime(iso: string): string {
  if (!iso) return "—";
  const then = new Date(iso).getTime();
  if (Number.isNaN(then)) return "—";
  const diff = Date.now() - then;
  const min = Math.floor(diff / 60000);
  if (min < 1) return "только что";
  if (min < 60) return `${min}м`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}ч`;
  const day = Math.floor(hr / 24);
  if (day < 30) return `${day}д`;
  return new Date(iso).toLocaleDateString();
}

/**
 * jsonParseError validates a free-text JSON field. Returns null when the string
 * is empty (treated as "no value") or parses as JSON; otherwise an error message.
 * D15: the Settings page persisted the VPN-servers JSON textarea verbatim with no
 * validation — one typo silently saved malformed config.
 */
export function jsonParseError(s: string): string | null {
  const trimmed = s.trim();
  if (trimmed === "") return null;
  try {
    JSON.parse(trimmed);
    return null;
  } catch (e) {
    return e instanceof Error ? e.message : "Invalid JSON";
  }
}
