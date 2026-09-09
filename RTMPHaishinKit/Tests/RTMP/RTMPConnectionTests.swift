import Foundation
import Testing

@testable import RTMPHaishinKit

@Suite struct RTMPConnectionTests {
    @Test func releaseWhenConnectFails() async throws {
        weak var weakConnection: RTMPConnection?

        func connectToUnavailableLocalEndpoint() async {
            let connection = RTMPConnection()
            weakConnection = connection
            do {
                _ = try await connection.connect("rtmp://localhost:19350/live")
                Issue.record("Expected localhost:19350 to be unavailable during unit tests.")
            } catch {
                try? await connection.close()
            }
        }

        await connectToUnavailableLocalEndpoint()
        #expect(weakConnection == nil)
    }
}
