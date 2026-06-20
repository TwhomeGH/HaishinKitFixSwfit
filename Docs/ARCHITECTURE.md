# 系統架構

## 概述

HaishinKit.swift 是一套完整的即時串流框架，支援 iOS、macOS、tvOS 與 visionOS。採用模組化設計，將核心串流能力與各通訊協定實作分離。

## 整體架構

```
┌─────────────────────────────────────────────────────────────┐
│                     應用層 (Examples)                        │
│    iOS / macOS / tvOS / visionOS 範例程式                    │
├─────────────────────────────────────────────────────────────┤
│                      Session 層                              │
│    StreamSession (統一介面)                                  │
│    StreamSessionBuilder / Factory 模式                       │
├─────────────────────────────────────────────────────────────┤
│                      通訊協定層                               │
│    ┌───────────┬───────────┬───────────┬──────────────┐     │
│    │ RTMP      │ SRT       │ WebRTC    │ MoQ (QUIC)   │     │
│    │HaishinKit │HaishinKit │HaishinKit │ HaishinKit   │     │
│    └───────────┴───────────┴───────────┴──────────────┘     │
├─────────────────────────────────────────────────────────────┤
│                      核心層 (HaishinKit)                      │
│    MediaMixer │ Codec (VideoToolbox) │ Network │ Stream    │
├─────────────────────────────────────────────────────────────┤
│                      系統框架                                 │
│    AVFoundation │ VideoToolbox │ AudioToolbox │ Network.fw  │
└─────────────────────────────────────────────────────────────┘
```

## 模組依賴關係

```
HaishinKit (核心)
  ├── RTMPHaishinKit → 依賴 HaishinKit
  ├── SRTHaishinKit  → 依賴 HaishinKit
  ├── RTCHaishinKit  → 依賴 HaishinKit
  ├── MoQTHaishinKit → 依賴 HaishinKit
  └── Examples       → 依賴所有模組
```

## 核心資料流

### 發布串流

```
相機/麥克風
    ↓
MediaMixer (混合/處理)
    ↓
VideoToolbox/AudioToolbox (編碼)
    ↓
RTMPStream.append(sampleBuffer)
    ↓
RTMPStream.doOutput() → RTMPConnection.doOutput()
    ↓
RTMPChunkBuffer.putMessage() (分塊)
    ↓
RTMPSocket.send() (NWConnection)
    ↓
網路 → RTMP 伺服器
```

### 播放串流

```
網路 ← RTMP 伺服器
    ↓
RTMPSocket.recv() (NWConnection)
    ↓
RTMPConnection.listen() (解析)
    ↓
RTMPChunkBuffer (重組)
    ↓
RTMPStream.dispatch() (分發)
    ↓
IncomingStream.append() → 播放
```

## 關鍵設計模式

| 模式 | 使用位置 | 說明 |
|------|----------|------|
| Factory | StreamSessionBuilderFactory | 根據 URL scheme 建立對應的 Session |
| Builder | StreamSessionBuilder | 鏈式設定 Session 參數 |
| Actor | RTMPConnection / RTMPStream | Swift actor 保證執行緒安全 |
| AsyncStream | 各層之間 | 非同步資料流傳遞 |
| Weak Delegate | RTMPStream → RTMPConnection | 避免循環引用 |

## 非同步架構

採用 Swift Structured Concurrency：

- **Actor**: `RTMPConnection`、`RTMPStream`、`RTMPSocket` 均為 actor
- **AsyncStream**: 各層透過 AsyncStream 傳遞資料
- **Task**: 使用 Task 進行非同步工作

### 資料流通道

```
RTMPStream (actor)
  outputContinuation (AsyncStream)
    → closure
      → RTMPConnection (actor)
        outputContinuation (AsyncStream)
          → [Data] chunks
            → RTMPSocket (actor)
              outputs (AsyncStream)
                → NWConnection.send()
```

## 程式碼參考

- HaishinKit/Sources/Session/:  Session 管理
- HaishinKit/Sources/Mixer/:   MediaMixer
- HaishinKit/Sources/Codec/:   編解碼器
- HaishinKit/Sources/Network/: 網路層
- HaishinKit/Sources/Stream/:  串流抽象層