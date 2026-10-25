use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock, RwLock};

use immich_core::ImmichCore;
use serde::Serialize;

static CORE_INSTANCE: RwLock<Option<Arc<ImmichCore>>> = RwLock::new(None);
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();

fn get_runtime() -> &'static tokio::runtime::Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("Failed to initialize tokio runtime for iOS FFI")
    })
}

fn get_core() -> Result<Arc<ImmichCore>, String> {
    let lock = CORE_INSTANCE
        .read()
        .map_err(|e| format!("Failed to acquire core read lock: {}", e))?;
    lock.clone()
        .ok_or_else(|| "ImmichCore is not initialized".to_string())
}

fn c_str_to_rust(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("Null pointer passed for string".to_string());
    }
    unsafe {
        CStr::from_ptr(ptr)
            .to_str()
            .map(|s| s.to_string())
            .map_err(|e| format!("Invalid UTF-8 string: {}", e))
    }
}

fn make_json_response<T: Serialize>(res: Result<T, String>) -> *mut c_char {
    let json_val = match res {
        Ok(data) => serde_json::json!({
            "success": true,
            "data": data,
            "error": serde_json::Value::Null,
        }),
        Err(err) => serde_json::json!({
            "success": false,
            "data": serde_json::Value::Null,
            "error": err,
        }),
    };

    let s = json_val.to_string();
    CString::new(s)
        .unwrap_or_else(|_| CString::new("{\"success\":false,\"error\":\"CString conversion failed\"}").unwrap())
        .into_raw()
}

/// Free a string returned by any `immich_ios_*` function.
#[no_mangle]
pub extern "C" fn immich_ios_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe {
            drop(CString::from_raw(ptr));
        }
    }
}

/// Check if the core engine is initialized.
#[no_mangle]
pub extern "C" fn immich_ios_is_initialized() -> bool {
    if let Ok(lock) = CORE_INSTANCE.read() {
        lock.is_some()
    } else {
        false
    }
}

/// Initialize the Immich Core engine with database and cache directory paths.
/// Returns a JSON envelope string: `{"success": true, "data": true}` or error.
#[no_mangle]
pub extern "C" fn immich_ios_init_core_engine(
    db_dir: *const c_char,
    cache_dir: *const c_char,
) -> *mut c_char {
    let run = || -> Result<bool, String> {
        let db_dir_str = c_str_to_rust(db_dir)?;
        let cache_dir_str = c_str_to_rust(cache_dir)?;

        let db_path = PathBuf::from(&db_dir_str).join("immich_ios_cache.db");
        let cache_path = PathBuf::from(&cache_dir_str);

        let core = ImmichCore::init(db_path, cache_path)
            .map_err(|e| format!("Core init error: {}", e))?;

        let mut lock = CORE_INSTANCE
            .write()
            .map_err(|e| format!("Failed to acquire core write lock: {}", e))?;
        *lock = Some(Arc::new(core));

        Ok(true)
    };

    make_json_response(run())
}

/// Initialize the Immich Core engine in-memory (useful for testing or ephemeral sessions).
#[no_mangle]
pub extern "C" fn immich_ios_init_in_memory(cache_dir: *const c_char) -> *mut c_char {
    let run = || -> Result<bool, String> {
        let cache_dir_str = c_str_to_rust(cache_dir)?;
        let cache_path = PathBuf::from(&cache_dir_str);

        let core = ImmichCore::init_in_memory(cache_path)
            .map_err(|e| format!("Core in-memory init error: {}", e))?;

        let mut lock = CORE_INSTANCE
            .write()
            .map_err(|e| format!("Failed to acquire core write lock: {}", e))?;
        *lock = Some(Arc::new(core));

        Ok(true)
    };

    make_json_response(run())
}

/// Log in to Immich server and validate connection.
/// Returns a JSON envelope string with status message or error.
#[no_mangle]
pub extern "C" fn immich_ios_login_server(
    server_url: *const c_char,
    api_key: *const c_char,
) -> *mut c_char {
    let run = || -> Result<String, String> {
        let server_url_str = c_str_to_rust(server_url)?;
        let api_key_str = c_str_to_rust(api_key)?;
        let core = get_core()?;

        get_runtime()
            .block_on(async { core.login_server(&server_url_str, &api_key_str).await })
            .map_err(|e| format!("Login error: {}", e))
    };

    make_json_response(run())
}

