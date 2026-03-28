"""Protocol registry — simple dict-based plugin store."""

from .base import Protocol

_registry: dict[str, Protocol] = {}


def register(protocol: Protocol) -> None:
    _registry[protocol.name] = protocol


def get(name: str) -> Protocol:
    return _registry[name]


def all() -> list[Protocol]:
    return list(_registry.values())


def enabled() -> list[Protocol]:
    return [p for p in _registry.values() if p.enabled]


def with_inbounds() -> list[Protocol]:
    """Protocols that actually generate xray inbounds.

    Filters out outbound-only protocols (WARP, NaiveProxy, etc.) that return
    empty lists from xray_inbounds(). Uses a dummy call to check.
    """
    result = []
    for p in enabled():
        try:
            # Check if protocol produces inbounds with dummy args
            inbounds = p.xray_inbounds([], [""])
            if inbounds:
                result.append(p)
        except Exception:
            # If check fails, include it to be safe
            result.append(p)
    return result


def with_links() -> list[Protocol]:
    """Protocols that generate client subscription links (all enabled by default)."""
    return enabled()
