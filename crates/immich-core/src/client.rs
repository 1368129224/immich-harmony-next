use std::path::{Path, PathBuf};
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::adapter::{
    parse_bucket_response, parse_buckets_response, AdapterError, Asset, BucketInfo,
    LEGACY_BUCKETS_QUERY, MODERN_BUCKETS_QUERY,
};

#[derive(Error, Debug)]
pub enum ClientError {
    #[error("HTTP request error: {0}")]
    Reqwest(#[from] reqwest::Error),
    #[error("Server returned error status {0}: {1}")]
    ServerStatus(StatusCode, String),
    #[error("Adapter parsing error: {0}")]
    Adapter(#[from] AdapterError),
    #[error("JSON parsing error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
    #[error("No base URL configured")]
    MissingBaseUrl,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginResponse {
    pub access_token: Option<String>,
    pub user_id: Option<String>,
    pub user_email: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThumbnailSize {
    Thumbnail,
    Preview,
}

impl ThumbnailSize {
    pub fn as_query_str(&self) -> &'static str {
        match self {
            ThumbnailSize::Thumbnail => "thumbnail",
            ThumbnailSize::Preview => "preview",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BulkUploadCheckItem {
    pub id: String,
    pub checksum: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BulkUploadCheckRequest {
    pub assets: Vec<BulkUploadCheckItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BulkUploadCheckResult {
    pub id: String,
    pub action: String, // "accept" or "reject"
    pub reason: Option<String>, // e.g. "duplicate"
    pub asset_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BulkUploadCheckResponse {
    pub results: Vec<BulkUploadCheckResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AssetUploadResponse {
    pub id: String,
    #[serde(default)]
    pub duplicate: bool,
}

pub struct ImmichClient {
    client: Client,
    base_url: Option<String>,
    api_key: Option<String>,
    access_token: Option<String>,
}

impl ImmichClient {
    pub fn new(base_url: Option<String>, api_key: Option<String>) -> Self {
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .unwrap_or_else(|_| Client::new());

        let clean_url = base_url.map(|u| u.trim_end_matches('/').to_string());

        Self {
            client,
            base_url: clean_url,
            api_key,
            access_token: None,
        }
    }

    pub fn set_base_url(&mut self, base_url: String) {
        self.base_url = Some(base_url.trim_end_matches('/').to_string());
    }

    pub fn set_api_key(&mut self, api_key: String) {
        self.api_key = Some(api_key);
    }

    pub fn set_access_token(&mut self, token: String) {
        self.access_token = Some(token);
    }

    fn auth_headers(&self) -> HeaderMap {
        let mut headers = HeaderMap::new();
        if let Some(ref key) = self.api_key {
            if let Ok(val) = HeaderValue::from_str(key) {
                headers.insert("x-api-key", val);
            }
        }
        if let Some(ref token) = self.access_token {
            let auth_str = format!("Bearer {}", token);
            if let Ok(val) = HeaderValue::from_str(&auth_str) {
                headers.insert(AUTHORIZATION, val);
            }
        }
        headers
    }

    fn url(&self, path: &str) -> Result<String, ClientError> {
        let base = self.base_url.as_ref().ok_or(ClientError::MissingBaseUrl)?;
        let clean_path = path.trim_start_matches('/');
        Ok(format!("{}/{}", base, clean_path))
    }

    /// Verifies server reachability and returns server ping / status info.
    pub async fn ping(&self) -> Result<bool, ClientError> {
        let url = self.url("api/server-info/ping")?;
        let res = self
            .client
            .get(&url)
            .headers(self.auth_headers())
            .send()
            .await?;

        if res.status().is_success() {
            return Ok(true);
        }

        // Try fallback to /api/server/version
        let v_url = self.url("api/server/version")?;
        let v_res = self
            .client
            .get(&v_url)
            .headers(self.auth_headers())
            .send()
            .await?;

        Ok(v_res.status().is_success())
    }

    /// Login with email and password, storing access token on success.
    pub async fn login(&mut self, email: &str, password: &str) -> Result<LoginResponse, ClientError> {
        let url = self.url("api/auth/login")?;
        let body = serde_json::json!({
            "email": email,
            "password": password
        });

        let res = self
            .client
            .post(&url)
            .json(&body)
            .send()
            .await?;

        if !res.status().is_success() {
            let status = res.status();
            let text = res.text().await.unwrap_or_default();
            return Err(ClientError::ServerStatus(status, text));
        }

        let login_res: LoginResponse = res.json().await?;
        if let Some(ref token) = login_res.access_token {
            self.access_token = Some(token.clone());
        }

        Ok(login_res)
    }

    /// Fetches timeline buckets with multi-version fallback.
    /// Tries modern query first (`visibility=timeline&withPartners=true`),
    /// falls back to legacy query (`size=MONTH&isArchived=false`) on HTTP 400.
    pub async fn fetch_buckets(&self) -> Result<Vec<BucketInfo>, ClientError> {
        let modern_url = self.url(&format!("api/timeline/buckets?{}", MODERN_BUCKETS_QUERY))?;
        let res = self
            .client
            .get(&modern_url)
            .headers(self.auth_headers())
            .send()
            .await?;

        if res.status() == StatusCode::BAD_REQUEST {
            // Fallback to legacy query parameters
            let legacy_url = self.url(&format!("api/timeline/buckets?{}", LEGACY_BUCKETS_QUERY))?;
            let legacy_res = self
                .client
                .get(&legacy_url)
                .headers(self.auth_headers())
                .send()
                .await?;

            if !legacy_res.status().is_success() {
                let status = legacy_res.status();
                let text = legacy_res.text().await.unwrap_or_default();
                return Err(ClientError::ServerStatus(status, text));
            }

            let text = legacy_res.text().await?;
            let buckets = parse_buckets_response(&text)?;
            return Ok(buckets);
        }

        if !res.status().is_success() {
            let status = res.status();
            let text = res.text().await.unwrap_or_default();
            return Err(ClientError::ServerStatus(status, text));
        }

        let text = res.text().await?;
        let buckets = parse_buckets_response(&text)?;
        Ok(buckets)
    }

    /// Fetches all assets within a given time bucket.
    pub async fn fetch_bucket_assets(&self, time_bucket: &str) -> Result<Vec<Asset>, ClientError> {
        let encoded_bucket = url_encode(time_bucket);
        let url = self.url(&format!("api/timeline/bucket?timeBucket={}", encoded_bucket))?;

        let res = self
            .client
            .get(&url)
            .headers(self.auth_headers())
            .send()
            .await?;

        if !res.status().is_success() {
            let status = res.status();
            let text = res.text().await.unwrap_or_default();
            return Err(ClientError::ServerStatus(status, text));
        }

        let body_text = res.text().await?;
        let assets = parse_bucket_response(&body_text, Some(time_bucket))?;
        Ok(assets)
    }

    /// Ensures thumbnail (`size=thumbnail`) or preview (`size=preview`) is downloaded
    /// into HarmonyOS sandbox cache directory and returns the absolute local path.
    pub async fn download_image_cache(
        &self,
        asset_id: &str,
        size: ThumbnailSize,
        cache_dir: &Path,
    ) -> Result<PathBuf, ClientError> {
        let sub_folder = match size {
            ThumbnailSize::Thumbnail => "thumbs",
            ThumbnailSize::Preview => "previews",
        };

        let target_dir = cache_dir.join(sub_folder);
        tokio::fs::create_dir_all(&target_dir).await?;

        let dest_file = target_dir.join(format!("{}.jpg", asset_id));

        // Skip downloading if already cached and non-empty
        if dest_file.exists() {
            if let Ok(metadata) = std::fs::metadata(&dest_file) {
                if metadata.len() > 0 {
                    return Ok(dest_file);
                }
            }
        }

        // Immich standard endpoints: /api/assets/{id}/thumbnail?size={size}
        let url = self.url(&format!(
            "api/assets/{}/thumbnail?size={}",
            asset_id,
            size.as_query_str()
        ))?;

        let res = self
            .client
            .get(&url)
            .headers(self.auth_headers())
            .send()
            .await?;

        let final_res = if res.status() == StatusCode::NOT_FOUND {
            // Older Immich fallback: /api/asset/thumbnail/{id}?size={size}
            let legacy_url = self.url(&format!(
                "api/asset/thumbnail/{}/?size={}",
                asset_id,
                size.as_query_str()
            ))?;
            self.client
                .get(&legacy_url)
                .headers(self.auth_headers())
                .send()
                .await?
        } else {
            res
        };

        if !final_res.status().is_success() {
            let status = final_res.status();
            let text = final_res.text().await.unwrap_or_default();
            return Err(ClientError::ServerStatus(status, text));
        }

        let bytes = final_res.bytes().await?;

        // Write atomically
        let temp_file = target_dir.join(format!("{}.tmp.{}", asset_id, std::process::id()));
        tokio::fs::write(&temp_file, &bytes).await?;
        tokio::fs::rename(&temp_file, &dest_file).await?;

        Ok(dest_file)
    }

    /// Downloads motion photo / live photo video into cacheDir and returns local path.
    pub async fn download_video_cache(
        &self,
        video_asset_id: &str,
        cache_dir: &Path,
    ) -> Result<PathBuf, ClientError> {
        let target_dir = cache_dir.join("videos");
        tokio::fs::create_dir_all(&target_dir).await?;

        let dest_file = target_dir.join(format!("{}.mp4", video_asset_id));

        if dest_file.exists() {
            if let Ok(metadata) = std::fs::metadata(&dest_file) {
                if metadata.len() > 0 {
                    return Ok(dest_file);
                }
            }
        }

        // Endpoint: /api/assets/{id}/video/playback or /api/assets/{id}/original
        let url = self.url(&format!("api/assets/{}/video/playback", video_asset_id))?;
        let res = self
            .client
            .get(&url)
            .headers(self.auth_headers())
            .send()
            .await?;

        let final_res = if !res.status().is_success() {
            // Fallback to /api/assets/{id}/original
            let orig_url = self.url(&format!("api/assets/{}/original", video_asset_id))?;
            self.client
                .get(&orig_url)
                .headers(self.auth_headers())
                .send()
                .await?
        } else {
            res
        };

        if !final_res.status().is_success() {
            let status = final_res.status();
            let text = final_res.text().await.unwrap_or_default();
            return Err(ClientError::ServerStatus(status, text));
        }

        let bytes = final_res.bytes().await?;
        let temp_file = target_dir.join(format!("{}.tmp.{}", video_asset_id, std::process::id()));
        tokio::fs::write(&temp_file, &bytes).await?;
        tokio::fs::rename(&temp_file, &dest_file).await?;

        Ok(dest_file)
    }

    /// Fetches full asset information including EXIF metadata from /api/assets/{id}.
    pub async fn fetch_asset_info(&self, asset_id: &str) -> Result<serde_json::Value, ClientError> {
        let url = self.url(&format!("api/assets/{}", asset_id))?;
        let res = self
            .client
            .get(&url)
            .headers(self.auth_headers())
            .send()
            .await?;

        if !res.status().is_success() {
            let status = res.status();
            let text = res.text().await.unwrap_or_default();
            return Err(ClientError::ServerStatus(status, text));
        }

        let val: serde_json::Value = res.json().await?;
        Ok(val)
    }

    /// Fetches EXIF info specifically for an asset.
    pub async fn fetch_asset_exif(&self, asset_id: &str) -> Result<Option<crate::adapter::ExifResponseDto>, ClientError> {
        let info = self.fetch_asset_info(asset_id).await?;
        if let Some(exif_val) = info.get("exifInfo") {
            let exif_dto: crate::adapter::ExifResponseDto = serde_json::from_value(exif_val.clone())?;
            return Ok(Some(exif_dto));
        }
        Ok(None)
    }

    /// Perform bulk upload check (/api/assets/bulk-upload-check) to verify which assets already exist on server.
    pub async fn bulk_upload_check(
        &self,
        assets: Vec<BulkUploadCheckItem>,
    ) -> Result<Vec<BulkUploadCheckResult>, ClientError> {
        let url = self.url("api/assets/bulk-upload-check")?;
        let payload = BulkUploadCheckRequest { assets };

        let res = self
            .client
            .post(&url)
            .headers(self.auth_headers())
            .json(&payload)
            .send()
            .await?;

        if !res.status().is_success() {
            let status = res.status();
            let text = res.text().await.unwrap_or_default();
            return Err(ClientError::ServerStatus(status, text));
        }

        let resp: BulkUploadCheckResponse = res.json().await?;
        Ok(resp.results)
    }

    /// Upload asset with dual-track support (primary photo/video + optional Live Photo paired video).
    pub async fn upload_asset(
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
    ) -> Result<AssetUploadResponse, ClientError> {
        use reqwest::multipart::{Form, Part};

        let url = self.url("api/assets")?;

        let asset_part = Part::bytes(file_bytes)
            .file_name(file_name.to_string())
            .mime_str("application/octet-stream")
            .unwrap_or_else(|_| Part::bytes(vec![]));

        let mut form = Form::new()
            .text("deviceAssetId", device_asset_id.to_string())
            .text("deviceId", device_id.to_string())
            .text("fileCreatedAt", file_created_at.to_string())
            .text("fileModifiedAt", file_modified_at.to_string())
            .text("isFavorite", if is_favorite { "true" } else { "false" })
            .part("assetData", asset_part);

        if let (Some(live_bytes), Some(live_name)) = (live_photo_bytes, live_photo_name) {
            let live_part = Part::bytes(live_bytes)
                .file_name(live_name.to_string())
                .mime_str("video/quicktime")
                .unwrap_or_else(|_| Part::bytes(vec![]));
            form = form.part("livePhotoData", live_part);
        }

        let res = self
            .client
            .post(&url)
            .headers(self.auth_headers())
            .multipart(form)
            .send()
            .await?;

        if !res.status().is_success() {
            let status = res.status();
            let text = res.text().await.unwrap_or_default();
            return Err(ClientError::ServerStatus(status, text));
        }

        let upload_resp: AssetUploadResponse = res.json().await?;
        Ok(upload_resp)
    }
}

fn url_encode(input: &str) -> String {
    let mut encoded = String::with_capacity(input.len() * 3);
    for b in input.bytes() {
        match b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                encoded.push(b as char);
            }
            _ => {
                encoded.push_str(&format!("%{:02X}", b));
            }
        }
    }
    encoded
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_client_url_construction() {
        let client = ImmichClient::new(
            Some("https://immich.home.arpa/".to_string()),
            Some("my-api-key".to_string()),
        );

        let url = client.url("api/timeline/buckets").unwrap();
        assert_eq!(url, "https://immich.home.arpa/api/timeline/buckets");

        let headers = client.auth_headers();
        assert_eq!(headers.get("x-api-key").unwrap(), "my-api-key");
    }

    #[test]
    fn test_url_encode() {
        assert_eq!(
            url_encode("2024-03-01T00:00:00.000Z"),
            "2024-03-01T00%3A00%3A00.000Z"
        );
    }

    #[tokio::test]
    async fn test_client_mock_server_flow() {
        use wiremock::matchers::{method, path, query_param};
        use wiremock::{Mock, MockServer, ResponseTemplate};

        let mock_server = MockServer::start().await;

        // Mock 1: ping
        Mock::given(method("GET"))
            .and(path("/api/server-info/ping"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"res": "pong"})))
            .mount(&mock_server)
            .await;

        // Mock 2: modern buckets query fails with 400 (triggering legacy fallback)
        Mock::given(method("GET"))
            .and(path("/api/timeline/buckets"))
            .and(query_param("visibility", "timeline"))
            .respond_with(ResponseTemplate::new(400))
            .mount(&mock_server)
            .await;

        // Mock 3: legacy buckets query succeeds
        let buckets_json = serde_json::json!([
            {"timeBucket": "2024-03-01T00:00:00.000Z", "count": 2}
        ]);
        Mock::given(method("GET"))
            .and(path("/api/timeline/buckets"))
            .and(query_param("size", "MONTH"))
            .respond_with(ResponseTemplate::new(200).set_body_json(buckets_json))
            .mount(&mock_server)
            .await;

        // Mock 4: fetch bucket assets (columnar)
        let assets_json = serde_json::json!({
            "id": ["mock-asset-1"],
            "type": ["IMAGE"],
            "fileCreatedAt": ["2024-03-01T12:00:00.000Z"],
            "fileModifiedAt": [null],
            "updatedAt": [null],
            "isFavorite": [true],
            "duration": [null],
            "livePhotoVideoId": [null],
            "thumbhash": ["mockhash"]
        });
        Mock::given(method("GET"))
            .and(path("/api/timeline/bucket"))
            .respond_with(ResponseTemplate::new(200).set_body_json(assets_json))
            .mount(&mock_server)
            .await;

        // Mock 5: thumbnail download
        Mock::given(method("GET"))
            .and(path("/api/assets/mock-asset-1/thumbnail"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(b"MOCK_THUMB_BYTES"))
            .mount(&mock_server)
            .await;

        // Mock 6: asset EXIF info
        let asset_info_json = serde_json::json!({
            "id": "mock-asset-1",
            "exifInfo": {
                "make": "Apple",
                "model": "iPhone 15 Pro",
                "fNumber": 1.78,
                "focalLength": 24.0,
                "iso": 80
            }
        });
        Mock::given(method("GET"))
            .and(path("/api/assets/mock-asset-1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(asset_info_json))
            .mount(&mock_server)
            .await;

        let client = ImmichClient::new(Some(mock_server.uri()), Some("test-api-key".to_string()));

        // 1. Verify ping
        let ping_res = client.ping().await.expect("Ping should succeed");
        assert!(ping_res);

        // 2. Verify bucket fallback logic
        let buckets = client.fetch_buckets().await.expect("Should fetch buckets via fallback");
        assert_eq!(buckets.len(), 1);
        assert_eq!(buckets[0].time_bucket, "2024-03-01T00:00:00.000Z");

        // 3. Verify bucket assets parsing
        let assets = client.fetch_bucket_assets("2024-03-01T00:00:00.000Z").await.expect("Should fetch assets");
        assert_eq!(assets.len(), 1);
        assert_eq!(assets[0].id, "mock-asset-1");
        assert!(assets[0].is_favorite);

        // 4. Verify thumbnail cache download
        let temp_dir = tempfile::tempdir().unwrap();
        let cached_thumb = client.download_image_cache("mock-asset-1", ThumbnailSize::Thumbnail, temp_dir.path())
            .await
            .expect("Should download thumbnail");
        assert!(cached_thumb.exists());
        let content = std::fs::read(&cached_thumb).unwrap();
        assert_eq!(content, b"MOCK_THUMB_BYTES");

        // 5. Verify EXIF fetch
        let exif = client.fetch_asset_exif("mock-asset-1").await.expect("Should fetch exif").expect("EXIF exists");
        assert_eq!(exif.make, Some("Apple".to_string()));
        assert_eq!(exif.model, Some("iPhone 15 Pro".to_string()));
        assert_eq!(exif.iso, Some(80));
    }
}
