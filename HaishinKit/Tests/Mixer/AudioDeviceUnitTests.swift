import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite("AudioDeviceUnit：釋放") struct AudioDeviceUnitTests {
    @Test("釋放後弱引用為 nil") func release() {
        weak var weakDevice: AudioDeviceUnit?
        _ = {
            guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
                return
            }
            let device = try? AudioDeviceUnit(0, device: audioDevice)
            weakDevice = device
        }()
        #expect(weakDevice == nil)
    }
}
