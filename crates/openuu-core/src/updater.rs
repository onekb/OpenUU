use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::error::{OpenUUError, Result};

pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const GITHUB_LATEST_RELEASE_API: &str =
    "https://api.github.com/repos/onekb/OpenUU/releases/latest";
pub const GITHUB_RELEASES_PAGE: &str = "https://github.com/onekb/OpenUU/releases/latest";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateCheckResult {
    pub ok: bool,
    pub has_update: bool,
    pub current_version: String,
    pub latest_version: String,
    pub tag_name: String,
    pub release_title: String,
    pub release_notes: String,
    pub published_at: String,
    pub html_url: String,
    pub asset_name: String,
    pub download_url: String,
    pub asset_size_bytes: u64,
    pub asset_sha256: String,
    pub error: String,
}

#[derive(Debug, Clone, Deserialize)]
struct GithubReleasePayload {
    #[serde(default)]
    tag_name: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    html_url: String,
    #[serde(default)]
    published_at: String,
    #[serde(default)]
    draft: bool,
    #[serde(default)]
    assets: Vec<GithubReleaseAsset>,
}

#[derive(Debug, Clone, Deserialize)]
struct GithubReleaseAsset {
    #[serde(default)]
    name: String,
    #[serde(default)]
    size: u64,
    #[serde(default)]
    browser_download_url: String,
    #[serde(default)]
    digest: Option<String>,
}

/// Parses `"v0.7.0"`, `"0.7.0-windows"`, or `"0.7.1"` into `(major, minor, patch)`.
pub fn parse_semver(raw: &str) -> Option<(u32, u32, u32)> {
    let trimmed = raw.trim().trim_start_matches(['v', 'V']);
    let core = trimmed.split(['-', '+']).next()?.trim();
    let mut parts = core.split('.');
    let major: u32 = parts.next()?.parse().ok()?;
    let minor: u32 = parts.next().unwrap_or("0").parse().ok()?;
    let patch: u32 = parts.next().unwrap_or("0").parse().ok()?;
    Some((major, minor, patch))
}

pub fn normalize_version_str(raw: &str) -> String {
    if let Some((maj, min, pat)) = parse_semver(raw) {
        format!("{maj}.{min}.{pat}")
    } else {
        raw.trim().trim_start_matches(['v', 'V']).to_string()
    }
}

/// Returns `true` strictly when `latest` > `current` according to SemVer `(major, minor, patch)`.
pub fn is_newer_version(current: &str, latest: &str) -> bool {
    match (parse_semver(current), parse_semver(latest)) {
        (Some(cur), Some(lat)) => lat > cur,
        _ => false,
    }
}

fn select_platform_asset<'a>(
    assets: &'a [GithubReleaseAsset],
    platform: &str,
    arch: &str,
) -> Option<&'a GithubReleaseAsset> {
    let plat = platform.trim().to_ascii_lowercase();
    let arch_lc = arch.trim().to_ascii_lowercase();
    let is_arm = arch_lc.contains("arm") || arch_lc.contains("aarch64");
    let is_x86 = arch_lc.contains("x86") || arch_lc.contains("amd64") || arch_lc.contains("x64");

    let valid: Vec<&GithubReleaseAsset> = assets
        .iter()
        .filter(|a| !a.name.is_empty() && !a.browser_download_url.is_empty())
        .collect();

    match plat.as_str() {
        "macos" | "darwin" => valid
            .iter()
            .copied()
            .find(|a| {
                let n = a.name.to_ascii_lowercase();
                n.ends_with(".dmg")
                    && ((is_arm && (n.contains("arm64") || n.contains("aarch64")))
                        || (is_x86 && (n.contains("x64") || n.contains("x86_64"))))
            })
            .or_else(|| {
                valid
                    .iter()
                    .copied()
                    .find(|a| a.name.to_ascii_lowercase().ends_with(".dmg"))
            }),
        "windows" | "win32" | "win" => valid
            .iter()
            .copied()
            .find(|a| {
                let n = a.name.to_ascii_lowercase();
                n.contains("windows") && (n.ends_with(".zip") || n.ends_with(".exe"))
            })
            .or_else(|| {
                valid.iter().copied().find(|a| {
                    let n = a.name.to_ascii_lowercase();
                    n.ends_with("-x64.zip") || n.ends_with(".msi")
                })
            }),
        "android" => valid
            .iter()
            .copied()
            .find(|a| {
                let n = a.name.to_ascii_lowercase();
                n.ends_with(".apk")
                    && ((is_arm && n.contains("arm64")) || (is_x86 && n.contains("x86_64")))
            })
            .or_else(|| {
                valid
                    .iter()
                    .copied()
                    .find(|a| a.name.to_ascii_lowercase().ends_with(".apk"))
            }),
        "ios" | "ipados" => valid
            .iter()
            .copied()
            .find(|a| a.name.to_ascii_lowercase().ends_with(".ipa")),
        _ => None,
    }
}

