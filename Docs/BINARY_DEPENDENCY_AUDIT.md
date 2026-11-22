# SRT／WebRTC 二進位依賴盤點

核對日期：2026-11-22（Asia/Taipei）。範圍為 Package.swift 鎖定的發布包與其公開建置腳本、上游發布紀錄及本地呼叫方式；沒有升級套件，沒有完成 Apple 平台連結／執行驗收或完整漏洞掃描。

## 目前引用

| 項目 | libdatachannel | libsrt |
| --- | --- | --- |
| XCFramework 版本 | v0.24.0 | v1.5.4 |
| 發布專案 commit | 679ac6e6b10413f91c9021aa3dcf45b41817909f | d4f3ced379fd5ec2e2717b51342e81c14b139e1b |
| 原始碼 checkout（建置腳本） | paullouisageneau/libdatachannel v0.24.0 | Haivision/srt v1.5.4 |
| 使用模組 | RTCHaishinKit | SRTHaishinKit |
| ZIP bytes | 66,901,500 | 34,090,902 |
| SHA-256 | 52163eed2c9d652d913b20d1fd5a1925c5982b1dcdf335fd916c72ffa385bb26 | 76879e2802e45ce043f52871a0a6764d57f833bdb729f2ba6663f4e31d658c4a |

本次盤點前同日已實際下載兩包到記憶體，SHA-256 與 manifest 相符、ZIP CRC 檢查通過。
兩包 Info.plist 都列 iOS 實機／模擬器、macOS、tvOS、visionOS；libdatachannel 另列 watchOS 及 arm64 Mac Catalyst，libsrt 沒有 Mac Catalyst slice。
這只驗證封裝完整性與平台清單，不代表已驗證其中每個 Mach-O 的符號、最低系統版本或執行行為。
ReplyKit project.pbxproj 目前只引用 HaishinKit／RTMPHaishinKit，未引用 RTC／SRT products；最終 App 是否含相關符號仍需以實際產物驗證。

## 建置與第三方依賴

### libdatachannel v0.24.0

