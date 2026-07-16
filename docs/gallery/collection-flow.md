# Gallery Collection Flow

图库采集有两个入口：手动选择图片采集和自动全库分析。两者共用同一套分析管线和存储格式。

## Manual Selection

手动选择图片采集使用系统图片选择器：

```text
PhotoViewPicker -> photoUris[] -> GalleryAnalyzer.analyzeUris(...)
```

行为：

- 用户显式选择图片。
- 当前选择上限由页面传入，现阶段为 9 张。
- picker 只返回 URI；分析器会在解码图片时尝试读取 EXIF。若 EXIF 包含 `DateTimeOriginal`，归档日期使用拍摄日期，否则退回到分析日期。
- 未命中缓存的图片会读取 EXIF 元数据，包括拍摄时间、拍摄设备和 GPS 经纬度；这些字段会写入 item JSON，并在详情页基础信息中展示。
- 读取 EXIF GPS 位置依赖 `ohos.permission.MEDIA_LOCATION`，用户未授权时仍会继续分析图片，但拍摄位置可能为空。
- 每张图片进入分析前仍会检查 `items/<date>/<id>.json`，命中缓存时跳过后续分析。

适用场景：

- 调试 OCR / 大模型 / embedding 效果。
- 小批量补采。
- 用户只想分析某几张图片。

## Automatic Full Library Analysis

自动分析不使用系统图片选择器，而是直接读取图库 asset 列表：

```text
photoAccessHelper.getPhotoAccessHelper(context)
  -> getAssets(...)
  -> GalleryAnalyzer.analyzeInputs(...)
```

当前策略：

- 需要 `ohos.permission.READ_IMAGEVIDEO` 权限；读取媒体位置时还需要 `ohos.permission.MEDIA_LOCATION`。
- 扫描图库全量图片。
- 按 `PhotoKeys.DATE_ADDED` 倒序读取。
- 从 asset 中读取 `DATE_ADDED`，失败时再尝试 `DATE_MODIFIED`。
- 位置优先使用图库 asset 元数据；asset 无位置时，分析器从图片 EXIF GPS 字段兜底读取。
- 生成 `GalleryPhotoInput`，包含 `uri`、稳定 `id` 和归档 `date`。
- 自动扫描开始时创建 `scan-session.json` 队列。
- 每张图片先检查 `items/<date>/<id>.json`。
- 缓存命中时跳过图片解码、OCR、大模型和 embedding。
- 缓存未命中时完整执行 OCR、大模型分析、embedding 和落盘。

## Pause And Resume

自动全库分析支持暂停和继续。

暂停行为：

- 暂停是软暂停。
- 已经开始的 OCR、模型请求、embedding 和文件写入会继续完成。
- 当前并发任务完成后，不再领取新的图片。
- 每张图片完成后都会更新 `scan-session.json`。
- 剩余图片保持 `queued` 状态。

继续行为：

- 页面读取 `scan-session.json`。
- 把 `queued` 和上次临时失败的 `failed` 图片重新送入分析管线。
- `done`、`skipped` 不会重复处理。
- 每张重新送入的图片仍会先检查 `items/<date>/<id>.json`，命中成功缓存则转为 `skipped`。

进度统计：

- `总数`：本次全库扫描生成的图片数量。
- `已完成`：`done + skipped`。
- `未完成`：尚未完成的图片数量，包含未领取、正在执行和上次失败待重试的任务。
- `跳过`：命中缓存或 OCR 关键词预筛过滤的图片数量。
- `失败`：分析失败的图片数量。

## Shared Pipeline

两个入口最终都会进入同一条分析管线：

1. 生成或接收稳定图片 `id` 和归档 `date`。
2. 检查 `gallery-log/items/<date>/<id>.json`。
3. 命中缓存则直接复用 item JSON。
4. 未命中缓存则解码图片。
5. 通过 `ImageSource.getImageProperty()` 读取 EXIF 元数据。
6. 按设置执行或跳过鸿蒙本地 OCR。
7. 调用云端多模态模型，解析 `title/category/summary/tags`；拍摄时间、设备和经纬度会作为可核查元数据附加到 prompt。
8. 对标题、类别、摘要和 OCR 文本拼接后做 embedding。
9. 写入 `embeddings/<date>/<id>.json`。
10. 写入 `items/<date>/<id>.json`。
11. 批次结束后，从本批次涉及日期的 items 重建 daily-log markdown。

## Operational Notes

自动全库分析可能覆盖几千张图片，首次运行会产生大量 OCR、模型和 embedding 工作。缓存命中能避免重复处理，但首次冷启动仍然需要较长时间。

### Map Kit / AGC Pending Setup

图片 EXIF 坐标读取、方向标注和详情页经纬度展示不依赖 AGC；这些能力只需要图片访问权限和 `MEDIA_LOCATION` 授权。

详情页内嵌地图底图、POI/地理位置渲染和 `sceneMap.queryLocation()` 依赖华为 Map Kit 服务端能力。当前本地调试包如果未在 AppGallery Connect（AGC）中给应用开通地图服务，或未配置匹配包名/签名指纹的 `agconnect-services.json`，地图组件只能显示 marker/Logo，底图和具体地理位置会缺失。典型日志如下：

```text
code=1002600004, message=The Map permission is not enabled.
```

待完善事项：

- 在 AGC 中为当前包名 `com.clawmate.app` 开通 Map Kit / 地图服务。
- 配置当前调试签名证书指纹。
- 下载匹配应用的 `agconnect-services.json` 并放入应用级目录。
- 重新构建安装后确认 HiLog 中不再出现 `1002600004`。

后续建议补充：

- 失败重试队列。
- 后台进度持久化。
- 仅 Wi-Fi / 充电时运行。
