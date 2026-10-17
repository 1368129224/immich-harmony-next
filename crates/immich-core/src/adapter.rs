use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const MODERN_BUCKETS_QUERY: &str = "visibility=timeline&withPartners=true";
pub const LEGACY_BUCKETS_QUERY: &str = "size=MONTH&isArchived=false";

#[derive(Error, Debug)]
pub enum AdapterError {
    #[error("Failed to parse JSON: {0}")]
    JsonError(#[from] serde_json::Error),
    #[error("Invalid timeline data structure: {0}")]
    InvalidData(String),
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct BucketInfo {
    #[serde(alias = "timeBucket")]
    pub time_bucket: String,
    #[serde(default)]
    pub count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Asset {
    pub id: String,
    #[serde(rename = "type")]
    pub asset_type: String,
    pub file_created_at: String,
    pub file_modified_at: Option<String>,
    pub updated_at: Option<String>,
    #[serde(default)]
    pub is_favorite: bool,
    pub duration: Option<String>,
    pub live_photo_video_id: Option<String>,
    pub thumbhash: Option<String>,
    pub local_thumb_path: Option<String>,
    pub local_preview_path: Option<String>,
    pub local_video_path: Option<String>,
    pub bucket_id: Option<String>,
    pub exif: Option<ExifResponseDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ExifResponseDto {
    pub make: Option<String>,
    pub model: Option<String>,
    pub lens_model: Option<String>,
    pub f_number: Option<f64>,
    pub focal_length: Option<f64>,
    pub iso: Option<i64>,
    pub exposure_time: Option<String>,
    pub date_time_original: Option<String>,
    pub file_size_in_byte: Option<i64>,
    pub city: Option<String>,
    pub state: Option<String>,
    pub country: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub projection_type: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ColumnarBucketDto {
    pub id: Vec<String>,
    #[serde(rename = "type")]
    pub asset_type: Option<Vec<String>>,
    pub file_created_at: Option<Vec<String>>,
    pub file_modified_at: Option<Vec<Option<String>>>,
    pub updated_at: Option<Vec<Option<String>>>,
    pub is_favorite: Option<Vec<Option<bool>>>,
    pub duration: Option<Vec<Option<String>>>,
    pub live_photo_video_id: Option<Vec<Option<String>>>,
    pub thumbhash: Option<Vec<Option<String>>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyAssetDto {
    pub id: String,
    #[serde(rename = "type")]
    pub asset_type: String,
    pub file_created_at: String,
    pub file_modified_at: Option<String>,
    pub updated_at: Option<String>,
    #[serde(default)]
    pub is_favorite: bool,
    pub duration: Option<String>,
    pub live_photo_video_id: Option<String>,
    pub thumbhash: Option<String>,
    pub exif_info: Option<ExifResponseDto>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum RawBucketResponse {
    Columnar(ColumnarBucketDto),
    LegacyArray(Vec<LegacyAssetDto>),
}

/// Parses the response of `/api/timeline/bucket`, supporting both modern columnar
/// `{ id: [...], type: [...] }` and legacy array of objects `[{ id, type, ... }]`.
pub fn parse_bucket_response(
    json_str: &str,
    bucket_id: Option<&str>,
) -> Result<Vec<Asset>, AdapterError> {
    let raw: RawBucketResponse = serde_json::from_str(json_str)?;

    match raw {
        RawBucketResponse::Columnar(col) => {
            let total = col.id.len();
            let mut assets = Vec::with_capacity(total);

            for i in 0..total {
                let id = col.id[i].clone();
                let asset_type = col
                    .asset_type
                    .as_ref()
                    .and_then(|v| v.get(i))
                    .cloned()
                    .unwrap_or_else(|| "IMAGE".to_string());
                let file_created_at = col
                    .file_created_at
                    .as_ref()
                    .and_then(|v| v.get(i))
                    .cloned()
                    .unwrap_or_default();
                let file_modified_at = col
                    .file_modified_at
                    .as_ref()
                    .and_then(|v| v.get(i))
                    .cloned()
                    .flatten();
                let updated_at = col
                    .updated_at
                    .as_ref()
                    .and_then(|v| v.get(i))
                    .cloned()
                    .flatten();
                let is_favorite = col
                    .is_favorite
                    .as_ref()
                    .and_then(|v| v.get(i))
                    .copied()
                    .flatten()
                    .unwrap_or(false);
                let duration = col
                    .duration
                    .as_ref()
                    .and_then(|v| v.get(i))
                    .cloned()
                    .flatten();
                let live_photo_video_id = col
                    .live_photo_video_id
                    .as_ref()
                    .and_then(|v| v.get(i))
                    .cloned()
                    .flatten();
                let thumbhash = col
                    .thumbhash
                    .as_ref()
                    .and_then(|v| v.get(i))
                    .cloned()
                    .flatten();

                assets.push(Asset {
                    id,
                    asset_type,
                    file_created_at,
                    file_modified_at,
                    updated_at,
                    is_favorite,
                    duration,
                    live_photo_video_id,
                    thumbhash,
                    local_thumb_path: None,
                    local_preview_path: None,
                    local_video_path: None,
                    bucket_id: bucket_id.map(ToString::to_string),
                    exif: None,
                });
            }

            Ok(assets)
        }
        RawBucketResponse::LegacyArray(legacy) => {
            let assets = legacy
                .into_iter()
                .map(|item| Asset {
                    id: item.id,
                    asset_type: item.asset_type,
                    file_created_at: item.file_created_at,
                    file_modified_at: item.file_modified_at,
                    updated_at: item.updated_at,
                    is_favorite: item.is_favorite,
                    duration: item.duration,
                    live_photo_video_id: item.live_photo_video_id,
                    thumbhash: item.thumbhash,
                    local_thumb_path: None,
                    local_preview_path: None,
                    local_video_path: None,
                    bucket_id: bucket_id.map(ToString::to_string),
                    exif: item.exif_info,
                })
                .collect();
            Ok(assets)
        }
    }
}

/// Parses the `/api/timeline/buckets` response into a list of BucketInfo.
pub fn parse_buckets_response(json_str: &str) -> Result<Vec<BucketInfo>, AdapterError> {
    let buckets: Vec<BucketInfo> = serde_json::from_str(json_str)?;
    Ok(buckets)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_modern_columnar() {
        let json_data = r#"{
            "id": ["uuid-1", "uuid-2"],
            "type": ["IMAGE", "VIDEO"],
            "fileCreatedAt": ["2024-03-01T12:00:00.000Z", "2024-03-01T13:00:00.000Z"],
            "fileModifiedAt": [null, "2024-03-01T13:30:00.000Z"],
            "updatedAt": ["2024-03-01T12:00:00.000Z", null],
            "isFavorite": [true, false],
            "duration": [null, "0:00:15.000000"],
            "livePhotoVideoId": ["video-uuid-1", null],
            "thumbhash": ["thumbhash1", "thumbhash2"]
        }"#;

        let assets = parse_bucket_response(json_data, Some("2024-03-01T00:00:00.000Z"))
            .expect("Columnar parse should succeed");

        assert_eq!(assets.len(), 2);

        let first = &assets[0];
        assert_eq!(first.id, "uuid-1");
        assert_eq!(first.asset_type, "IMAGE");
        assert_eq!(first.file_created_at, "2024-03-01T12:00:00.000Z");
        assert_eq!(first.file_modified_at, None);
        assert_eq!(first.updated_at, Some("2024-03-01T12:00:00.000Z".to_string()));
        assert!(first.is_favorite);
        assert_eq!(first.duration, None);
        assert_eq!(first.live_photo_video_id, Some("video-uuid-1".to_string()));
        assert_eq!(first.thumbhash, Some("thumbhash1".to_string()));
        assert_eq!(first.bucket_id, Some("2024-03-01T00:00:00.000Z".to_string()));

        let second = &assets[1];
        assert_eq!(second.id, "uuid-2");
        assert_eq!(second.asset_type, "VIDEO");
        assert!(!second.is_favorite);
        assert_eq!(second.duration, Some("0:00:15.000000".to_string()));
        assert_eq!(second.live_photo_video_id, None);
    }

    #[test]
    fn test_parse_legacy_array() {
        let json_data = r#"[
            {
                "id": "uuid-legacy-1",
                "type": "IMAGE",
                "fileCreatedAt": "2023-11-15T08:30:00.000Z",
                "fileModifiedAt": "2023-11-15T08:30:00.000Z",
                "updatedAt": "2023-11-15T08:30:00.000Z",
                "isFavorite": true,
                "duration": null,
                "livePhotoVideoId": null,
                "thumbhash": "legacyhash"
            }
        ]"#;

        let assets = parse_bucket_response(json_data, Some("2023-11-01T00:00:00.000Z"))
            .expect("Legacy array parse should succeed");

        assert_eq!(assets.len(), 1);
        let item = &assets[0];
        assert_eq!(item.id, "uuid-legacy-1");
        assert_eq!(item.asset_type, "IMAGE");
        assert_eq!(item.file_created_at, "2023-11-15T08:30:00.000Z");
        assert!(item.is_favorite);
        assert_eq!(item.thumbhash, Some("legacyhash".to_string()));
        assert_eq!(item.bucket_id, Some("2023-11-01T00:00:00.000Z".to_string()));
    }

    #[test]
    fn test_parse_legacy_array_with_exif() {
        let json_data = r#"[
            {
                "id": "uuid-legacy-exif",
                "type": "IMAGE",
                "fileCreatedAt": "2023-11-15T08:30:00.000Z",
                "fileModifiedAt": null,
                "updatedAt": null,
                "isFavorite": false,
                "duration": null,
                "livePhotoVideoId": null,
                "thumbhash": null,
                "exifInfo": {
                    "make": "Sony",
                    "model": "ILCE-7M4",
                    "fNumber": 2.8,
                    "focalLength": 35.0,
                    "iso": 200,
                    "exposureTime": "1/250"
                }
            }
        ]"#;

        let assets = parse_bucket_response(json_data, Some("2023-11-01T00:00:00.000Z"))
            .expect("Legacy array parse with exif should succeed");

        assert_eq!(assets.len(), 1);
        let exif = assets[0].exif.as_ref().expect("exif should be present");
        assert_eq!(exif.make, Some("Sony".to_string()));
        assert_eq!(exif.model, Some("ILCE-7M4".to_string()));
        assert_eq!(exif.f_number, Some(2.8));
        assert_eq!(exif.focal_length, Some(35.0));
        assert_eq!(exif.iso, Some(200));
        assert_eq!(exif.exposure_time, Some("1/250".to_string()));
    }

    #[test]
    fn test_parse_buckets_response() {
        let json_data = r#"[
            {"timeBucket": "2024-03-01T00:00:00.000Z", "count": 128},
            {"timeBucket": "2024-02-01T00:00:00.000Z", "count": 64}
        ]"#;

        let buckets = parse_buckets_response(json_data).expect("Should parse buckets");
        assert_eq!(buckets.len(), 2);
        assert_eq!(buckets[0].time_bucket, "2024-03-01T00:00:00.000Z");
        assert_eq!(buckets[0].count, 128);
        assert_eq!(buckets[1].time_bucket, "2024-02-01T00:00:00.000Z");
        assert_eq!(buckets[1].count, 64);
    }
}
