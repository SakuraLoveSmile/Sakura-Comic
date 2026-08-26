//! Domain models with multi-server identity (serverId, remoteId).

pub mod author;
pub mod book;
pub mod collection;
pub mod readlist;
pub mod series;
pub mod server;
pub mod server_profile;

pub use author::Author;
pub use book::{Book, BookMetadata, BookPage, Media, ReadProgress};
pub use collection::{Collection, CollectionPage};
pub use readlist::{ReadList, ReadListPage};
pub use series::{BookMetadataAggregation, Series, SeriesMetadata, SeriesPage};
pub use server::{Library, ServerInfo};
pub use server_profile::{AuthType, ServerProfile};
