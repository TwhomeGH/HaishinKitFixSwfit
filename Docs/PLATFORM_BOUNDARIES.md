# 多平台邊界設計規範

HaishinKit 的核心套件同時支援 iOS、tvOS、macCatalyst、macOS 與 visionOS。
平台差異若直接散落在 media mixer、codec 或 transport pipeline 中，後續維護會很快變成
`#if` 分支交錯。本文定義後續拆分多平台實作時的規範。

## 目標

- 核心 pipeline 盡量維持平台無關。
- 平台專屬 API 集中在小型 adapter / facade 中。
- 每個平台差異都有可測試的共用介面。
- 避免靠檔名誤以為 SwiftPM 會自動分平台編譯。

## 基本原則

Swift 不會因為檔名包含 `iOS`、`macOS`、`ForIOS` 或 `ForMacOS` 就自動排除檔案。
只要檔案在同一個 target 的 source path 內，它就會被該 target 編譯。因此平台專屬檔案
仍然必須使用頂層 platform guard：

```swift
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
// iOS-family implementation.
#endif
```

```swift
#if os(macOS)
// macOS implementation.
#endif
```

檔名可以用來提升可讀性，但不能當成編譯條件。

## 推薦模式：Protocol + Facade

遇到 `AVAudioSession`、capture device、route change、screen capture、permission、
VideoToolbox option 差異時，優先建立一個小型 protocol 或 facade，讓核心邏輯只依賴共用介面。

共用檔案：

```swift
protocol AudioRouteObserving: AnyObject {
    var isEchoCancellationActive: Bool { get }
    func start()
    func stop()
}
```

iOS-family 實作：

```swift
#if os(iOS) || os(tvOS) || targetEnvironment(macCatalyst)
import AVFoundation

final class PlatformAudioRouteObserver: AudioRouteObserving {
    var isEchoCancellationActive: Bool {
        AVAudioSession.sharedInstance().inputDataSources?.isEmpty == false
    }

    func start() {
        // Observe AVAudioSession route changes.
    }

    func stop() {
        // Remove observer.
    }
}
#endif
```

macOS 實作：

```swift
#if os(macOS)
final class PlatformAudioRouteObserver: AudioRouteObserving {
    var isEchoCancellationActive: Bool {
        true
    }

    func start() {
    }

    func stop() {
    }
}
#endif
```

核心使用端：

```swift
final class AudioMixerByMultiTrack {
    private let routeObserver: AudioRouteObserving

    init(routeObserver: AudioRouteObserving = PlatformAudioRouteObserver()) {
        self.routeObserver = routeObserver
    }
}
```

這樣 `AudioMixerByMultiTrack` 不需要知道 `AVAudioSession` 是否存在，也不需要在核心流程中穿插
平台分支。

## 檔案命名

平台邊界檔案使用下列命名：

- `FeatureName.swift`：平台無關 protocol、facade 或共用 model。
- `FeatureName_iOS.swift`：iOS / tvOS / macCatalyst 實作。
- `FeatureName_macOS.swift`：macOS 實作。
- `FeatureName_visionOS.swift`：visionOS 有獨立差異時才新增。

不要使用含糊名稱，例如 `FeatureName_Apple.swift`，除非檔案真的能在所有 Apple 平台共用。
新平台分檔優先使用 `_` 而不是 `+`，避免 shell、URL、artifact 或外部工具對 `+` 有特殊處理時產生讀取問題。

## `#if` 放置位置

優先順序：

1. 放在平台專屬檔案頂層。
2. 放在小型 adapter / facade 內。
3. 放在核心流程中的單一窄範圍分支。

避免：

- 在同一個 method 內多次交錯 `#if`。
- 在 hot path 中散落平台分支。
- 為了單一平台 API 讓核心型別暴露平台專屬型別。

## Target 拆分時機

不要一開始就把套件拆成多個 SwiftPM targets。只有符合以下情況時才考慮：

- 平台專屬依賴無法透過頂層 `#if` 隔離。
- 某平台需要完全不同的 public API surface。
- 編譯時間或 binary size 已經因平台混編產生明確成本。
- 測試 target 必須完全分離才能穩定。

若要拆 target，建議先形成：

- `HaishinKitCore`：平台無關資料結構、時間軸、buffer、format。
- `HaishinKitAppleMedia`：AVFoundation / CoreMedia / VideoToolbox adapter。
- `HaishinKit`：對外 product，組合 core 與平台實作。

這是大規模重構，需另開設計文件與遷移計畫。

## 測試規範

新增平台 facade 時需補兩層測試：

- 共用 protocol 行為測試：使用 fake implementation，不依賴硬體或 simulator 裝置。
- 平台 smoke test：只確認平台實作可建立、可釋放，且在缺少硬體時能安全跳過。

CI 中至少保持：

- `HaishinKitTests` iOS Simulator job。
- `HaishinKitTests` macOS job。
- transport package tests 與核心 tests 分 job 彙總。

需要真 camera、microphone、RTMP server、SRT server 或 WebRTC peer 的測試，應放入
integration workflow，不應混入必跑 unit workflow。

## 遷移步驟

既有檔案若已經有大量平台分支，按以下順序拆：

1. 找出直接引用平台專屬 API 的最小功能。
2. 定義平台無關 protocol，名稱描述能力，不描述平台。
3. 建立 `_iOS.swift`、`_macOS.swift` 等平台實作檔。
4. 核心型別改成依賴 protocol 或 facade。
5. 補 fake-based unit tests。
6. 將原本散落的 `#if` 從核心流程移除或縮到單一建構點。

每次遷移只處理一個邊界，例如 audio route、capture device、screen capture 或 VT options。
不要在同一個 PR 同時重排整個 media pipeline。

## 目前已套用的邊界

- `AudioEchoRouteObserving`：隔離 AEC 是否需要啟用的音訊路由判斷。
- `PlatformAudioEchoRouteObserver_iOS.swift`：使用 `AVAudioSession.routeChangeNotification`
  與目前輸出路由判斷耳機、聽筒、藍牙或喇叭路徑。
- `PlatformAudioEchoRouteObserver_Default.swift`：macOS / visionOS 等沒有同一路由 API
  的平台保守回報有 echo path，讓 AEC 保持可用且不註冊 route observer。
- `AudioMixerByMultiTrack`：只依賴 `AudioEchoRouteObserving`，不直接引用
  `AVAudioSession` route API。
