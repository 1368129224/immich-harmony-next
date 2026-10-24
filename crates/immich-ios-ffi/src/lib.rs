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
