//! Domain models with multi-server identity (serverId, remoteId).

pub mod series;
pub mod server_profile;

pub use series::{Series, SeriesMetadata, SeriesPage};
pub use server_profile::{AuthType, ServerProfile};
