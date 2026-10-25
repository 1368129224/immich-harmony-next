use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{params, Connection, OptionalExtension};
use thiserror::Error;

use crate::adapter::{Asset, BucketInfo};

#[derive(Error, Debug)]
pub enum DbError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),
    #[error("Database lock poisoned")]
    Poisoned,
}

pub struct DbEngine {
    conn: Mutex<Connection>,
}

impl DbEngine {
    pub fn open<P: AsRef<Path>>(path: P) -> Result<Self, DbError> {
        let conn = Connection::open(path)?;
        let engine = Self {
            conn: Mutex::new(conn),
        };
        engine.init_schema()?;
        Ok(engine)
    }

    pub fn open_in_memory() -> Result<Self, DbError> {
        let conn = Connection::open_in_memory()?;
        let engine = Self {
            conn: Mutex::new(conn),
        };
        engine.init_schema()?;
        Ok(engine)
    }

    fn init_schema(&self) -> Result<(), DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;

        conn.execute_batch(
            "
            CREATE TABLE IF NOT EXISTS server_config (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS buckets (
                time_bucket TEXT PRIMARY KEY,
                count INTEGER NOT NULL,
                last_synced_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS assets (
                id TEXT PRIMARY KEY,
                asset_type TEXT NOT NULL,
                file_created_at TEXT NOT NULL,
                file_modified_at TEXT,
                updated_at TEXT,
                is_favorite INTEGER NOT NULL DEFAULT 0,
                duration TEXT,
                live_photo_video_id TEXT,
                thumbhash TEXT,
                local_thumb_path TEXT,
                local_preview_path TEXT,
                local_video_path TEXT,
                bucket_id TEXT,
                exif_json TEXT,
                updated_timestamp INTEGER NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_assets_bucket ON assets(bucket_id);
            CREATE INDEX IF NOT EXISTS idx_assets_created ON assets(file_created_at DESC);

            CREATE TABLE IF NOT EXISTS upload_tombstones (
                local_asset_id TEXT PRIMARY KEY,
                account_id TEXT NOT NULL,
                reason TEXT NOT NULL,
                created_at INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS upload_sync_status (
                local_asset_id TEXT PRIMARY KEY,
                server_asset_id TEXT,
                checksum TEXT,
                status TEXT NOT NULL, -- 'pending', 'uploading', 'completed', 'failed', 'rejected'
                error_message TEXT,
                updated_at INTEGER NOT NULL
            );
            ",
        )?;

        Ok(())
    }

    pub fn set_config(&self, key: &str, value: &str) -> Result<(), DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        conn.execute(
            "INSERT INTO server_config (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    pub fn get_config(&self, key: &str) -> Result<Option<String>, DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let mut stmt = conn.prepare("SELECT value FROM server_config WHERE key = ?1")?;
        let res = stmt
            .query_row(params![key], |row| row.get(0))
            .optional()?;
        Ok(res)
    }

    pub fn upsert_buckets(&self, buckets: &[BucketInfo]) -> Result<(), DbError> {
        let mut conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let tx = conn.transaction()?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        {
            let mut stmt = tx.prepare(
                "INSERT INTO buckets (time_bucket, count, last_synced_at)
                 VALUES (?1, ?2, ?3)
                 ON CONFLICT(time_bucket) DO UPDATE SET
                    count = excluded.count,
                    last_synced_at = excluded.last_synced_at",
            )?;

            for b in buckets {
                stmt.execute(params![b.time_bucket, b.count, now])?;
            }
        }

        tx.commit()?;
        Ok(())
    }

    pub fn get_buckets(&self) -> Result<Vec<BucketInfo>, DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let mut stmt = conn.prepare("SELECT time_bucket, count FROM buckets ORDER BY time_bucket DESC")?;
        let rows = stmt.query_map([], |row| {
            Ok(BucketInfo {
                time_bucket: row.get(0)?,
                count: row.get(1)?,
            })
        })?;

        let mut list = Vec::new();
        for r in rows {
            list.push(r?);
        }
        Ok(list)
    }

    pub fn upsert_assets(&self, assets: &[Asset]) -> Result<(), DbError> {
        let mut conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let tx = conn.transaction()?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        {
            let mut stmt = tx.prepare(
                "INSERT INTO assets (
                    id, asset_type, file_created_at, file_modified_at, updated_at,
                    is_favorite, duration, live_photo_video_id, thumbhash,
                    local_thumb_path, local_preview_path, local_video_path, bucket_id,
                    exif_json, updated_timestamp
                ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
                ON CONFLICT(id) DO UPDATE SET
                    asset_type = excluded.asset_type,
                    file_created_at = excluded.file_created_at,
                    file_modified_at = excluded.file_modified_at,
                    updated_at = excluded.updated_at,
                    is_favorite = excluded.is_favorite,
                    duration = excluded.duration,
                    live_photo_video_id = excluded.live_photo_video_id,
                    thumbhash = excluded.thumbhash,
                    local_thumb_path = COALESCE(excluded.local_thumb_path, assets.local_thumb_path),
                    local_preview_path = COALESCE(excluded.local_preview_path, assets.local_preview_path),
                    local_video_path = COALESCE(excluded.local_video_path, assets.local_video_path),
                    bucket_id = COALESCE(excluded.bucket_id, assets.bucket_id),
                    exif_json = COALESCE(excluded.exif_json, assets.exif_json),
                    updated_timestamp = excluded.updated_timestamp",
            )?;

            for a in assets {
                let exif_str = a.exif.as_ref().and_then(|e| serde_json::to_string(e).ok());
                stmt.execute(params![
                    a.id,
                    a.asset_type,
                    a.file_created_at,
                    a.file_modified_at,
                    a.updated_at,
                    if a.is_favorite { 1 } else { 0 },
                    a.duration,
                    a.live_photo_video_id,
                    a.thumbhash,
                    a.local_thumb_path,
                    a.local_preview_path,
                    a.local_video_path,
                    a.bucket_id,
                    exif_str,
                    now,
                ])?;
            }
        }

        tx.commit()?;
        Ok(())
    }

    pub fn get_assets_by_bucket(&self, bucket_id: &str) -> Result<Vec<Asset>, DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let mut stmt = conn.prepare(
            "SELECT id, asset_type, file_created_at, file_modified_at, updated_at,
                    is_favorite, duration, live_photo_video_id, thumbhash,
                    local_thumb_path, local_preview_path, local_video_path, bucket_id, exif_json
             FROM assets
             WHERE bucket_id = ?1
             ORDER BY file_created_at DESC",
        )?;

        let rows = stmt.query_map(params![bucket_id], |row| {
            let is_fav_int: i32 = row.get(5)?;
            let exif_str: Option<String> = row.get(13)?;
            let exif = exif_str.and_then(|s| serde_json::from_str(&s).ok());
            Ok(Asset {
                id: row.get(0)?,
                asset_type: row.get(1)?,
                file_created_at: row.get(2)?,
                file_modified_at: row.get(3)?,
                updated_at: row.get(4)?,
                is_favorite: is_fav_int != 0,
                duration: row.get(6)?,
                live_photo_video_id: row.get(7)?,
                thumbhash: row.get(8)?,
                local_thumb_path: row.get(9)?,
                local_preview_path: row.get(10)?,
                local_video_path: row.get(11)?,
                bucket_id: row.get(12)?,
                exif,
            })
        })?;

        let mut list = Vec::new();
        for r in rows {
            list.push(r?);
        }
        Ok(list)
    }

    pub fn get_asset(&self, id: &str) -> Result<Option<Asset>, DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let mut stmt = conn.prepare(
            "SELECT id, asset_type, file_created_at, file_modified_at, updated_at,
                    is_favorite, duration, live_photo_video_id, thumbhash,
                    local_thumb_path, local_preview_path, local_video_path, bucket_id, exif_json
             FROM assets
             WHERE id = ?1",
        )?;

        let asset = stmt
            .query_row(params![id], |row| {
                let is_fav_int: i32 = row.get(5)?;
                let exif_str: Option<String> = row.get(13)?;
                let exif = exif_str.and_then(|s| serde_json::from_str(&s).ok());
                Ok(Asset {
                    id: row.get(0)?,
                    asset_type: row.get(1)?,
                    file_created_at: row.get(2)?,
                    file_modified_at: row.get(3)?,
                    updated_at: row.get(4)?,
                    is_favorite: is_fav_int != 0,
                    duration: row.get(6)?,
                    live_photo_video_id: row.get(7)?,
                    thumbhash: row.get(8)?,
                    local_thumb_path: row.get(9)?,
                    local_preview_path: row.get(10)?,
                    local_video_path: row.get(11)?,
                    bucket_id: row.get(12)?,
                    exif,
                })
            })
            .optional()?;

        Ok(asset)
    }

