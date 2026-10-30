#ifndef IMMICH_CORE_FFI_H
#define IMMICH_CORE_FFI_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

/**
 * Free a C-string previously allocated and returned by any immich_ios_* function.
 */
void immich_ios_free_string(char *ptr);

/**
 * Check whether ImmichCore engine is currently initialized.
 */
bool immich_ios_is_initialized(void);

/**
 * Initialize ImmichCore engine with local database directory and cache directory.
 * Returns a JSON envelope string: {"success": bool, "data": bool, "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_init_core_engine(const char *db_dir, const char *cache_dir);

/**
 * Initialize ImmichCore engine with in-memory database and specified cache directory.
 * Returns a JSON envelope string: {"success": bool, "data": bool, "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_init_in_memory(const char *cache_dir);

/**
 * Validate and log in to Immich server with given server URL and API key.
 * Returns a JSON envelope string: {"success": bool, "data": string, "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_login_server(const char *server_url, const char *api_key);

/**
 * Synchronize and return all time buckets from Immich server (or local SQLite cache).
 * Returns a JSON envelope string: {"success": bool, "data": [BucketInfo], "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_sync_and_get_buckets(void);

/**
 * Retrieve cached buckets directly from SQLite without network requests.
 * Returns a JSON envelope string: {"success": bool, "data": [BucketInfo], "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_get_cached_buckets(void);

/**
 * Fetch all assets belonging to a time bucket from Immich server (or local SQLite cache).
 * Returns a JSON envelope string: {"success": bool, "data": [Asset], "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_fetch_bucket_assets(const char *time_bucket);

/**
 * Retrieve cached assets for a bucket directly from SQLite without network requests.
 * Returns a JSON envelope string: {"success": bool, "data": [Asset], "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_get_cached_bucket_assets(const char *time_bucket);

/**
 * Ensure an asset's media (thumbnail, preview, or video) is downloaded and cached in the local sandbox.
 * Returns a JSON envelope string: {"success": bool, "data": string (local_path), "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_ensure_asset_cached(const char *asset_id, const char *media_type);

/**
 * Prepare a complete viewer bundle (image preview path, live photo video path, duration) for an asset.
 * Returns a JSON envelope string: {"success": bool, "data": AssetViewerBundle, "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_prepare_asset_viewer_bundle(const char *asset_id);

/**
 * Retrieve or fetch EXIF details for an asset.
 * Returns a JSON envelope string: {"success": bool, "data": ExifResponseDto | null, "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_get_asset_exif(const char *asset_id);

/**
 * Bulk upload check candidate assets against Immich server and local tombstones.
 * candidates_json: JSON string array [{"id": "...", "checksum": "..."}]
 * Returns JSON envelope string: {"success": bool, "data": [BulkUploadCheckResult], "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_bulk_upload_check(const char *candidates_json);

/**
 * Upload single asset with dual-track support (primary + live photo video).
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_upload_asset(
    const char *device_asset_id,
    const char *device_id,
    const char *file_created_at,
    const char *file_modified_at,
    bool is_favorite,
    const uint8_t *file_bytes_ptr,
    size_t file_bytes_len,
    const char *file_name,
    const uint8_t *live_photo_bytes_ptr,
    size_t live_photo_bytes_len,
    const char *live_photo_name
);

/**
 * Add a tombstone to prevent an asset from being automatically re-uploaded.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_add_upload_tombstone(
    const char *local_asset_id,
    const char *account_id,
    const char *reason
);

/**
 * Check if a local asset is tombstoned for the active account.
 */
bool immich_ios_is_upload_tombstoned(const char *local_asset_id);

/**
 * Get all upload tombstones.
 * Returns JSON envelope string: {"success": bool, "data": [{"localAssetId": string, "accountId": string, "reason": string, "createdAt": number}], "error": string | null}.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_get_upload_tombstones(void);

/**
 * Remove an upload tombstone.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_remove_upload_tombstone(const char *local_asset_id);

/**
 * Select the account (server+user key) that tombstone checks/removals apply to.
 * Caller MUST free the returned string using immich_ios_free_string().
 */
char *immich_ios_set_active_account(const char *account_id);

#endif /* IMMICH_CORE_FFI_H */
