"""離線執行 RTMP 恢復核心測試，不需要 Apple SDK 或下載套件。

只複製實際的佇列／編碼輸出狀態原始檔及測試，沒有替換狀態機的測試替身。
這不取代 macOS/iOS 的整個套件編譯、VideoToolbox 或網路整合測試。
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
files = {
    "HaishinKit/Sources/Codec/VideoEncoderOutputState.swift": "Sources/HaishinKit",
    "RTMPHaishinKit/Sources/RTMP/RTMPOutputQueue.swift": "Sources/RTMPHaishinKit",
    "HaishinKit/Tests/Codec/VideoEncoderOutputStateTests.swift": "Tests/HaishinKitTests",
    "RTMPHaishinKit/Tests/RTMP/RTMPOutputQueueTests.swift": "Tests/RTMPHaishinKitTests",
}
with tempfile.TemporaryDirectory(prefix="haishin-rtmp-recovery-") as directory:
    root = Path(directory)
    (root / "Package.swift").write_text("""// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "RecoveryValidation", targets: [
    .target(name: "HaishinKit"),
    .target(name: "RTMPHaishinKit"),
    .testTarget(name: "HaishinKitTests", dependencies: ["HaishinKit"]),
    .testTarget(name: "RTMPHaishinKitTests", dependencies: ["RTMPHaishinKit"])
])
""", encoding="utf-8")
    for source, target in files.items():
        output = root / target / Path(source).name
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(repo / source, output)
    result = subprocess.run(["swift", "test", "--package-path", str(root)], check=False)
    raise SystemExit(result.returncode)
