//! VPN protocol plugin system — trait, types, registry, implementations.

pub mod types;
pub mod registry;
pub mod vless_reality;
pub mod vless_cdn;
pub mod hysteria2;
pub mod warp;
pub mod anytls;
pub mod naiveproxy;
pub mod xdns;
pub mod xicmp;

pub use types::*;
pub use registry::ProtocolRegistry;

#[cfg(test)]
mod tests;
