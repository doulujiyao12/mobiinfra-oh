# Gallery Storage Format

图库采集结果按日期拆分存储。`items` 和 `embeddings` 使用单图单文件，支持并发写入；`daily-log` 是按天、按类别生成的 Markdown 派生索引，批次结束后从当天 items 统一重建。

## Directory

应用内实际根目录为 `filesDir/gallery-log`。当前调试包在真机上的参考路径为 `/data/app/el2/100/base/com.clawmate.app/haps/entry/files/gallery-log/`。

```text
gallery-log/
  daily-log/
    2026-06-01/
      聊天.md
      餐饮.md
  items/
    2026-06-01/
      gallery_123.json
      gallery_456.json
  embeddings/
    2026-06-01/
      gallery_123.json
      gallery_456.json
```

目录职责：

- `daily-log/<date>/<category>.md` 面向人读，按类别拆分摘要。
- `items/<date>/<id>.json` 面向程序查重和读取完整分析结果，不按类别拆分。
- `embeddings/<date>/<id>.json` 面向向量检索，不按类别拆分。

`items` 和 `embeddings` 不使用 category 作为路径的一部分，因为 category 是大模型分析后的结果。分析前如果路径依赖 category，就无法快速判断图片是否已经处理过。

## Daily Markdown

每个 daily-log 文件对应一天内的一个类别，例如 `gallery-log/daily-log/2026-06-01/餐饮.md`。

```md
<!-- DAILY_LOG_METADATA
{
  "source": "gallery",
  "date": "2026-06-01",
  "category": "餐饮",
  "latest_entry_index": 2,
  "item_count": 2
}
-->

# 2026-06-01 / 餐饮

1. [gallery_456] 早餐聊天截图: 微信聊天中提到去楼下买豆浆、包子和鸡蛋。
   - 对方要求购买豆浆和两个包子。
   - 聊天发生在早餐时段，内容和楼下早餐店相关。
   - 可作为当天早餐偏好和代买事项记录。

2. [gallery_789] 早餐小票: 便利店早餐消费记录，包含豆浆、饭团和付款金额。
   - 商品包含豆浆和饭团。
   - 小票中保留了付款金额和消费商户。
```

规则：

- `metadata` 用于快速读取日期、类别和条目数量。
- 正文每条保留 `id/title/summary`，并展开模型提取的 `details` 细节，方便人读和快速检索。
- daily-log 记录具体但仍保持轻量；完整 OCR、原始模型返回、embedding 引用等使用 `id` 到 `items` 目录查详情。
- daily-log 不作为事实源；同一天任意 item 更新后，可从 `items/<date>` 全量重建 `daily-log/<date>/*.md`。

## Item JSON

单张图片的完整分析结果保存在 `gallery-log/items/<date>/<id>.json`。

```json
{
  "id": "gallery_456",
  "uri": "file://media/Photo/12/IMG_0001.jpg",
  "title": "早餐聊天截图",
  "category": "餐饮",
  "summary": "微信聊天中提到去楼下买豆浆、包子和鸡蛋。",
  "details": [
    "对方要求购买豆浆和两个包子。",
    "聊天发生在早餐时段，内容和楼下早餐店相关。",
    "可作为当天早餐偏好和代买事项记录。"
  ],
  "tags": ["早餐", "微信", "买饭"],
  "ocrText": "你帮我买个豆浆和两个包子...",
  "rawModelText": "{\"title\":\"早餐聊天截图\",...}",
  "keywords": ["早餐", "微信", "买饭", "豆浆", "包子"],
  "date": "2026-06-01",
  "embeddingRef": "gallery-log/embeddings/2026-06-01/gallery_456.json",
  "embeddingStatus": "ok",
  "embeddingDimension": 1024,
  "error": "",
  "latitude": 31.207123,
  "longitude": 121.473701,
  "exif": {
    "dateTimeOriginal": "2026:06:01 08:12:20",
    "deviceMake": "HUAWEI",
    "deviceModel": "HUAWEI Mate 60 Pro",
    "imageWidth": "4096",
    "imageHeight": "3072",
    "orientation": "Top-left",
    "latitude": 31.207123,
    "longitude": 121.473701
  },
  "createdAt": 1780316461000
}
```