fn parse_release_payload(
    payload: GithubReleasePayload,
    current_version: &str,
    platform: &str,
    arch: &str,
) -> Result<UpdateCheckResult> {
    if payload.draft || payload.tag_name.trim().is_empty() {
        return Err(OpenUUError::Wan("未获取到有效的正式发布版本信息".into()));
    }
    let cur_norm = normalize_version_str(if current_version.trim().is_empty() {
        CORE_VERSION
    } else {
        current_version
    });
    let latest_norm = normalize_version_str(&payload.tag_name);
    let has_update = is_newer_version(&cur_norm, &latest_norm);

    let matched = select_platform_asset(&payload.assets, platform, arch);
    let (asset_name, download_url, asset_size_bytes, asset_sha256) = if let Some(a) = matched {
        let sha = a
            .digest
            .as_deref()
            .unwrap_or("")
            .strip_prefix("sha256:")
            .unwrap_or("")
            .to_ascii_lowercase();
        (
            a.name.clone(),
            a.browser_download_url.clone(),
            a.size,
            sha,
        )
    } else {
        (String::new(), String::new(), 0, String::new())
    };

    let html_url = if payload.html_url.trim().is_empty() {
        GITHUB_RELEASES_PAGE.to_string()
    } else {
        payload.html_url
    };
    let release_title = if payload.name.trim().is_empty() {
        format!("OpenUU {}", payload.tag_name)
    } else {
        payload.name
    };

    Ok(UpdateCheckResult {
        ok: true,
        has_update,
        current_version: cur_norm,
        latest_version: latest_norm,
        tag_name: payload.tag_name,
        release_title,
        release_notes: payload.body.trim().to_string(),
        published_at: payload.published_at,
        html_url,
        asset_name,
        download_url,
        asset_size_bytes,
        asset_sha256,
        error: String::new(),
    })
}

async fn fetch_release_from_url(
    client: &reqwest::Client,
    url: &str,
) -> Result<GithubReleasePayload> {
    let resp = client
        .get(url)
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", format!("OpenUU/{CORE_VERSION}"))
        .send()
        .await
        .map_err(|e| OpenUUError::Wan(format!("请求更新接口失败: {e}")))?;

    if !resp.status().is_success() {
        return Err(OpenUUError::Wan(format!(
            "更新接口返回 HTTP {}",
            resp.status()
        )));
    }
    resp.json::<GithubReleasePayload>()
        .await
        .map_err(|e| OpenUUError::Wan(format!("解析版本信息失败: {e}")))
}

/// Checks for updates by querying `{coord_url}/v1/latest-release` first (edge-cached, Mainland-friendly),
/// automatically falling back to GitHub's official Releases API.
pub async fn check_latest_release(
    coord_url: &str,
    allow_insecure_tls: bool,
    current_version: &str,
    platform: &str,
    arch: &str,
) -> UpdateCheckResult {
    let cur_norm = normalize_version_str(if current_version.trim().is_empty() {
        CORE_VERSION
    } else {
        current_version
    });

    let client = match reqwest::Client::builder()
        .timeout(Duration::from_secs(6))
        .connect_timeout(Duration::from_secs(4))
        .danger_accept_invalid_certs(allow_insecure_tls)
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            return UpdateCheckResult::failure(&cur_norm, format!("HTTP 客户端初始化失败: {e}"));
        }
    };

    let base_coord = coord_url.trim().trim_end_matches('/');
    if !base_coord.is_empty() {
        let mirror_url = format!("{base_coord}/v1/latest-release");
        if let Ok(payload) = fetch_release_from_url(&client, &mirror_url).await {
            if let Ok(res) = parse_release_payload(payload, &cur_norm, platform, arch) {
                return res;
            }
        }
    }

    match fetch_release_from_url(&client, GITHUB_LATEST_RELEASE_API).await {
        Ok(payload) => match parse_release_payload(payload, &cur_norm, platform, arch) {
            Ok(res) => res,
            Err(e) => UpdateCheckResult::failure(&cur_norm, format!("{e}")),
        },
        Err(e) => UpdateCheckResult::failure(&cur_norm, format!("{e}")),
    }
}