/// Synchronize and get time buckets from Immich server or local cache.
/// Returns a JSON envelope string with `data: [BucketInfo]`.
#[no_mangle]
pub extern "C" fn immich_ios_sync_and_get_buckets() -> *mut c_char {
    let run = || -> Result<serde_json::Value, String> {
        let core = get_core()?;
        let buckets = get_runtime()
            .block_on(async { core.sync_and_get_buckets().await })
            .map_err(|e| format!("Sync buckets error: {}", e))?;

        serde_json::to_value(&buckets).map_err(|e| format!("Serialization error: {}", e))
    };

    make_json_response(run())
}

/// Fetch assets for a specific time bucket from Immich server or local cache.
/// Returns a JSON envelope string with `data: [Asset]`.
#[no_mangle]
pub extern "C" fn immich_ios_fetch_bucket_assets(time_bucket: *const c_char) -> *mut c_char {
    let run = || -> Result<serde_json::Value, String> {
        let time_bucket_str = c_str_to_rust(time_bucket)?;
        let core = get_core()?;
        let assets = get_runtime()
            .block_on(async { core.fetch_bucket_assets(&time_bucket_str).await })
            .map_err(|e| format!("Fetch bucket assets error: {}", e))?;

        serde_json::to_value(&assets).map_err(|e| format!("Serialization error: {}", e))
    };

    make_json_response(run())
}

/// Ensure that an asset media (thumbnail, preview, or video) is downloaded and cached locally.
/// Returns a JSON envelope string with `data: <local_file_path>`.
#[no_mangle]
pub extern "C" fn immich_ios_ensure_asset_cached(
    asset_id: *const c_char,
    media_type: *const c_char,
) -> *mut c_char {
    let run = || -> Result<String, String> {
        let asset_id_str = c_str_to_rust(asset_id)?;
        let media_type_str = c_str_to_rust(media_type)?;
        let core = get_core()?;

        get_runtime()
            .block_on(async { core.ensure_asset_cached(&asset_id_str, &media_type_str).await })
            .map_err(|e| format!("Ensure cached error: {}", e))
    };

    make_json_response(run())
}

/// Prepare full asset viewer bundle (image preview path, live photo video path, duration, etc.).
/// Returns a JSON envelope string with `data: AssetViewerBundle`.
#[no_mangle]
pub extern "C" fn immich_ios_prepare_asset_viewer_bundle(asset_id: *const c_char) -> *mut c_char {
    let run = || -> Result<serde_json::Value, String> {
        let asset_id_str = c_str_to_rust(asset_id)?;
        let core = get_core()?;

        let bundle = get_runtime()
            .block_on(async { core.prepare_asset_viewer_bundle(&asset_id_str).await })
            .map_err(|e| format!("Prepare asset viewer bundle error: {}", e))?;

        serde_json::to_value(&bundle).map_err(|e| format!("Serialization error: {}", e))
    };

    make_json_response(run())
}

/// Fetch or retrieve cached EXIF information for an asset.
/// Returns a JSON envelope string with `data: ExifResponseDto` or `data: null`.
#[no_mangle]
pub extern "C" fn immich_ios_get_asset_exif(asset_id: *const c_char) -> *mut c_char {
    let run = || -> Result<serde_json::Value, String> {
        let asset_id_str = c_str_to_rust(asset_id)?;
        let core = get_core()?;

        let exif = get_runtime()
            .block_on(async { core.get_or_fetch_exif(&asset_id_str).await })
            .map_err(|e| format!("Get EXIF error: {}", e))?;

        serde_json::to_value(&exif).map_err(|e| format!("Serialization error: {}", e))
    };

    make_json_response(run())
}

/// Retrieve locally cached buckets directly from SQLite without network.
/// Returns a JSON envelope string with `data: [BucketInfo]`.
#[no_mangle]
pub extern "C" fn immich_ios_get_cached_buckets() -> *mut c_char {
    let run = || -> Result<serde_json::Value, String> {
        let core = get_core()?;
        let buckets = core
            .get_cached_buckets()
            .map_err(|e| format!("Get cached buckets error: {}", e))?;

        serde_json::to_value(&buckets).map_err(|e| format!("Serialization error: {}", e))
    };

    make_json_response(run())
}

