import Foundation
import Testing

@testable import RTMPHaishinKit

@Suite struct RTMPAuthenticatorTests {
    @Test func makeSanJoseAuthCommandWithOpaque() throws {
        let url = try #require(URL(string: "rtmp://user:pass@example.com/live/stream"))
        let command = RTMPAuthenticator.makeSanJoseAuthCommand(
            url,
            description: "reason=needauth?salt=salt&opaque=opaque",
            challengeValue: 0x01020304
        )

        #expect(
            command ==
                "rtmp://user:pass@example.com/live/stream&opaque=opaque&challenge=01020304&response=G05rVBawRUivEp7GEROdTg=="
        )
    }

    @Test func makeSanJoseAuthCommandWithServerChallenge() throws {
        let url = try #require(URL(string: "rtmp://user:pass@example.com/live/stream"))
        let command = RTMPAuthenticator.makeSanJoseAuthCommand(
            url,
            description: "reason=needauth?salt=salt&challenge=serverchallenge",
            challengeValue: 0x01020304
        )

        #expect(
            command ==
                "rtmp://user:pass@example.com/live/stream&challenge=01020304&response=WpZlCkxjs1+gPncXPEXwcA=="
        )
    }

    @Test func makeAdobeAuthCommand() throws {
        let status = RTMPStatus(
            code: "NetConnection.Connect.Rejected",
            level: "error",
            description: "authmod=adobe"
        )
        let result = RTMPAuthenticator().makeCommand("rtmp://user:pass@example.com/live/stream", status: status)
        let command = try result.get()

        #expect(command == "rtmp://user:pass@example.com/live/stream?authmod=adobe&user=user")
    }
}