impl UpdateCheckResult {
    pub fn failure(current_version: &str, error: String) -> Self {
        Self {
            ok: false,
            has_update: false,
            current_version: current_version.to_string(),
            latest_version: String::new(),
            tag_name: String::new(),
            release_title: String::new(),
            release_notes: String::new(),
            published_at: String::new(),
            html_url: GITHUB_RELEASES_PAGE.to_string(),
            asset_name: String::new(),
            download_url: String::new(),
            asset_size_bytes: 0,
            asset_sha256: String::new(),
            error,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semver_comparison_and_asset_matching() {
        assert_eq!(parse_semver("v0.7.0"), Some((0, 7, 0)));
        assert_eq!(parse_semver("0.7.0-windows"), Some((0, 7, 0)));
        assert!(is_newer_version("0.6.0", "v0.7.0"));
        assert!(is_newer_version("v0.7.0", "0.7.1"));
        assert!(is_newer_version("0.7.9", "1.0.0"));
        assert!(!is_newer_version("0.7.0", "v0.7.0"));
        assert!(!is_newer_version("0.8.0", "v0.7.0"));

        let sample_json = r####"{
            "tag_name": "v0.8.0",
            "name": "OpenUU v0.8.0",
            "body": "### 新增\n- 支持一键无感更新",
            "html_url": "https://github.com/onekb/OpenUU/releases/tag/v0.8.0",
            "published_at": "2026-11-23T08:00:00Z",
            "draft": false,
            "assets": [
                {
                    "name": "OpenUU-v0.8.0-macOS-arm64.dmg",
                    "size": 24117248,
                    "browser_download_url": "https://github.com/onekb/OpenUU/releases/download/v0.8.0/OpenUU-v0.8.0-macOS-arm64.dmg",
                    "digest": "sha256:abcdef0123456789"
                },
                {
                    "name": "OpenUU-v0.8.0-Windows-x64.zip",
                    "size": 68157440,
                    "browser_download_url": "https://github.com/onekb/OpenUU/releases/download/v0.8.0/OpenUU-v0.8.0-Windows-x64.zip"
                },
                {
                    "name": "OpenUU-v0.8.0-Android-arm64.apk",
                    "size": 19922944,
                    "browser_download_url": "https://github.com/onekb/OpenUU/releases/download/v0.8.0/OpenUU-v0.8.0-Android-arm64.apk"
                },
                {
                    "name": "OpenUU-v0.8.0-iOS-unsigned.ipa",
                    "size": 14680064,
                    "browser_download_url": "https://github.com/onekb/OpenUU/releases/download/v0.8.0/OpenUU-v0.8.0-iOS-unsigned.ipa"
                }
            ]
        }"####;

        let payload: GithubReleasePayload = serde_json::from_str(sample_json).unwrap();
        let mac_res =
            parse_release_payload(payload.clone(), "v0.7.0", "macos", "aarch64").unwrap();
        assert!(mac_res.has_update);
        assert_eq!(mac_res.latest_version, "0.8.0");
        assert_eq!(mac_res.asset_name, "OpenUU-v0.8.0-macOS-arm64.dmg");
        assert_eq!(mac_res.asset_sha256, "abcdef0123456789");

        let win_res = parse_release_payload(payload.clone(), "0.8.0", "windows", "x86_64").unwrap();
        assert!(!win_res.has_update);
        assert_eq!(win_res.asset_name, "OpenUU-v0.8.0-Windows-x64.zip");

        let and_res = parse_release_payload(payload.clone(), "0.7.0", "android", "arm64").unwrap();
        assert!(and_res.has_update);
        assert_eq!(and_res.asset_name, "OpenUU-v0.8.0-Android-arm64.apk");

        let ios_res = parse_release_payload(payload, "0.7.0", "ios", "arm64").unwrap();
        assert!(ios_res.has_update);
        assert_eq!(ios_res.asset_name, "OpenUU-v0.8.0-iOS-unsigned.ipa");
    }
}
