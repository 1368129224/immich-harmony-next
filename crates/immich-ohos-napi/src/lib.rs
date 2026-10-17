use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use immich_core::ImmichCore;
use napi_derive_ohos::napi;
use napi_ohos::{Error, Result, Status};

static CORE_INSTANCE: RwLock<Option<Arc<ImmichCore>>> = RwLock::new(None);

fn get_core() -> Result<Arc<ImmichCore>> {
    let lock = CORE_INSTANCE
        .read()
        .map_err(|_| Error::new(Status::GenericFailure, "Failed to acquire core lock"))?;
    lock.clone()
        .ok_or_else(|| Error::new(Status::GenericFailure, "ImmichCore not initialized"))
}

#[napi(object)]
pub struct AssetViewerBundleDto {
    pub asset_id: String,
    pub asset_type: String,
    pub image_path: String,
    pub video_path: Option<String>,
    pub is_live_photo: bool,
    pub duration: Option<String>,
}

#[napi]
pub fn init_core_engine(db_dir: String, cache_dir: String) -> Result<bool> {
    let db_path = PathBuf::from(db_dir).join("immich_cache.db");
    let cache_path = PathBuf::from(cache_dir);

    let core = ImmichCore::init(db_path, cache_path)
        .map_err(|e| Error::new(Status::GenericFailure, format!("Core init error: {}", e)))?;

    let mut lock = CORE_INSTANCE
        .write()
        .map_err(|_| Error::new(Status::GenericFailure, "Failed to acquire core lock"))?;
    *lock = Some(Arc::new(core));

    Ok(true)
}

#[napi]
pub async fn login_server(server_url: String, api_key: String) -> Result<String> {
    let core = get_core()?;
    core.login_server(&server_url, &api_key)
        .await
        .map_err(|e| Error::new(Status::GenericFailure, format!("Login error: {}", e)))
}

#[napi]
pub async fn sync_and_get_buckets() -> Result<String> {
    let core = get_core()?;
    let buckets = core
        .sync_and_get_buckets()
        .await
        .map_err(|e| Error::new(Status::GenericFailure, format!("Sync buckets error: {}", e)))?;

    serde_json::to_string(&buckets)
        .map_err(|e| Error::new(Status::GenericFailure, format!("Serialization error: {}", e)))
}

#[napi]
pub async fn fetch_bucket_assets_json(time_bucket: String) -> Result<String> {
    let core = get_core()?;
    let assets = core
        .fetch_bucket_assets(&time_bucket)
        .await
        .map_err(|e| Error::new(Status::GenericFailure, format!("Fetch assets error: {}", e)))?;

    serde_json::to_string(&assets)
        .map_err(|e| Error::new(Status::GenericFailure, format!("Serialization error: {}", e)))
}

#[napi]
pub async fn ensure_asset_cached(asset_id: String, media_type: String) -> Result<String> {
    let core = get_core()?;
    core.ensure_asset_cached(&asset_id, &media_type)
        .await
        .map_err(|e| Error::new(Status::GenericFailure, format!("Cache media error: {}", e)))
}

#[napi]
pub async fn prepare_asset_viewer_bundle(asset_id: String) -> Result<AssetViewerBundleDto> {
    let core = get_core()?;
    let bundle = core
        .prepare_asset_viewer_bundle(&asset_id)
        .await
        .map_err(|e| Error::new(Status::GenericFailure, format!("Prepare viewer error: {}", e)))?;

    Ok(AssetViewerBundleDto {
        asset_id: bundle.asset_id,
        asset_type: bundle.asset_type,
        image_path: bundle.image_path,
        video_path: bundle.video_path,
        is_live_photo: bundle.is_live_photo,
        duration: bundle.duration,
    })
}