/// Retrieve locally cached assets for a bucket directly from SQLite without network.
/// Returns a JSON envelope string with `data: [Asset]`.
#[no_mangle]
pub extern "C" fn immich_ios_get_cached_bucket_assets(time_bucket: *const c_char) -> *mut c_char {
    let run = || -> Result<serde_json::Value, String> {
        let time_bucket_str = c_str_to_rust(time_bucket)?;
        let core = get_core()?;
        let assets = core
            .get_cached_bucket_assets(&time_bucket_str)
            .map_err(|e| format!("Get cached bucket assets error: {}", e))?;

        serde_json::to_value(&assets).map_err(|e| format!("Serialization error: {}", e))
    };

    make_json_response(run())
}

/// Bulk upload check candidate assets against Immich server and local tombstones.
/// `candidates_json`: JSON string array `[{"id": "...", "checksum": "..."}]`
/// Returns JSON envelope: `{"success": true, "data": [{"id": "...", "action": "accept"|"reject", "reason": "...", "assetId": "..."}]}`
#[no_mangle]
pub extern "C" fn immich_ios_bulk_upload_check(candidates_json: *const c_char) -> *mut c_char {
    let run = || -> Result<serde_json::Value, String> {
        let json_str = c_str_to_rust(candidates_json)?;
        let candidates: Vec<immich_core::client::BulkUploadCheckItem> = serde_json::from_str(&json_str)
            .map_err(|e| format!("Invalid candidates JSON: {}", e))?;
        let core = get_core()?;

        let results = get_runtime()
            .block_on(async { core.check_bulk_upload_candidates(candidates).await })
            .map_err(|e| format!("Bulk upload check error: {}", e))?;

        serde_json::to_value(&results).map_err(|e| format!("Serialization error: {}", e))
    };

    make_json_response(run())
}

/// Upload a single asset with full dual-track support (primary + live photo video).
#[no_mangle]
pub extern "C" fn immich_ios_upload_asset(
    device_asset_id: *const c_char,
    device_id: *const c_char,
    file_created_at: *const c_char,
    file_modified_at: *const c_char,
    is_favorite: bool,
    file_bytes_ptr: *const u8,
    file_bytes_len: usize,
    file_name: *const c_char,
    live_photo_bytes_ptr: *const u8,
    live_photo_bytes_len: usize,
    live_photo_name: *const c_char,
) -> *mut c_char {
    let run = || -> Result<serde_json::Value, String> {
        let local_id = c_str_to_rust(device_asset_id)?;
        let dev_id = c_str_to_rust(device_id)?;
        let created_at = c_str_to_rust(file_created_at)?;
        let modified_at = c_str_to_rust(file_modified_at)?;
        let fname = c_str_to_rust(file_name)?;

        if file_bytes_ptr.is_null() || file_bytes_len == 0 {
            return Err("Primary file bytes cannot be empty".to_string());
        }
        let primary_bytes = unsafe { std::slice::from_raw_parts(file_bytes_ptr, file_bytes_len).to_vec() };

        let (live_bytes, live_name) = if !live_photo_bytes_ptr.is_null() && live_photo_bytes_len > 0 && !live_photo_name.is_null() {
            let b = unsafe { std::slice::from_raw_parts(live_photo_bytes_ptr, live_photo_bytes_len).to_vec() };
            let n = c_str_to_rust(live_photo_name)?;
            (Some(b), Some(n))
        } else {
            (None, None)
        };

        let core = get_core()?;
        let resp = get_runtime()
            .block_on(async {
                core.upload_single_asset(
                    &local_id,
                    &dev_id,
                    &created_at,
                    &modified_at,
                    is_favorite,
                    primary_bytes,
                    &fname,
                    live_bytes,
                    live_name.as_deref(),
                )
                .await
            })
            .map_err(|e| format!("Upload error: {}", e))?;

        serde_json::to_value(&resp).map_err(|e| format!("Serialization error: {}", e))
    };

    make_json_response(run())
}