字段说明：

- `category` 是稳定分桶字段，当前支持 `聊天`、`文档`、`餐饮`、`购物`、`出行`、`健康`、`工作`、`其他`。
- `summary` 是给 daily-log 文件和列表页展示的短摘要。
- `details` 是具体细节数组，用于记录人物、地点、商户、金额、时间、订单号、聊天事项、待办等可核查信息。
- `date` 是图片归档日期，自动扫描优先使用图库 asset 日期；手动选择图片如果 EXIF 中有 `DateTimeOriginal`，则使用拍摄日期。
- `ocrText` 是鸿蒙本地 OCR 文本；跳过 OCR 时为空。
- `rawModelText` 保留大模型原始返回，便于调试和重新解析。
- `keywords` 来自模型 tags 和 OCR 文本的轻量关键词。
- `embeddingRef` 指向向量文件；如果 embedding 失败或跳过则为空。
- `latitude` / `longitude` 是可用于列表、daily-log 和详情页展示的经纬度。自动扫描优先来自图库 asset 元数据，缺失时由图片 EXIF GPS 字段兜底。
- `exif` 保存从 `ImageSource.getImageProperty()` 读取的图片元数据，当前包含拍摄时间、设备厂商/型号、图片尺寸、方向和 GPS 原始字段/解析坐标。EXIF 读取失败或图片不包含对应字段时可为空。

## Cache Key

采集逻辑在处理图片前计算：

```text
date = 图片归档日期
id = 稳定图片 ID
itemPath = gallery-log/items/<date>/<id>.json
```

如果 `itemPath` 已存在，则认为该图片已经分析过，直接复用 JSON 结果，并跳过：

- 图片解码
- 鸿蒙 OCR
- 云端大模型分析
- embedding
- item / embedding / daily 重写

`id` 需要保持稳定，理想来源优先级是图库 asset id，其次是可稳定复现的 uri / 文件名 / 日期 / size 组合。

## Embedding JSON

向量独立保存在 `gallery-log/embeddings/<date>/<id>.json`。

```json
{
  "id": "gallery_456",
  "uri": "file://media/Photo/12/IMG_0001.jpg",
  "date": "2026-06-01",
  "category": "餐饮",
  "text": "早餐聊天截图\n餐饮\n微信聊天中提到去楼下买豆浆、包子和鸡蛋。\n你帮我买个豆浆...",
  "vector": [0.0123, -0.0456],
  "model": "BAAI/bge-m3",
  "mode": "remote",
  "createdAt": 1780316462000
}
```

规则：

- `text` 是用于 embedding 的拼接文本，包含标题、类别、摘要和 OCR。
- `mode=remote` 表示云端 SiliconFlow/bge-m3。
- `mode=huawei_local` 表示预留的华为端侧 embedding 接口或本地 fallback。
- daily-log 文件不保存向量，避免 markdown 体积膨胀。

## Write Flow

1. 写入 `embeddings/<date>/<id>.json`，得到 `embeddingRef`。
2. 写入 `items/<date>/<id>.json`。
3. 批次结束后收集本批次涉及的日期，从 `items/<date>/*.json` 重建 `daily-log/<date>/<category>.md`。

## Notes

旧的 `gallery/results.json`、`gallery/embeddings.json` 聚合文件以及 `gallery-log/daily` 目录不再作为图库分析的目标格式。新的结构优先支持大量图片、items/embeddings 并发写入、按日期清理，以及后续向量检索。daily-log 是派生视图，损坏或格式升级时可以从 items 重新生成。
