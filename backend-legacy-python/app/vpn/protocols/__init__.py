"""Protocol plugins — register all protocols here."""

from . import registry  # noqa: F401
from .anytls import AnyTLS
from .hysteria2 import Hysteria2
from .naiveproxy import NaiveProxy
from .vless_cdn import VlessCdn
from .vless_reality import VlessReality
from .warp import Warp
from .xdns import Xdns
from .xicmp import Xicmp

registry.register(VlessReality())
registry.register(VlessCdn())
registry.register(Hysteria2())
registry.register(Warp())
registry.register(AnyTLS())
registry.register(NaiveProxy())
registry.register(Xdns())
registry.register(Xicmp())
