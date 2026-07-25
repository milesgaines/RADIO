import XCTest
@testable import RadioKit

/// Pins the credential-storage contract: the Navidrome password comes from a
/// `SecretStore` (the keychain in the app), never from `UserDefaults`, and a
/// plain-text password left behind by an older build gets moved across once.
final class NavidromeCredentialsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suite = "com.radioplus.tests.navidrome"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    private func writeServerDetails(host: String = "https://music.example.com", user: String = "dj") {
        defaults.set(host, forKey: NavidromeConfig.StorageKey.baseURL)
        defaults.set(user, forKey: NavidromeConfig.StorageKey.username)
    }

    // MARK: - Reading

    func testConfigTakesPasswordFromTheSecretStore() {
        writeServerDetails()
        let secrets = InMemorySecretStore([NavidromeConfig.SecretKey.password: "s3cret"])

        let config = NavidromeConfig.fromDefaults(defaults, secrets: secrets)

        XCTAssertEqual(config?.username, "dj")
        XCTAssertEqual(config?.baseURL.absoluteString, "https://music.example.com")
        XCTAssertEqual(config?.password, "s3cret")
    }

    func testConfigIsNilWhenTheSecretStoreHasNoPassword() {
        writeServerDetails()
        // A plain-text password in UserDefaults must not satisfy the config —
        // that's exactly the storage we moved away from.
        defaults.set("s3cret", forKey: NavidromeConfig.StorageKey.legacyPassword)

        XCTAssertNil(NavidromeConfig.fromDefaults(defaults, secrets: InMemorySecretStore()))
    }

    func testConfigIsNilWhenServerDetailsAreMissing() {
        let secrets = InMemorySecretStore([NavidromeConfig.SecretKey.password: "s3cret"])
        XCTAssertNil(NavidromeConfig.fromDefaults(defaults, secrets: secrets))
    }

    // MARK: - Writing

    func testSavingAPasswordNeverTouchesUserDefaults() throws {
        let secrets = InMemorySecretStore()
        let config = NavidromeConfig(
            baseURL: URL(string: "https://music.example.com")!,
            username: "dj",
            password: "s3cret"
        )

        try config.savePassword(to: secrets)

        XCTAssertEqual(secrets.secret(forKey: NavidromeConfig.SecretKey.password), "s3cret")
        XCTAssertNil(defaults.string(forKey: NavidromeConfig.StorageKey.legacyPassword))
    }

    func testForgettingThePasswordClearsTheSecretStore() throws {
        let secrets = InMemorySecretStore([NavidromeConfig.SecretKey.password: "s3cret"])

        try NavidromeConfig.forgetPassword(secrets)

        XCTAssertNil(secrets.secret(forKey: NavidromeConfig.SecretKey.password))
    }

    // MARK: - Migration off UserDefaults

    func testLegacyPlainTextPasswordIsMovedIntoTheSecretStore() {
        writeServerDetails()
        defaults.set("s3cret", forKey: NavidromeConfig.StorageKey.legacyPassword)
        let secrets = InMemorySecretStore()

        XCTAssertTrue(NavidromeConfig.migrateLegacyPassword(defaults, secrets: secrets))

        XCTAssertEqual(secrets.secret(forKey: NavidromeConfig.SecretKey.password), "s3cret")
        XCTAssertNil(
            defaults.string(forKey: NavidromeConfig.StorageKey.legacyPassword),
            "The plain-text copy must be deleted once the keychain has it"
        )
        // The listener stays connected across the upgrade.
        XCTAssertEqual(NavidromeConfig.fromDefaults(defaults, secrets: secrets)?.password, "s3cret")
    }

    func testMigrationIsANoOpWithNothingInPlainText() {
        writeServerDetails()
        let secrets = InMemorySecretStore([NavidromeConfig.SecretKey.password: "s3cret"])

        XCTAssertFalse(NavidromeConfig.migrateLegacyPassword(defaults, secrets: secrets))

        XCTAssertEqual(secrets.secret(forKey: NavidromeConfig.SecretKey.password), "s3cret")
    }

    func testMigrationDropsAStaleCopyWithoutOverwritingTheKeychain() {
        writeServerDetails()
        defaults.set("old-password", forKey: NavidromeConfig.StorageKey.legacyPassword)
        let secrets = InMemorySecretStore([NavidromeConfig.SecretKey.password: "current-password"])

        XCTAssertFalse(NavidromeConfig.migrateLegacyPassword(defaults, secrets: secrets))

        XCTAssertEqual(
            secrets.secret(forKey: NavidromeConfig.SecretKey.password),
            "current-password",
            "The keychain is authoritative — a stale plain-text copy must not clobber it"
        )
        XCTAssertNil(defaults.string(forKey: NavidromeConfig.StorageKey.legacyPassword))
    }

    func testMigrationIsIdempotent() {
        writeServerDetails()
        defaults.set("s3cret", forKey: NavidromeConfig.StorageKey.legacyPassword)
        let secrets = InMemorySecretStore()

        XCTAssertTrue(NavidromeConfig.migrateLegacyPassword(defaults, secrets: secrets))
        XCTAssertFalse(NavidromeConfig.migrateLegacyPassword(defaults, secrets: secrets))
        XCTAssertEqual(secrets.secret(forKey: NavidromeConfig.SecretKey.password), "s3cret")
    }
}