固定版本的 [build-clone.sh](https://github.com/HaishinKit/libdatachannel-xcframework/blob/v0.24.0/build-clone.sh) checkout libdatachannel v0.24.0、krzyzanowskim/OpenSSL 的 3.3.3001 與 ios-cmake 4.5.0，並遞迴取得子模組。
[build-ios.sh](https://github.com/HaishinKit/libdatachannel-xcframework/blob/v0.24.0/build-ios.sh) 使用靜態函式庫、NO_TESTS=YES／NO_EXAMPLES=YES，將 libdatachannel、libsrtp2、usrsctp、libjuice 及 OpenSSL lib/*.a 合併。
NO_TESTS 表示此建置腳本不執行上游測試，不表示上游從未測試。

上游 v0.24.0 tree 的依賴 commit：

| 子模組 | Commit |
| --- | --- |
| libjuice | 5948a4162d37bc213d6051b67ee2876ccc5a99a6 |
| libsrtp | ee1a77c9f9dc02c42bda9901038c500c5efe4cfa |
| usrsctp | fec583d54493f879d2ae44a743423bf8a04371ab |
| plog | 94899e0b926ac1b0f4750bfbd495167b4a6ae9ef |
| json | 55f93686c01528224f448c19128836e7df245f72 |

來源：[上游 tree](https://github.com/paullouisageneau/libdatachannel/tree/v0.24.0/deps)。這是原始碼依賴，不代表每項都各自成為獨立動態庫。OpenSSL 的 3.3.3001 是封裝專案 tag，不能直接當作二進位內 OpenSSL 的完整版本證明。

### libsrt v1.5.4

[build-clone.sh](https://github.com/HaishinKit/libsrt-xcframework/blob/v1.5.4/build-clone.sh) 鎖定 SRT v1.5.4，**OpenSSL 只 clone，沒有 checkout 固定 tag／commit**。
[build-ios.sh](https://github.com/HaishinKit/libsrt-xcframework/blob/v1.5.4/build-ios.sh) 將 libcrypto.a、libssl.a 合併到 libsrt.a。
因此只從該 tag 的腳本無法重現或確定發布包所含 OpenSSL 版本；ZIP 校驗碼不能補上來源版本證據。

兩包都有靜態合併 OpenSSL 的設計，同時連結時需檢查重複符號／版本混用；目前僅是待驗證風險，未實際重現連結衝突。
建置腳本與發布包亦尚未建立可重現建置或產物來源證明，不能斷言發布者完全依腳本生成該 ZIP。

## 上游後續修正：優先核對項目

### SRT：優先處理

- [1.5.5](https://github.com/Haivision/srt/releases/tag/v1.5.5)：包含 startup／cleanup 一致性及可能使 srt_close／srt_cleanup 卡住的鎖順序修正。
- [1.5.6](https://github.com/Haivision/srt/releases/tag/v1.5.6)：官方列出安全更新，包含 KMREQ／KMRSP 長度驗證與 DROPREQ 越界讀取修正。
- [1.5.7](https://github.com/Haivision/srt/releases/tag/v1.5.7)：官方列出加密狀態降級防護、畸形 ACK 驗證及其他安全強化。

所以目前 1.5.4 不應標為「安全性已驗證」。需逐項確認受影響版本、功能開關與可達路徑；本次沒有測試漏洞觸發，也未證明每項問題都存在於這份發布二進位。

### libdatachannel

- [0.24.2](https://github.com/paullouisageneau/libdatachannel/releases/tag/v0.24.2)：RTP／RTCP 封包大小檢查修正。
- [0.24.3](https://github.com/paullouisageneau/libdatachannel/releases/tag/v0.24.3)：REMB／RTCP 長度檢查、closeTracks 重複鎖定、DTLS 啟動競態等修正。
- [0.24.4](https://github.com/paullouisageneau/libdatachannel/releases/tag/v0.24.4)：ICE 接收 callback 的 heap-use-after-free，以及 OpenSSL DTLS／TLS input BIO 同步修正。
- [0.24.6](https://github.com/paullouisageneau/libdatachannel/releases/tag/v0.24.6)：包含 TURN relay 情境的 DTLS 握手死鎖與啟動順序修正。
- [0.24.7](https://github.com/paullouisageneau/libdatachannel/releases/tag/v0.24.7)：包含送出失敗後 pacing queue 狀態修正。

優先核對 OpenSSL／libjuice 路徑；上游另有 MbedTLS 或 libnice 專用修正，不可一律套用到本封裝。後續版本有修正不等於已確認我們遇到同一缺陷；需要比對引入版本與封裝實際配置。

## 本地整合與 CI 邊界

- SRTConnection 每個實例 init 呼叫 srt_startup，deinit 呼叫 srt_cleanup；SRTSocket 有 srt_close 路徑。應測多連線並存、其中一條停止、重連及程序收尾，確認全域函式庫生命週期與 socket 關閉契約。
- RTCPeerConnection／RTCDataChannel／RTCTrack 使用 passUnretained user pointer 與 C callback，並在 deinit 刪除 C 物件。需確認停止 callback、關閉與釋放的先後，不僅升級 C library；本次未判定已存在 UAF。
- swift-tests.yml 目前只指定核心／RTMP suites，TSan 僅覆蓋 OutgoingStreamTests；即使整包建置順帶編譯其他目標，也不等於 RTC／SRT 連線和釋放已驗收。
- 目前「依賴下載成功」「核心測試通過」均不能用作這兩個協議模組正常的證據，也不能把它們直接歸因為 RTMP 推流問題。

## 後續順序與完成條件

1. 優先完成 SRT 安全修正適用性核對，以及兩包 OpenSSL 實際版本／授權來源盤點；取得可信任的版本證據再選升級候選。
2. 對候選版核對平台 slice、最低系統版本、C API、Swift wrapper 及 OpenSSL 連結策略，不能只換 URL／checksum。
3. 分別執行 RTC／SRT 的 macOS、iOS 編譯與連結；再加入連線／傳輸／斷線／反覆重連／多實例釋放測試及對應 sanitizer 檢查。
4. 保留版本、測試平台、建置參數與授權清單；完成 Apple 平台與長時間驗收後才能將可用性項目標為完成。
5. 可選協議拆包屬設計評估；尚未決定實作，不因本次盤點刪除 SRT／RTC 支援。

## 第二輪核對：升級路徑已改變（2026-11-22）

v0.24.6 起，兩個 XCFramework 已從「純 binaryTarget」改為 SwiftPM package，且 **OpenSSL 不再內嵌**：

| 項目 | v0.24.0／v1.5.4（現用） | v0.24.6＋／v1.5.7（升級目標） |
| --- | --- | --- |
| 形式 | `binaryTarget` zip | SwiftPM package（product → source wrapper target） |
| OpenSSL | 靜態合併進 `.a` | 共享 `krzyzanowskim/OpenSSL-Package`（`3.3.3001..<4.0.0`，dynamic） |
| 來源證據 | 無 | `SOURCES.json`（commit、授權、`modified:false`）、`THIRD-PARTY-LICENSES.txt`、`libdatachannel-sources.zip`、`.sha256` |

- **不能只升一個**：官方明文禁止新的 libdatachannel 與仍內嵌 OpenSSL 的舊 libsrt 併用；兩者必須一起遷移。libsrt v1.5.7 同時包含 1.5.6／1.5.7 的安全修正。
- **arm64 不是新限制**：v0.24.0 的建置腳本已是 `MAC_ARM64`、`SIMULATORARM64`、`MAC_CATALYST_ARM64`（再 `lipo -thin arm64`）。v0.24.6+ README 只是把現狀寫明，升級不會失去原本存在的 Intel slice。
- **唯一的平台調升**是 visionOS 1.0 → 1.3；iOS／tvOS 13、macOS 11、Catalyst 14 都低於本專案宣告值。
- 下載大小：v0.24.6 約 19.8 MB、v0.24.7 約 170.6 MB（保留 DWARF；最終 App 不會等比例變大）、libsrt v1.5.7 約 8.2 MB。
- v0.24.7 已知上游 WebSocket URL regex 在 libc++ 的迴歸；本專案不使用 libdatachannel WebSocket（signaling 走自家 `HTTPSession`），不受影響。
- OpenSSL 的**實際解析版本**改由消費端 `Package.resolved` 決定，XCFramework 不再提供；CVE 分診應以 App 的解析結果為準。
- v0.24.7 上游來源 commit `800e849a1ede5667caaf8f6caa1eb21e4906dd87`、zip SHA-256 `524213882b9ca6f08dc6e6af87d0fdda3618b6ced848c2d8c8c36a08f932b851`；libsrt v1.5.7 zip SHA-256 `1761d2c2dcb94014af68417b0ed254dfc5af730df985beb7b681ba202fb5af8d`。
- CI 已新增 `RTCHaishinKit build + tests` 基線（`swift build --target RTCHaishinKit` ＋ iOS 模擬器測試），升級後才有可歸因的回歸訊號。
