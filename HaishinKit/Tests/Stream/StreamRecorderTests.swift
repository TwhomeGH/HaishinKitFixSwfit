import Foundation
import Testing

@testable import HaishinKit

@Suite("StreamRecorder：開始錄影路徑") struct StreamRecorderTests {
    @Test("nil 路徑：使用預設檔名") func startRunning_nil() async throws {
        let recorder = StreamRecorder()
        try await recorder.startRecording(nil)
        let moviesDirectory = await recorder.moviesDirectory
        // $moviesDirectory/B644F60F-0959-4F54-9D14-7F9949E02AD8.mp4
        #expect(((await recorder.outputURL?.path.contains(moviesDirectory.path)) != nil))
    }

    @Test("相對檔名：置於影片目錄") func startRunning_fileName() async throws {
        let recorder = StreamRecorder()
        try? await recorder.startRecording(URL(string: "dir/sample.mp4"))
        _ = await recorder.moviesDirectory
        // $moviesDirectory/dir/sample.mp4
        #expect(((await recorder.outputURL?.path.contains("dir/sample.mp4")) != nil))
    }

    @Test("完整路徑：直接使用") func startRunning_fullPath() async {
        let recorder = StreamRecorder()
        let fullPath = await recorder.moviesDirectory.appendingPathComponent("sample.mp4")
        // $moviesDirectory/sample.mp4
        try? await recorder.startRecording(fullPath)
        #expect(await recorder.outputURL == fullPath)
    }

    @Test("目錄路徑：產生檔名") func startRunning_dir() async {
        let recorder = StreamRecorder()
        try? await recorder.startRecording(URL(string: "dir"))
        // $moviesDirectory/dir/33FA7D32-E0A8-4E2C-9980-B54B60654044.mp4
        #expect(((await recorder.outputURL?.path.contains("dir")) != nil))
    }

    @Test("檔案已存在：拋出錯誤") func startRunning_fileAlreadyExists() async {
        let recorder = StreamRecorder()
        let filePath = await recorder.moviesDirectory.appendingPathComponent("duplicate-file.mp4")
        do {
            try FileManager.default.createDirectory(
                at: filePath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = FileManager.default.createFile(atPath: filePath.path, contents: nil)
            await #expect(throws: StreamRecorder.Error.self) {
                try await recorder.startRecording(filePath)
            }
        } catch {
            Issue.record(error)
        }
        try? FileManager.default.removeItem(at: filePath)
    }
}
