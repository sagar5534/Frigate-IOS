# Learnings

Gotchas worth remembering, captured as they surface. Newest first.

## The login request must be exempt from the 401 retry seam

`FrigateClient` re-authenticates on a `401` by calling the credential provider, which re-runs
`/api/login`. If `login` is itself allowed to trigger that path, a wrong stored password recurses
forever: `login` 401 -> reauthenticate -> `login` 401 -> ... The fix is a single guard in the
client (`endpoint.path != "login"`). This never surfaced in C1 because login tests ran with no
credential provider; it only bites once a real provider (C5) is attached. Any future
auth/token-exchange endpoint added to the retry-eligible surface needs the same exemption.

## AppModel persistence pollutes real storage in tests unless stores are injected

`AppModel`'s production defaults are the real Keychain (`KeychainCredentialStore()`) and the
App-Group `UserDefaults` suite (`ServerConfigStore()`). Any test that drives `connect`/`submitLogin`
will write to them for real. Tests must inject an in-memory credential store and a temp-suite
`ServerConfigStore` (see `makeTestAppModel`); `ServerConfigStore(defaults:)` + a UUID suite name,
cleaned up with `removePersistentDomain(forName:)`, keeps it hermetic.

## App Group as a Keychain access group is NOT team-prefixed

iOS prefixes ordinary `keychain-access-groups` entries with the team id (`$(AppIdentifierPrefix)`),
but an **App Group id used as a keychain access group is the exception - it is used verbatim**. So
the entitlement entry and the runtime `kSecAttrAccessGroup` are both just `group.com.sagarp.Frigate`
(no `LL6476HKHT.` prefix). This is why C4 deviates from the plan's `$(AppIdentifierPrefix)group...`
sketch. Confirmed on the iPhone 17 simulator: the app signs with the entitlement and a real
`SecItem` save/read/clear against the shared group passes. Hosted unit tests inherit the host app's
entitlement, so they can exercise the shared access group directly (no separate entitlement on the
test target).

## `MockURLProtocol.requestHandler` runs off the main actor

The handler closure is `@Sendable` and invoked on a background queue. In a `@MainActor` test class,
any helper it calls (e.g. a `HTTPURLResponse` factory) must be marked `nonisolated`, or the build
fails with "call to main actor-isolated instance method in a synchronous nonisolated context."
Precompute main-actor values (like response `Data`) before setting the handler, and keep the
closure body limited to nonisolated work.

## Adding a unit-test target to a file-system-synchronized Xcode project (objectVersion 77)

The project uses `PBXFileSystemSynchronizedRootGroup`, so source files under `app/Frigate/` are
auto-discovered - no `project.pbxproj` entry per file. The `FrigateTests` target reuses the same
mechanism: a `PBXFileSystemSynchronizedRootGroup` at `app/FrigateTests/` listed in the target's
`fileSystemSynchronizedGroups` means new `.swift` test files are picked up automatically (build
phases stay empty; Xcode assigns by file type). Wiring a test target by hand still needs the
usual objects: native target (`com.apple.product-type.bundle.unit-test`), product `.xctest`
file ref, `TEST_HOST`/`BUNDLE_LOADER` pointing at the app, a `PBXTargetDependency` +
`PBXContainerItemProxy` on the app, `TestTargetID` in `TargetAttributes`, config list + Debug/
Release configs, and a `<Testables>` entry in the shared scheme's `TestAction`.

## `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (project default)

The app target defaults every non-actor type to `@MainActor`. `URLSessionDelegate` and
`URLProtocol` subclasses are called off the main actor, so mark them `nonisolated` (e.g.
`InsecureTrustDelegate`, and the test `MockURLProtocol`) or the overrides won't match their
`nonisolated` superclass declarations. `actor FrigateClient` defines its own isolation domain and
is unaffected. The test target omits this setting, so its `URLProtocol` subclass compiles cleanly.

The same default bites the networking/model layer that `actor FrigateClient` consumes: a value
type left at the default `@MainActor` gets a main-actor-isolated `Codable`/`Equatable` conformance
and main-actor-isolated static methods, which the actor can't touch ("Main actor-isolated
conformance ... cannot be used in actor-isolated context", "... static method 'login' cannot be
called from outside of the actor"). Fix is to mark the off-main-actor types `nonisolated`
(`Endpoint`, `FrigateConfig`, `LoginRequest`, `HTTPMethod`, `APIError`, `CredentialProviding`,
`CredentialStoring`, `CredentialAccount`, `KeychainCredentialProvider`) rather than disabling the
project-wide default (UI code still wants MainActor-by-default). **Gotcha:** `nonisolated` on the
primary type declaration does not cover members declared in an `extension` - the extension inherits
the MainActor default independently, so `Endpoint`'s static builders needed `nonisolated extension
Endpoint { ... }` too.