    pub fn update_asset_exif(&self, id: &str, exif: &crate::adapter::ExifResponseDto) -> Result<(), DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let exif_str = serde_json::to_string(exif).map_err(|e| DbError::Sqlite(rusqlite::Error::ToSqlConversionFailure(Box::new(e))))?;
        conn.execute(
            "UPDATE assets SET exif_json = ?2 WHERE id = ?1",
            params![id, exif_str],
        )?;
        Ok(())
    }

    pub fn update_asset_paths(
        &self,
        id: &str,
        thumb_path: Option<&str>,
        preview_path: Option<&str>,
        video_path: Option<&str>,
    ) -> Result<(), DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        conn.execute(
            "UPDATE assets SET
                local_thumb_path = COALESCE(?2, local_thumb_path),
                local_preview_path = COALESCE(?3, local_preview_path),
                local_video_path = COALESCE(?4, local_video_path)
             WHERE id = ?1",
            params![id, thumb_path, preview_path, video_path],
        )?;
        Ok(())
    }

    pub fn clear_all(&self) -> Result<(), DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        conn.execute_batch(
            "DELETE FROM assets;
             DELETE FROM buckets;
             DELETE FROM server_config;
             DELETE FROM upload_tombstones;
             DELETE FROM upload_sync_status;",
        )?;
        Ok(())
    }

    // MARK: - Upload Sync & Tombstone Methods

    /// Add a tombstone to prevent an asset from being automatically re-uploaded (e.g. after cloud deletion)
    pub fn add_upload_tombstone(&self, local_id: &str, account_id: &str, reason: &str) -> Result<(), DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        conn.execute(
            "INSERT INTO upload_tombstones (local_asset_id, account_id, reason, created_at)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(local_asset_id) DO UPDATE SET
                account_id = excluded.account_id,
                reason = excluded.reason,
                created_at = excluded.created_at",
            params![local_id, account_id, reason, now],
        )?;
        Ok(())
    }

    /// Check if a local asset has a tombstone preventing auto-upload
    pub fn is_upload_tombstoned(&self, local_id: &str) -> Result<bool, DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let mut stmt = conn.prepare("SELECT 1 FROM upload_tombstones WHERE local_asset_id = ?1")?;
        let exists = stmt.exists(params![local_id])?;
        Ok(exists)
    }

    /// Retrieve all tombstones as (local_asset_id, account_id, reason, created_at)
    pub fn get_all_upload_tombstones(&self) -> Result<Vec<(String, String, String, i64)>, DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let mut stmt = conn.prepare("SELECT local_asset_id, account_id, reason, created_at FROM upload_tombstones ORDER BY created_at DESC")?;
        let rows = stmt.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
        })?;
        let mut list = Vec::new();
        for r in rows {
            list.push(r?);
        }
        Ok(list)
    }

    /// Remove a tombstone if user manually triggers upload
    pub fn remove_upload_tombstone(&self, local_id: &str) -> Result<(), DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        conn.execute(
            "DELETE FROM upload_tombstones WHERE local_asset_id = ?1",
            params![local_id],
        )?;
        Ok(())
    }

    /// Update upload sync status for a local asset
    pub fn set_upload_sync_status(
        &self,
        local_id: &str,
        server_id: Option<&str>,
        checksum: Option<&str>,
        status: &str,
        error_message: Option<&str>,
    ) -> Result<(), DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;
        conn.execute(
            "INSERT INTO upload_sync_status (local_asset_id, server_asset_id, checksum, status, error_message, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(local_asset_id) DO UPDATE SET
                server_asset_id = COALESCE(excluded.server_asset_id, upload_sync_status.server_asset_id),
                checksum = COALESCE(excluded.checksum, upload_sync_status.checksum),
                status = excluded.status,
                error_message = excluded.error_message,
                updated_at = excluded.updated_at",
            params![local_id, server_id, checksum, status, error_message, now],
        )?;
        Ok(())
    }

    /// Get upload sync status for a local asset
    pub fn get_upload_sync_status(&self, local_id: &str) -> Result<Option<(String, Option<String>)>, DbError> {
        let conn = self.conn.lock().map_err(|_| DbError::Poisoned)?;
        let mut stmt = conn.prepare("SELECT status, server_asset_id FROM upload_sync_status WHERE local_asset_id = ?1")?;
        let res = stmt
            .query_row(params![local_id], |row| Ok((row.get(0)?, row.get(1)?)))
            .optional()?;
        Ok(res)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_db_config_and_schema() {
        let db = DbEngine::open_in_memory().expect("In-memory DB creation failed");

        db.set_config("server_url", "https://immich.example.com")
            .expect("set_config failed");
        let val = db
            .get_config("server_url")
            .expect("get_config failed")
            .expect("value should exist");
        assert_eq!(val, "https://immich.example.com");

        // Overwrite
        db.set_config("server_url", "https://immich-updated.example.com")
            .expect("set_config overwrite failed");
        let val_updated = db
            .get_config("server_url")
            .expect("get_config failed")
            .expect("value should exist");
        assert_eq!(val_updated, "https://immich-updated.example.com");
    }

    #[test]
    fn test_db_buckets_and_assets() {
        let db = DbEngine::open_in_memory().expect("In-memory DB creation failed");

        let buckets = vec![
            BucketInfo {
                time_bucket: "2024-03-01T00:00:00.000Z".to_string(),
                count: 10,
            },
            BucketInfo {
                time_bucket: "2024-02-01T00:00:00.000Z".to_string(),
                count: 5,
            },
        ];

        db.upsert_buckets(&buckets).expect("upsert_buckets failed");
        let stored_buckets = db.get_buckets().expect("get_buckets failed");
        assert_eq!(stored_buckets.len(), 2);
        assert_eq!(stored_buckets[0].time_bucket, "2024-03-01T00:00:00.000Z");

        let assets = vec![
            Asset {
                id: "asset-1".to_string(),
                asset_type: "IMAGE".to_string(),
                file_created_at: "2024-03-01T10:00:00.000Z".to_string(),
                file_modified_at: None,
                updated_at: None,
                is_favorite: true,
                duration: None,
                live_photo_video_id: Some("video-1".to_string()),
                thumbhash: Some("th-1".to_string()),
                local_thumb_path: None,
                local_preview_path: None,
                local_video_path: None,
                bucket_id: Some("2024-03-01T00:00:00.000Z".to_string()),
                exif: None,
            },
            Asset {
                id: "asset-2".to_string(),
                asset_type: "VIDEO".to_string(),
                file_created_at: "2024-03-01T11:00:00.000Z".to_string(),
                file_modified_at: None,
                updated_at: None,
                is_favorite: false,
                duration: Some("0:00:10.000000".to_string()),
                live_photo_video_id: None,
                thumbhash: None,
                local_thumb_path: None,
                local_preview_path: None,
                local_video_path: None,
                bucket_id: Some("2024-03-01T00:00:00.000Z".to_string()),
                exif: None,
            },
        ];

        db.upsert_assets(&assets).expect("upsert_assets failed");

        let bucket_assets = db
            .get_assets_by_bucket("2024-03-01T00:00:00.000Z")
            .expect("get_assets_by_bucket failed");
        assert_eq!(bucket_assets.len(), 2);

        let single = db.get_asset("asset-1").expect("get_asset failed").expect("asset should exist");
        assert_eq!(single.id, "asset-1");
        assert!(single.is_favorite);
        assert_eq!(single.live_photo_video_id, Some("video-1".to_string()));

        // Update cache paths
        db.update_asset_paths("asset-1", Some("/cache/thumb1.jpg"), None, None)
            .expect("update_asset_paths failed");

        let updated_single = db.get_asset("asset-1").expect("get_asset failed").expect("asset should exist");
        assert_eq!(updated_single.local_thumb_path, Some("/cache/thumb1.jpg".to_string()));
        assert_eq!(updated_single.local_preview_path, None);
    }
}
