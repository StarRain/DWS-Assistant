import XCTest
@testable import DashboardCore

final class SetupCheckTests: XCTestCase {
    private func check(_ json: String) throws -> DWSAccountCheck {
        try DWSAccountCheck(CommandResult(status: 0, stdout: json, stderr: ""))
    }

    func testRenewableLoginRemainsAuthorizedAndMissingIdentityDoesNotPass() throws {
        let value = try check(#"{"success":true,"authenticated":true,"token_valid":false,"refresh_token_valid":true,"corp_id":"corp","user_id":"user","user_name":"测试"}"#)
        XCTAssertEqual(value.state, .authorized)
        XCTAssertEqual(value.profile?.id, "corp:user")
        XCTAssertTrue(value.detail.contains("续期"))
        let incomplete = try check(#"{"authenticated":true,"corp_id":"corp"}"#)
        XCTAssertEqual(incomplete.state, .indeterminate)
        XCTAssertNil(incomplete.profile)
    }

    func testUnreadableOrRepairRequiredSnapshotIsNeverShownAsLogout() throws {
        for reason in ["local_state_requires_repair", "local_state_unreadable", "dek_missing", "keychain_unavailable", "future_diagnostic"] {
            let value = try check("{\"authenticated\":false,\"reason\":\"\(reason)\"}")
            XCTAssertEqual(value.state, .indeterminate)
            XCTAssertNil(value.profile)
        }
        XCTAssertEqual(try check(#"{"authenticated":false}"#).state, .signedOut)
        XCTAssertThrowsError(try check(#"{"success":true}"#))
        XCTAssertThrowsError(try check(#"{"success":false,"authenticated":true,"corp_id":"corp","user_id":"user"}"#))
    }

    func testSetupMigrationRespectsExistingWorkspacesAndExplicitChoice() throws {
        var c = Conversation(); c.stableID = "cid-test"; c.profile = "corp:user"
        var config = DashboardConfig(); config.conversations = [c]
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as! [String: Any]
        legacy.removeValue(forKey: "setupCompleted")
        XCTAssertTrue(try JSONDecoder().decode(DashboardConfig.self, from: JSONSerialization.data(withJSONObject: legacy)).setupCompleted)
        legacy["conversations"] = []
        XCTAssertFalse(try JSONDecoder().decode(DashboardConfig.self, from: JSONSerialization.data(withJSONObject: legacy)).setupCompleted)
        XCTAssertFalse(try JSONDecoder().decode(DashboardConfig.self, from: JSONEncoder().encode(config)).setupCompleted)
        config.setupCompleted = true
        XCTAssertTrue(try JSONDecoder().decode(DashboardConfig.self, from: JSONEncoder().encode(config)).setupCompleted)
    }
}
