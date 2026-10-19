# 系统图库与 Immich 收藏同步：可行性与推荐方案

> 状态：官方文档调研，未做三平台 SDK 编译和真机验证。用户已确认“先本 App 本地收藏，系统图库能联动就联动，照片正常上传并匹配后同步当前账户的 Immich 收藏”。完整收藏同步方向、取消收藏传播与冲突规则仍待定，不自动视为已批准双向同步。

## 1. 结论

**可以实现 App 本地收藏状态 → 已匹配的 Immich 云端资产收藏；但不能承诺在本项目全部最低支持系统上，与系统图库收藏无感双向一致。**

应区分三个状态：系统图库收藏、本 App 本地保存的收藏意图、某服务器某账户的 Immich 收藏。这三个状态不能只用一个布尔值表示所有同步进度。

Rust 多版本适配解决 Immich API 差异，不会绕过操作系统的图库访问权限、API 开放等级和用户确认。

## 2. 官方能力核查

| 平台 | 读取系统收藏 | 修改系统收藏 | 结论与限制 |
| --- | --- | --- | --- |
| iOS | PhotoKit 的 `PHAsset.isFavorite`，仅限有权访问的资产 | `PHAssetChangeRequest.isFavorite`，在 Photo Library change block 中提交 | 有公开读写能力；需要相应图库授权，有限授权不是全库。库变更存在系统确认机制，不承诺每次都可后台静默成功；必须检查实际结果 |
| Android | Android 11 / API 30 起 `MediaStore.MediaColumns.IS_FAVORITE` | API 30 起 `MediaStore.createFavoriteRequest` 发起系统请求，用户同意后设置；其他已获写权限路径依实际授权判断 | 官方标准媒体库可对接，但不保证所有 OEM / 第三方相册的私有收藏都与 MediaStore 一致，必须逐机验证；旧版本需要降级 |
| HarmonyOS NEXT | `PhotoKeys.FAVORITE`、系统 FAVORITE 相册，依 READ_IMAGEVIDEO 等实际权限访问 | 华为当前普通应用文档中 `MediaAssetChangeRequest.setFavorite` 标注 **26.0.0 起**；OpenHarmony 的较早 `setFavorite` 文档标注系统接口 | 不能把新版本方法用于本项目 API 12 基线，也不能因获批读写图库受限权限就假定可调用系统接口。最低支持范围内系统收藏写回必须按不可保证处理，新版本按实际 SDK / 权限验证后启用 |

### 证据边界

- 华为新版公开文档的 `setFavorite` 起始版本是关键证据，不能笼统断言“鸿蒙任何版本都不支持普通应用修改收藏”。
- OpenHarmony 的系统 API 文档只用于说明较早相关接口的系统限定；不以它替代所有商业 HarmonyOS 版本的能力判断。
- `PhotoKeys.FAVORITE` 可读不证明 `PhotoAsset.set` 可任意写此字段；不能绕过公开接口用元数据写入示例实现收藏。
- Apple 的库变更文档说明有系统确认机制；具体收藏变更在目标系统 / 授权状态下的提示频率需真机验证，不把一般说明推断为“所有系统每点一次爱心必弹一次”。
- Android `createFavoriteRequest` 是创建请求，不是调用后即收藏成功；需完成系统流程并检查结果。拒绝或取消不得伪装已写入系统。

## 3. 已确认核心策略与实现约束

### 3.1 App 本地收藏优先，系统图库联动按能力启用

1. 用户在 App 收藏本机独有照片时，先可靠保存 App 本地收藏意图，支持离线。
2. 有公开能力、权限且用户同意时，写入系统图库收藏；不具备能力时显示这是 App 收藏，不声称系统图库已经改变。
3. 已上传且成功匹配到当前账户云端资产时，同步收藏元数据；同步失败保留待处理状态并可重试。
4. 尚未上传时，只有在它原本属于用户确认的备份范围、当前账户开启备份且没有被禁止重传时，才随正常备份上传，再提交收藏状态。
5. **点收藏不隐式上传原件、不扩大备份相册范围、不解除禁止自动重传。** 不在备份范围的照片可以只收藏在 App 内，等待用户明确手动上传。
6. 云端独有照片可收藏于 Immich，不为了同步系统收藏而偷偷下载到系统图库。

