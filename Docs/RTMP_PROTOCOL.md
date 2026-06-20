# RTMP 通訊協定實作

## 概述

HaishinKit.swift 的 RTMP（Real-Time Messaging Protocol）實作支援 RTMP 與 RTMPS 兩種通訊協定。涵蓋完整的 RTMP 協定堆疊：

- TCP/IP 連線建立
- RTMP Handshake（C0/C1/S0/S1/C2/S2）
- Chunk 分塊機制（類型 0/1/2/3）
- 訊息序列化/反序列化
- 認證處理
- 串流管理

## 協定堆疊

```
┌─────────────────────────────────────┐
│      應用層                          │
│  RTMPCommandMessage, RTMPDataMessage │
├─────────────────────────────────────┤
│      訊息層                          │
│  RTMPChunkMessageHeader              │
├─────────────────────────────────────┤
│      Chunk 分塊層                    │
│  RTMPChunkBuffer                     │
├─────────────────────────────────────┤
│      傳輸層                          │
│  RTMPSocket (NWConnection)           │
└─────────────────────────────────────┘
```

## 核心元件

### RTMPConnection

`RTMPConnection` 是 RTMP 通訊協定的核心類別，負責管理：

- 使用 NWConnection 的 TCP/IP 連線
- RTMP Handshake 程序
- Chunk 緩衝區管理
- 訊息解析與分派
- 透過 RTMPAuthenticator 進行認證
- 透過 NetworkMonitor 進行網路監控

### RTMPHandshake

處理 RTMP Handshake 程序：
1. C0/C1 封包（版本 + 時間戳 + 隨機位元組）
2. S0/S1 封包（版本 + 時間戳 + 隨機位元組）
3. C2 封包（S1 時間戳 + 當前時間 + S1 隨機資料）
4. S2 封包（C1 時間戳 + 當前時間 + C1 隨機資料）

### RTMPChunk

實作 Chunk 分塊機制：
- Chunk 類型：0、1、2、3
- 不同類型對應不同標頭大小
- 訊息長度、時間戳、串流 ID 處理
- 酬載緩衝與解析

### RTMPMessage 類型

支援以下訊息類型：

| 類型 | 說明 |
|------|------|
| 0x01 | 設定 Chunk 大小 |
| 0x02 | 中止訊息 |
| 0x03 | 確認 |
| 0x04 | 使用者控制 |
| 0x05 | 視窗確認大小 |
| 0x06 | 設定同儕頻寬 |
| 0x08 | 音訊訊息 |
| 0x09 | 視訊訊息 |
| 0x0F | AMF3 資料訊息 |
| 0x10 | AMF3 共享物件 |
| 0x11 | AMF3 命令訊息 |
| 0x12 | AMF0 資料訊息 |
| 0x13 | AMF0 共享物件 |
| 0x14 | AMF0 命令訊息 |
| 0x16 | 聚合訊息 |

## 連線流程

### 1. URL 解析

RTMP 連線 URL 解析出：
- 主機與連接埠
- 通訊協定（rtmp/rtmps）
- 從路徑元件解析應用名稱
- 查詢參數

### 2. Handshake 程序

```swift
// 步驟 1：發送 C0+C1 封包
await socket.send(handshake.c0c1packet)

// 步驟 2：接收 S0+S1 封包
for await data in await socket.recv() {
    try await listen(data)
}

// 步驟 3：發送 C2 封包
await socket.send(handshake.c2packet())

// 步驟 4：接收 S2 封包
for await data in await socket.recv() {
    try await listen(data)
}
```

### 3. Connect 命令

connect 命令包含：
- `app`：應用程式名稱（從 URL 路徑解析）
- `flashVer`：Flash 版本字串
- `tcUrl`：不含認證資訊的 URL
- `swfUrl`：SWF URL（如有提供）
- `pageUrl`：HTTP referer URL
- `objectEncoding`：AMF0 編碼
- `capabilities`：連線能力
- `audioCodecs`：支援的音訊編解碼器
- `videoCodecs`：支援的視訊編解碼器

### 4. 建立串流

成功連線後：
1. 透過 `createStream` 命令建立串流
2. 設定 Chunk 大小與視窗確認
3. 使用 `publish` 命令發布串流

## Restream.io 特定考量

Restream.io 通常使用：
- RTMPS 通訊協定（`rtmps://live.restream.io/live/串流金鑰`）
- 串流金鑰作為路徑的最後一部分
- 不需要額外的 URL 認證（直接使用串流金鑰）

### URL 格式範例

```
rtmps://live.restream.io/live/串流金鑰
```

其中：
- 主機：`live.restream.io`
- 連接埠：443（RTMPS 預設）
- 應用名稱：`live`
- 串流名稱：`串流金鑰`

### 潛在問題

1. **App 參數建構**：應用名稱應僅為 "live"，不應包含 "/串流金鑰"
2. **TLS 設定**：確保 restream.io 網域的 TLS 憑證處理正確
3. **連線逾時**：Restream 可能有更嚴格的連線逾時設定

## 疑難排解

### 常見錯誤碼

| 代碼 | 說明 |
|------|------|
| `NetConnection.Connect.Failed` | 連線失敗（網路問題） |
| `NetConnection.Connect.Rejected` | 連線被拒絕（需要認證） |
| `NetStream.Publish.BadName` | 串流名稱無效 |

### 除錯技巧

1. 檢查到 restream.io 的網路連線
2. 驗證串流金鑰格式與有效性
3. 確保 restream.io 網域的 TLS 憑證有效
4. 監控 Handshake 程序日誌
5. 驗證 Chunk 大小與視窗設定

## 設定參數

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `defaultTimeout` | 15 秒 | 連線逾時 |
| `defaultWindowSizeS` | 250000 | 視窗大小 |
| `defaultChunkSizeS` | 8192 | Chunk 大小 |
| `defaultCapabilities` | 239 | 連線能力 |
| `defaultFlashVer` | "FMLE/3.0 (compatible; FMSc/1.0)" | Flash 版本 |

## 程式碼參考

- RTMPConnection.swift：主要連線邏輯
- RTMPHandshake.swift：Handshake 實作
- RTMPChunk.swift：Chunk 分塊機制
- RTMPSocket.swift：網路傳輸
- RTMPAuthenticator.swift：認證處理