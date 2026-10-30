pub mod adapter;
pub mod client;
pub mod db;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::RwLock;

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub use adapter::{Asset, BucketInfo};
pub use client::{ImmichClient, ThumbnailSize};
pub use db::DbEngine;

#[derive(Error, Debug)]
pub enum CoreError {
    #[error("Database error: {0}")]
    Db(#[from] db::DbError),
    #[error("Network client error: {0}")]
    Client(#[from] client::ClientError),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("Asset not found: {0}")]
    AssetNotFound(String),
    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),
    #[error("Core engine not initialized")]
    NotInitialized,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetViewerBundle {
    pub asset_id: String,
    pub asset_type: String,
    pub image_path: String,
    pub video_path: Option<String>,
    pub is_live_photo: bool,
    pub duration: Option<String>,
}

#[derive(Clone)]
pub struct ImmichCore {
    pub db: Arc<DbEngine>,
    pub client: Arc<RwLock<ImmichClient>>,
    pub cache_dir: PathBuf,
}

impl ImmichCore {
    pub fn init<P: AsRef<Path>, Q: AsRef<Path>>(
        db_path: P,
        cache_dir: Q,
    ) -> Result<Self, CoreError> {
        let db = Arc::new(DbEngine::open(db_path)?);
        let cache_path = cache_dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&cache_path)?;

        let saved_url = db.get_config("server_url").unwrap_or(None);
        // Credentials live in the platform secure store (Keychain etc.) and are handed
        // to us per session via login_server; never keep a plaintext copy in SQLite.
        // Purge any key persisted by older builds.
        let _ = db.delete_config("api_key");

        let client = Arc::new(RwLock::new(ImmichClient::new(saved_url, None)));

        Ok(Self {
            db,
            client,
            cache_dir: cache_path,
        })
    }

    pub fn init_in_memory<P: AsRef<Path>>(cache_dir: P) -> Result<Self, CoreError> {
        let db = Arc::new(DbEngine::open_in_memory()?);
        let cache_path = cache_dir.as_ref().to_path_buf();
        std::fs::create_dir_all(&cache_path)?;

        let client = Arc::new(RwLock::new(ImmichClient::new(None, None)));

        Ok(Self {
            db,
            client,
            cache_dir: cache_path,
        })
    }

    pub async fn login_server(&self, server_url: &str, api_key: &str) -> Result<String, CoreError> {
        self.db.set_config("server_url", server_url)?;
        // The API key is intentionally kept in memory only.

        {
            let mut client = self.client.write().await;
            client.set_base_url(server_url.to_string());
            client.set_api_key(api_key.to_string());
        }

        // Validate connection
        let client = self.client.read().await;
        let _ = client.ping().await?;

        Ok("Logged in successfully".to_string())
    }

    pub async fn sync_and_get_buckets(&self) -> Result<Vec<BucketInfo>, CoreError> {
        let buckets = {
            let client = self.client.read().await;
            match client.fetch_buckets().await {
                Ok(b) => b,
                Err(e) => {
                    // If network fails, return cached buckets from local db
                    let cached = self.db.get_buckets()?;
                    if !cached.is_empty() {
                        return Ok(cached);
                    }
                    return Err(CoreError::Client(e));
                }
            }
        };

        self.db.upsert_buckets(&buckets)?;
        Ok(buckets)
    }

    /// Retrieve locally cached buckets directly without making a network request.
    pub fn get_cached_buckets(&self) -> Result<Vec<BucketInfo>, CoreError> {
        let cached = self.db.get_buckets()?;
        Ok(cached)
    }

    /// Retrieve locally cached assets for a bucket directly without making a network request.
    pub fn get_cached_bucket_assets(&self, time_bucket: &str) -> Result<Vec<Asset>, CoreError> {
        let cached = self.db.get_assets_by_bucket(time_bucket)?;
        Ok(cached)
    }

    pub async fn fetch_bucket_assets(&self, time_bucket: &str) -> Result<Vec<Asset>, CoreError> {
        let assets = {
            let client = self.client.read().await;
            match client.fetch_bucket_assets(time_bucket).await {
                Ok(a) => a,
                Err(e) => {
                    let cached = self.db.get_assets_by_bucket(time_bucket)?;
                    if !cached.is_empty() {
                        return Ok(cached);
                    }
                    return Err(CoreError::Client(e));
                }
            }
        };

        self.db.upsert_assets(&assets)?;
        Ok(assets)
    }

    pub async fn ensure_asset_cached(
        &self,
        asset_id: &str,
        media_type: &str,
    ) -> Result<String, CoreError> {
        let client = self.client.read().await;

        let path = match media_type {
            "preview" => {
                let file = client
                    .download_image_cache(asset_id, ThumbnailSize::Preview, &self.cache_dir)
                    .await?;
                let path_str = file.to_string_lossy().to_string();
                self.db
                    .update_asset_paths(asset_id, None, Some(&path_str), None)?;
                path_str
            }
            "video" => {
                let file = client
                    .download_video_cache(asset_id, &self.cache_dir)
                    .await?;
                let path_str = file.to_string_lossy().to_string();
                self.db
                    .update_asset_paths(asset_id, None, None, Some(&path_str))?;
                path_str
            }
            _ => {
                // Default to thumbnail
                let file = client
                    .download_image_cache(asset_id, ThumbnailSize::Thumbnail, &self.cache_dir)
                    .await?;
                let path_str = file.to_string_lossy().to_string();
                self.db
                    .update_asset_paths(asset_id, Some(&path_str), None, None)?;
                path_str
            }
        };

        Ok(path)
    }

    pub async fn prepare_asset_viewer_bundle(
        &self,
        asset_id: &str,
    ) -> Result<AssetViewerBundle, CoreError> {
        let asset = self
            .db
            .get_asset(asset_id)?
            .ok_or_else(|| CoreError::AssetNotFound(asset_id.to_string()))?;

        // Ensure preview image is cached
        let image_path = self.ensure_asset_cached(asset_id, "preview").await?;

        // If asset has livePhotoVideoId, ensure motion video is cached
        let mut video_path = None;
        let mut is_live_photo = false;

        if let Some(ref live_vid) = asset.live_photo_video_id {
            if !live_vid.is_empty() {
                if let Ok(v_path) = self.ensure_asset_cached(live_vid, "video").await {
                    video_path = Some(v_path);
                    is_live_photo = true;
                }
            }
        } else if asset.asset_type.eq_ignore_ascii_case("VIDEO") {
            if let Ok(v_path) = self.ensure_asset_cached(asset_id, "video").await {
                video_path = Some(v_path);
            }
        }

        Ok(AssetViewerBundle {
            asset_id: asset.id,
            asset_type: asset.asset_type,
            image_path,
            video_path,
            is_live_photo,
            duration: asset.duration,
        })
    }

    /// Fetches asset EXIF details either from local DB cache or remote server.
    pub async fn get_or_fetch_exif(
        &self,
        asset_id: &str,
    ) -> Result<Option<crate::adapter::ExifResponseDto>, CoreError> {
        // 1. Check local DB
        if let Some(asset) = self.db.get_asset(asset_id)? {
            if let Some(exif) = asset.exif {
                return Ok(Some(exif));
            }
        }

        // 2. Fetch from network
        let client = self.client.read().await;
        if let Ok(Some(exif)) = client.fetch_asset_exif(asset_id).await {
            let _ = self.db.update_asset_exif(asset_id, &exif);
            return Ok(Some(exif));
        }

        Ok(None)
    }

    /// Check upload candidates in bulk, automatically filtering out tombstoned assets.
    pub async fn check_bulk_upload_candidates(
        &self,
        candidates: Vec<client::BulkUploadCheckItem>,
    ) -> Result<Vec<client::BulkUploadCheckResult>, CoreError> {
        // 1. Filter out local assets that are tombstoned
        let mut non_tombstoned = Vec::with_capacity(candidates.len());
        let mut tombstoned_results = Vec::new();

        for item in candidates {
            if self.db.is_upload_tombstoned(&item.id, &self.active_account()).unwrap_or(false) {
                tombstoned_results.push(client::BulkUploadCheckResult {
                    id: item.id,
                    action: "reject".to_string(),
                    reason: Some("tombstoned".to_string()),
                    asset_id: None,
                });
            } else {
                non_tombstoned.push(item);
            }
        }

        // 2. Query remote server
        let mut results = tombstoned_results;
        if !non_tombstoned.is_empty() {
            let client = self.client.read().await;
            let remote_results = client.bulk_upload_check(non_tombstoned).await?;
            for r in &remote_results {
                if r.action == "reject" && r.reason.as_deref() == Some("duplicate") {
                    let _ = self.db.set_upload_sync_status(
                        &r.id,
                        r.asset_id.as_deref(),
                        None,
                        "completed",
                        None,
                    );
                }
            }
            results.extend(remote_results);
        }

        Ok(results)
    }

    /// Upload a single asset with full dual-track support (primary + live photo video)
    pub async fn upload_single_asset(
        &self,
        device_asset_id: &str,
        device_id: &str,
        file_created_at: &str,
        file_modified_at: &str,
        is_favorite: bool,
        file_bytes: Vec<u8>,
        file_name: &str,
        live_photo_bytes: Option<Vec<u8>>,
        live_photo_name: Option<&str>,
    ) -> Result<client::AssetUploadResponse, CoreError> {
        // Check tombstone
        if self.db.is_upload_tombstoned(device_asset_id, &self.active_account()).unwrap_or(false) {
            return Err(CoreError::Client(client::ClientError::ServerStatus(
                reqwest::StatusCode::CONFLICT,
                "Asset is tombstoned and cannot be auto-uploaded".to_string(),
            )));
        }

        let _ = self.db.set_upload_sync_status(
            device_asset_id,
            None,
            None,
            "uploading",
            None,
        );

        let client = self.client.read().await;
        let res = client
            .upload_asset(
                device_asset_id,
                device_id,
                file_created_at,
                file_modified_at,
                is_favorite,
                file_bytes,
                file_name,
                live_photo_bytes,
                live_photo_name,
            )
            .await;

        match res {
            Ok(ref upload_res) => {
                let _ = self.db.set_upload_sync_status(
                    device_asset_id,
                    Some(&upload_res.id),
                    None,
                    "completed",
                    None,
                );
            }
            Err(ref e) => {
                let err_msg = e.to_string();
                let _ = self.db.set_upload_sync_status(
                    device_asset_id,
                    None,
                    None,
                    "failed",
                    Some(&err_msg),
                );
            }
        }

        res.map_err(CoreError::Client)
    }

    /// List all upload tombstones
    pub fn get_upload_tombstones(&self) -> Result<Vec<(String, String, String, i64)>, CoreError> {
        self.db.get_all_upload_tombstones().map_err(CoreError::Db)
    }

    /// Remove an upload tombstone
    pub fn remove_upload_tombstone(&self, local_asset_id: &str) -> Result<(), CoreError> {
        self.db
            .remove_upload_tombstone(local_asset_id, &self.active_account())
            .map_err(CoreError::Db)
    }

    /// Account (server+user key chosen by the platform layer) that tombstone checks apply to.
    /// Persisted in the DB so it survives core re-initialization.
    pub fn set_active_account(&self, account_id: &str) -> Result<(), CoreError> {
        self.db.set_config("active_account", account_id).map_err(CoreError::Db)
    }

    pub fn active_account(&self) -> String {
        self.db
            .get_config("active_account")
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    pub fn is_upload_tombstoned(&self, local_asset_id: &str) -> bool {
        self.db
            .is_upload_tombstoned(local_asset_id, &self.active_account())
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tombstones_are_scoped_per_account() {
        let temp_dir = tempfile::tempdir().unwrap();
        let core = ImmichCore::init_in_memory(temp_dir.path()).unwrap();

        core.db.add_upload_tombstone("local-1", "srv|alice", "deleted_from_cloud").unwrap();

        core.set_active_account("srv|alice").unwrap();
        assert!(core.is_upload_tombstoned("local-1"));

        // Another account must not inherit the suppression.
        core.set_active_account("srv|bob").unwrap();
        assert!(!core.is_upload_tombstoned("local-1"));

        // Removing under bob does not lift alice's tombstone.
        core.remove_upload_tombstone("local-1").unwrap();
        core.set_active_account("srv|alice").unwrap();
        assert!(core.is_upload_tombstoned("local-1"));

        // Clearing cached data must not lift suppression.
        core.db.clear_all().unwrap();
        core.set_active_account("srv|alice").unwrap();
        assert!(core.is_upload_tombstoned("local-1"));
        core.remove_upload_tombstone("local-1").unwrap();
        assert!(!core.is_upload_tombstoned("local-1"));
    }

    #[tokio::test]
    async fn test_login_does_not_persist_api_key() {
        let temp_dir = tempfile::tempdir().unwrap();
        let core = ImmichCore::init_in_memory(temp_dir.path()).unwrap();
        // Unreachable host: ping fails, but credentials must never hit SQLite anyway.
        let _ = core.login_server("http://127.0.0.1:1", "secret-key").await;
        assert!(core.db.get_config("api_key").unwrap().is_none());
    }

    #[tokio::test]
    async fn test_core_engine_in_memory() {
        let temp_dir = tempfile::tempdir().expect("tempdir creation failed");
        let core = ImmichCore::init_in_memory(temp_dir.path()).expect("core init failed");

        // Verify config persistence
        core.db.set_config("test_key", "test_val").unwrap();
        assert_eq!(
            core.db.get_config("test_key").unwrap().unwrap(),
            "test_val"
        );

        // Verify asset bundle preparation with simulated cached files
        let asset_id = "test-live-photo-id";
        let live_vid = "test-live-video-id";

        let sample_asset = Asset {
            id: asset_id.to_string(),
            asset_type: "IMAGE".to_string(),
            file_created_at: "2024-03-01T12:00:00.000Z".to_string(),
            file_modified_at: None,
            updated_at: None,
            is_favorite: true,
            duration: None,
            live_photo_video_id: Some(live_vid.to_string()),
            thumbhash: None,
            local_thumb_path: None,
            local_preview_path: None,
            local_video_path: None,
            bucket_id: Some("2024-03-01T00:00:00.000Z".to_string()),
            exif: None,
        };

        core.db.upsert_assets(&[sample_asset]).unwrap();

        // Create mock preview file and video file on disk
        let preview_dir = temp_dir.path().join("previews");
        let video_dir = temp_dir.path().join("videos");
        std::fs::create_dir_all(&preview_dir).unwrap();
        std::fs::create_dir_all(&video_dir).unwrap();

        let mock_preview_file = preview_dir.join(format!("{}.jpg", asset_id));
        let mock_video_file = video_dir.join(format!("{}.mp4", live_vid));
        std::fs::write(&mock_preview_file, b"MOCK_JPEG").unwrap();
        std::fs::write(&mock_video_file, b"MOCK_MP4").unwrap();

        // Now prepare bundle — it will find the existing cached files!
        let bundle = core
            .prepare_asset_viewer_bundle(asset_id)
            .await
            .expect("prepare_asset_viewer_bundle failed");

        assert_eq!(bundle.asset_id, asset_id);
        assert_eq!(bundle.asset_type, "IMAGE");
        assert!(bundle.is_live_photo);
        assert_eq!(bundle.image_path, mock_preview_file.to_str().unwrap());
        assert_eq!(bundle.video_path, Some(mock_video_file.to_str().unwrap().to_string()));

        // Test EXIF retrieval
        let exif = core.get_or_fetch_exif(asset_id).await.unwrap();
        assert!(exif.is_none()); // Initially none

        let mock_exif = crate::adapter::ExifResponseDto {
            make: Some("Huawei".to_string()),
            model: Some("Pura 70 Ultra".to_string()),
            iso: Some(100),
            ..Default::default()
        };
        core.db.update_asset_exif(asset_id, &mock_exif).unwrap();

        let fetched_exif = core.get_or_fetch_exif(asset_id).await.unwrap().unwrap();
        assert_eq!(fetched_exif.make, Some("Huawei".to_string()));
        assert_eq!(fetched_exif.model, Some("Pura 70 Ultra".to_string()));
        assert_eq!(fetched_exif.iso, Some(100));
    }
}
