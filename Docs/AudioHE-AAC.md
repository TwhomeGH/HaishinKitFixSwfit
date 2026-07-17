# HE-AAC v1/v2 支援已實作完畢

在你的 SampleHandler 中可以這樣用：

```swift
// 自動選擇 device 支援的最佳 AAC 格式（heAacV2 → heAac → aac）
var audioSettings = await mediaMixer.audioMixerSettings
audioSettings.format = AudioCodecSettings.bestAacFormat
await mediaMixer.setAudioMixerSettings(audioSettings)

// Log 會顯示選擇結果
logger.info("audio: format=\(AudioCodecSettings.bestAacFormat.audioDescription)")
```

# RTMP 端用同一 CodecID (10)
 傳送，HE-AAC 的差異 只反應在 AudioSpecificConfig 的 AudioObjectType，server/player 自動判讀。