这保留了用户希望的“先本机收藏、后续到云端”，但把“App 本地”和“系统图库”诚实区分，不用最低平台不具备的能力阻塞全部收藏功能。

### 3.2 完整同步方向待定

用户已明确收藏同步方向后定。上传成功并匹配后提交此前保存的收藏意图已确认，但不因此推出全库持续单向覆盖或双向镜像。

- App 内操作 → 当前账户的云端收藏：上传并匹配后的收藏意图提交已确认；已存在资产的持续同步范围仍需规则。
- 系统图库收藏 → App / 云端：授权后可提供导入 / 同步；自动覆盖范围与初始合并规则需确认。
- 云端收藏 → 系统图库：按平台能力、用户选择及系统确认处理，不承诺后台强制写回。
- 取消收藏的传播、首次本机与云端状态不同的处理，不能未经确认就采用“任一端为真则永远为真”或“最后读到的覆盖”。

### 3.3 多账户与冲突

- 系统图库收藏是设备媒体的状态，不天然按 Immich 账户隔离；A 账户收藏不应在切到 B 后自动写入 B，除非 B 的收藏导入规则明确允许。
- App 待同步意图绑定发起时的服务器与账户；账户切换不会改投目标。
- 防重传决策与收藏意图独立，收藏元数据操作不等于允许上传原件。
- 离线连续收藏 / 取消收藏应归并成最终意图，避免恢复网络后反复闪动；需保留必要版本信息以处理远端并发变化。
- 无访问权限 / 未读取到资产时，不把未知当成未收藏，更不能据此批量清除云端收藏。

## 4. 对开工的影响

- 不阻塞照片流四列默认、二至十五列正方形网格的原型，也不阻塞同步状态模型和备份范围选择设计。
- 本地收藏与系统按能力联动的降级策略已确认；在完整同步方向确定前，不实现全库自动双向覆盖或隐式上传。
- 用户已明确：曾同步、后手动删除云端而仅保留本机的照片，用缩略图右下角专用图标区分，只有明确手动上传才可重传；收藏或加云端相册不能触发上传。
- 本机照片“加入云端相册”与收藏是两个操作；不采用先前“点击加相册，确认后自动代为上传”的建议。目标云端资产不存在时，先说明需独立手动上传；是否保留待加入相册意图另行确定。

## 5. 官方来源

- [Apple PHAsset.isFavorite](https://developer.apple.com/documentation/photos/phasset/isfavorite)
- [Apple PHAssetChangeRequest](https://developer.apple.com/documentation/photos/phassetchangerequest)
- [Apple Requesting Changes to the Photo Library](https://developer.apple.com/documentation/photokit/requesting-changes-to-the-photo-library)
- [Android MediaStore](https://developer.android.com/reference/android/provider/MediaStore)：`createFavoriteRequest` 自 API 30 起、系统用户确认及回调结果。
- [Android MediaColumns](https://developer.android.com/reference/android/provider/MediaStore.MediaColumns)：`IS_FAVORITE`。
- [HarmonyOS 系统相册资源使用指导](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/photoaccesshelper-systemalbum-guidelines)
- [HarmonyOS PhotoKeys 等枚举](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-photoaccesshelper-e)
- [HarmonyOS MediaAssetChangeRequest](https://developer.huawei.com/consumer/cn/doc/harmonyos-references/arkts-apis-photoaccesshelper-mediaassetchangerequest)：新版公开 `setFavorite` 标注 26.0.0 起。
- [OpenHarmony 系统 photoAccessHelper API](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-media-library-kit/js-apis-photoAccessHelper-sys.md)：较早收藏接口的系统 API 限定，仅作明确标注的平台参考。