/// Mark a local asset as tombstoned (cannot be re-uploaded automatically)
#[no_mangle]
pub extern "C" fn immich_ios_add_upload_tombstone(
    local_asset_id: *const c_char,
    account_id: *const c_char,
    reason: *const c_char,
) -> *mut c_char {
    let run = || -> Result<bool, String> {
        let local_id = c_str_to_rust(local_asset_id)?;
        let acc_id = c_str_to_rust(account_id)?;
        let r = c_str_to_rust(reason)?;
        let core = get_core()?;

        core.db.add_upload_tombstone(&local_id, &acc_id, &r)
            .map_err(|e| format!("Add tombstone error: {}", e))?;
        Ok(true)
    };

    make_json_response(run())
}

/// Check if a local asset is tombstoned
#[no_mangle]
pub extern "C" fn immich_ios_is_upload_tombstoned(local_asset_id: *const c_char) -> bool {
    if let Ok(local_id) = c_str_to_rust(local_asset_id) {
        if let Ok(core) = get_core() {
            return core.db.is_upload_tombstoned(&local_id).unwrap_or(false);
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use immich_core::adapter::BucketInfo;
    use std::ffi::CString;

    #[test]
    fn test_ffi_init_and_lifecycle() {
        let temp_dir = tempfile::tempdir().expect("tempdir failed");
        let cache_str = temp_dir.path().to_str().unwrap();
        let c_cache = CString::new(cache_str).unwrap();

        // Initially not initialized
        assert!(!immich_ios_is_initialized());

        // Initialize in memory
        let raw_res = immich_ios_init_in_memory(c_cache.as_ptr());
        assert!(!raw_res.is_null());
        let res_str = unsafe { CStr::from_ptr(raw_res).to_str().unwrap() };
        let parsed: serde_json::Value = serde_json::from_str(res_str).unwrap();
        assert_eq!(parsed["success"], true);
        assert_eq!(parsed["data"], true);
        immich_ios_free_string(raw_res);

        assert!(immich_ios_is_initialized());

        // Test get cached buckets (initially empty)
        let raw_cached = immich_ios_get_cached_buckets();
        let cached_str = unsafe { CStr::from_ptr(raw_cached).to_str().unwrap() };
        let parsed_cached: serde_json::Value = serde_json::from_str(cached_str).unwrap();
        assert_eq!(parsed_cached["success"], true);
        assert_eq!(parsed_cached["data"].as_array().unwrap().len(), 0);
        immich_ios_free_string(raw_cached);

        // Populate a bucket in local DB
        let core = get_core().unwrap();
        let sample_bucket = BucketInfo {
            time_bucket: "2024-03-01T00:00:00.000Z".to_string(),
            count: 5,
        };
        core.db.upsert_buckets(&[sample_bucket]).unwrap();

        // Now test sync_and_get_buckets fallback to local cached buckets
        let raw_buckets = immich_ios_sync_and_get_buckets();
        let buckets_str = unsafe { CStr::from_ptr(raw_buckets).to_str().unwrap() };
        let parsed_buckets: serde_json::Value = serde_json::from_str(buckets_str).unwrap();
        assert_eq!(parsed_buckets["success"], true);
        assert_eq!(parsed_buckets["data"].as_array().unwrap().len(), 1);
        assert_eq!(parsed_buckets["data"][0]["count"], 5);
        immich_ios_free_string(raw_buckets);

        // Test EXIF for non-existent asset
        let c_asset_id = CString::new("nonexistent-asset").unwrap();
        let raw_exif = immich_ios_get_asset_exif(c_asset_id.as_ptr());
        let exif_str = unsafe { CStr::from_ptr(raw_exif).to_str().unwrap() };
        let parsed_exif: serde_json::Value = serde_json::from_str(exif_str).unwrap();
        assert_eq!(parsed_exif["success"], true);
        assert!(parsed_exif["data"].is_null());
        immich_ios_free_string(raw_exif);
    }

    #[test]
    fn test_ffi_null_pointer_handling() {
        let raw_res = immich_ios_fetch_bucket_assets(std::ptr::null());
        assert!(!raw_res.is_null());
        let res_str = unsafe { CStr::from_ptr(raw_res).to_str().unwrap() };
        let parsed: serde_json::Value = serde_json::from_str(res_str).unwrap();
        assert_eq!(parsed["success"], false);
        assert!(parsed["error"].as_str().unwrap().contains("Null pointer"));
        immich_ios_free_string(raw_res);
    }
}
