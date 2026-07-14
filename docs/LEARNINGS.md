# Learnings

Gotchas worth remembering, captured as they surface. Newest first.

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
