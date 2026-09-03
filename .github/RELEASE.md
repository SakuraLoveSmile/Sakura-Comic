# 发布（GitHub Release）

本文描述如何用 `.github/workflows/release.yml` 一键产出各平台的已签名产物并自动创建 GitHub Release。

## 触发方式

- **打 tag 自动发版**（推荐）
  ```bash
  git tag v0.1.0
  git push origin v0.1.0
  ```
  workflow 监听 `push: tags: ["v*"]`，自动以该 tag 创建 Release。

- **手动触发**
  GitHub → Actions → Release → Run workflow
  可填 `version`（如 `v0.1.0`，空则取 `android/app/pubspec.yaml` 的 `version` 字段）
  与 `draft` 开关。

## Android 产物

- `app-arm64-v8a-release.apk` / `app-armeabi-v7a-release.apk` / `app-x86_64-release.apk`
- `app-release.aab`（Play Store 用）

构建前会执行 `scripts/frb_wire.sh`（FRB 生成 + `cargo ndk --release --features frb` 三 ABI 的 `.so`），因此无需提交 `jniLibs/`。

### 一次性：把本地自签密钥注册到仓库 Secrets

本地已由 `scripts/android_release_key.sh` 生成（git-忽略）：

- `android/app/android/keystore/comic-release.jks`
- `android/app/android/key.properties`（含 `storePassword`/`keyPassword`/`keyAlias`）

在仓库中注册 4 个 Secrets（Settings → Secrets and variables → Actions → New repository secret）：

```bash
# macOS
base64 -i android/app/android/keystore/comic-release.jks | tr -d '\n' | pbcopy
# Linux
# base64 -w0 android/app/android/keystore/comic-release.jks | xclip -selection clipboard

# 粘贴为 ANDROID_KEYSTORE_BASE64
# 另三个直接从 android/app/android/key.properties 复制：
# ANDROID_KEYSTORE_PASSWORD = storePassword
# ANDROID_KEY_PASSWORD      = keyPassword
# ANDROID_KEY_ALIAS         = keyAlias  （默认 comic-release）
```

> ⚠️ `.jks` + `key.properties` 是 `dev.sakurasep.comic` 的终身身份，丢了旧安装就无法覆盖升级。

CI 中 workflow 会把 `ANDROID_KEYSTORE_BASE64` 解回 `keystore/comic-release.jks` 并现场生成 `key.properties`，失败则 loud-fail（`build.gradle.kts` 要求 release 必须签名，不会悄悄退回 debug 签名）。

## Apple 产物

- `ComicApp_iOS-Release-iphoneos-v*.app.zip`（unsigned，`CODE_SIGNING_ALLOWED=NO`）
- `ComicApp_macOS-...app.zip` 同理

`apple/ComicApp/project.yml` 由 `xcodegen generate` 生成 `.xcodeproj`（git-忽略），workflow 已包含该步。
tvOS / visionOS 已从本次发布流水线中暂时移除（按当前需求），后续需要可在 `release.yml` 中恢复对应 job 步骤。

> 当前 `bundleIdPrefix` 仍为 `com.example.comic`（`apple/ComicApp/project.yml:5`）。首次提交 App Store / TestFlight 前建议改为 `dev.sakurasep.comic`，与 Android 的 `applicationId` 保持一致（改后需在 Apple Developer Portal 重新注册 bundle IDs）。

要产出可安装的签名 IPA / pkg，需在 `release.yml` 的 `apple` job 中把 `CODE_SIGNING_ALLOWED=NO` 换成你的 `CODE_SIGN_IDENTITY` / `PROVISIONING_PROFILE_SPECIFIER` / `DEVELOPMENT_TEAM`，并注入 `APPLE_CERTIFICATE_*` 等 Secrets。

## 版本号

- `android/app/pubspec.yaml` 的 `version: 0.1.0+2` 同时决定 `versionName`/`versionCode`。
- Apple 各 target 的 `MARKETING_VERSION` 需手动与之同步（或在 release job 里加一步 `grep` 同步）。
- 覆盖安装测试：同签名下 `0.1.0+1 → 0.1.0+2` 已在本地验证不丢库与下载。

## 产物校验

Android 构建后会执行：

```bash
$ANDROID_HOME/build-tools/*/apksigner verify --print-certs app-arm64-v8a-release.apk
# 应显示  CN=Comic, OU=Personal, O=Comic  （自签），而非  CN=Android Debug
```
