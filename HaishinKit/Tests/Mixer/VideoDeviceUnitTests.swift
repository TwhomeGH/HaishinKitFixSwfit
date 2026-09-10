import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite("VideoDeviceUnit：釋放") struct VideoDeviceUnitTests {
    @Test("釋放後弱引用為 nil") func release() {
        weak var weakDevice: VideoDeviceUnit?
        _ = {
            guard let videoDevice = AVCaptureDevice.default(for: .video) else {
                return
            }
            let device = try? VideoDeviceUnit(0, device: videoDevice)
            weakDevice = device
        }()
        #expect(weakDevice == nil)
    }
}
