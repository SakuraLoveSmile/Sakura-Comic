//! API transport: HTTP client, authentication, pagination, retry,
//! error mapping and SSE connection.
//!
//! Contracts: `specs/openapi/komga-openapi.yaml`, `specs/events/komga-sse-events.md`.

pub mod auth;
pub mod contract;
pub mod error;
pub mod series;
pub mod server;
pub mod url;
