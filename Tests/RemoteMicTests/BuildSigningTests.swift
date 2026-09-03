import Foundation
import Testing

@Suite("Build signing")
struct BuildSigningTests {
    @Test func buildDefaultsToStableAdHocSigning() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )

        #expect(source.contains("CODE_SIGN_IDENTITY"))
        #expect(source.contains("SIGNING_IDENTITY=\"${CODE_SIGN_IDENTITY:--}\""))
        #expect(source.contains("if [[ \"$SIGNING_IDENTITY\" == \"-\" ]]; then"))
        #expect(source.contains("designated => identifier"))
        #expect(source.contains("XPCServices/Installer.xpc"))
        #expect(source.contains("XPCServices/Downloader.xpc"))
        #expect(source.contains("--preserve-metadata=entitlements"))
        #expect(source.contains("$SPARKLE_VERSION_DIR/Autoupdate"))
        #expect(source.contains("$SPARKLE_VERSION_DIR/Updater.app"))
        #expect(source.contains("find \"$APP_DIR\" -type f -exec chmod 644 {} +"))
        #expect(source.contains("Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"))
        #expect(!source.contains("security find-identity -p codesigning -v"))
        #expect(!source.contains("git config --get user.email"))
        let signingSource = try #require(source.components(separatedBy: "codesign --verify --deep").first)
        #expect(!signingSource.contains("--deep"))
        let adHocSigningSource = try #require(
            signingSource.components(
                separatedBy: "if [[ \"$SIGNING_IDENTITY\" == \"-\" ]]; then"
            ).last
        )
        #expect(!adHocSigningSource.contains("--options runtime"))
        #expect(source.contains("MiRemoteV2ch.driver"))
        #expect(source.contains("$OUTPUT_DIR/MiRemoteV2ch.driver"))
    }

    @Test func releaseBuildsDriverBeforeEmbeddingItInTheApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dmgSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-dmg.sh"),
            encoding: .utf8
        )
        let notarizeSource = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-release.sh"),
            encoding: .utf8
        )
        let dmgDriver = try #require(dmgSource.range(of: "build-doubao-driver.sh"))
        let dmgApp = try #require(dmgSource.range(of: "build-app.sh"))
        let notarizeDriver = try #require(notarizeSource.range(of: "build-doubao-driver.sh"))
        let notarizeApp = try #require(notarizeSource.range(of: "build-app.sh"))
        #expect(dmgDriver.lowerBound < dmgApp.lowerBound)
        #expect(notarizeDriver.lowerBound < notarizeApp.lowerBound)
    }

    @Test func productionReleaseDoesNotRequirePrivateFeaturePackage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-app.sh"),
            encoding: .utf8
        )
        let notarizeSource = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-release.sh"),
            encoding: .utf8
        )
        let verifySource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-app.sh"),
            encoding: .utf8
        )

        #expect(!buildSource.contains("SAYALL_AI_PACKAGE_PATH"))
        #expect(!buildSource.contains("A SayAllAI package is required for this build"))
        #expect(!buildSource.contains("SayAllAI_SayAllAI.bundle"))
        #expect(!buildSource.contains("SayAllAIIncluded"))
        #expect(buildSource.contains("DEFAULT_SCRATCH_PATH=\"/private/tmp/remote-mic-swiftpm/"))
        #expect(!buildSource.contains("DEFAULT_SCRATCH_PATH=\"$ROOT/.build-app-sayall-ai\""))
        #expect(!notarizeSource.contains("REQUIRE_SAYALL_AI_PACKAGE"))
        #expect(!verifySource.contains("SayAllAI"))
    }

    @Test func installerSigningUsesTheReleaseKeychainAndHasATimeout() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("scripts/build-doubao-driver-pkg.sh"),
            encoding: .utf8
        )

        #expect(source.contains("INSTALLER_SIGNING_KEYCHAIN=\"${INSTALLER_SIGNING_KEYCHAIN:-${NOTARY_KEYCHAIN:-}}\""))
        #expect(source.contains("PRODUCTSIGN_TIMEOUT_SECONDS=\"${PRODUCTSIGN_TIMEOUT_SECONDS:-900}\""))
        #expect(source.contains("productsign --sign \"$INSTALLER_SIGNING_IDENTITY\""))
        #expect(source.contains("\"${PRODUCTSIGN_KEYCHAIN_ARGS[@]}\""))
        #expect(source.contains("productsign timed out after"))
        #expect(source.contains("sign_product \"$UNSIGNED_INSTALL_PACKAGE\" \"$INSTALL_PACKAGE\""))
        #expect(source.contains("sign_product \"$UNSIGNED_UNINSTALL_PACKAGE\" \"$UNINSTALL_PACKAGE\""))
    }

    @Test func clientUsesOnlyTheStableUpdateFeed() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )

        #expect(source.contains("func feedURLString() -> String?"))
        #expect(!source.contains("preReleaseFeed"))
        #expect(!source.contains("latestReleaseFeedURL"))
    }

    @Test func fastReleaseKeepsMandatorySafetyGates() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fastReleaseSource = try String(
            contentsOf: root.appendingPathComponent("scripts/fast-release.sh"),
            encoding: .utf8
        )
        let notarizeSource = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-release.sh"),
            encoding: .utf8
        )
        let publishSource = try String(
            contentsOf: root.appendingPathComponent("scripts/publish-release.sh"),
            encoding: .utf8
        )
        let releaseVariantsSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/package-macos-release-variants.sh"
            ),
            encoding: .utf8
        )
        let previewVerifierSource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-preview-branch.sh"),
            encoding: .utf8
        )

        #expect(fastReleaseSource.contains("fast release requires a clean committed worktree"))
        #expect(fastReleaseSource.contains("fast release requires release/pre-v$VERSION"))
        #expect(fastReleaseSource.contains("verify-preview-branch.sh"))
        #expect(fastReleaseSource.contains("fast release rejected non-document/resource change"))
        #expect(fastReleaseSource.contains("fast release rejected a possible plaintext credential"))
        #expect(fastReleaseSource.contains("fast release requires a $VERSION entry"))
        #expect(fastReleaseSource.contains("xcrun swift test"))
        #expect(fastReleaseSource.contains("validate-notary-secrets-repo.sh"))
        #expect(fastReleaseSource.contains("ALLOW_ISOLATED_RELEASE_KEYCHAIN=1"))
        #expect(fastReleaseSource.contains("PARALLEL_PACKAGE_NOTARIZATION=1"))
        #expect(fastReleaseSource.contains("package-macos-release-variants.sh"))
        #expect(fastReleaseSource.contains("publish-release.sh\" prerelease"))
        #expect(!fastReleaseSource.contains("git push origin main"))
        #expect(notarizeSource.contains("wait \"$install_notary_pid\""))
        #expect(notarizeSource.contains("wait \"$uninstall_notary_pid\""))
        #expect(publishSource.contains("usage: $0 prerelease|auto|promote"))
        #expect(publishSource.contains(".candidateBranch == $candidateBranch"))
        #expect(publishSource.contains("stable promotion is restricted to main"))
        #expect(publishSource.contains("candidate-provenance.json"))
        #expect(publishSource.contains("schemaVersion: 2"))
        #expect(publishSource.contains("baseMainCommit"))
        #expect(publishSource.contains("stable-promotion.json"))
        #expect(publishSource.contains("CONFIGURED_DOWNLOAD_PREFIX=\"${RELEASE_DOWNLOAD_PREFIX:-}\""))
        #expect(publishSource.contains("CDN_DOWNLOAD_PREFIX=\"$GITHUB_DOWNLOAD_PREFIX\""))
        #expect(publishSource.contains("if (( USE_EXTERNAL_DOWNLOAD_PREFIX == 1 )); then"))
        #expect(publishSource.contains("verify_cdn_assets"))
        #expect(publishSource.contains("gh workflow run release-guard.yml"))
        #expect(previewVerifierSource.contains("release/pre-vX.Y.Z"))
        #expect(previewVerifierSource.contains("preview candidate contains a non-release change"))
        #expect(previewVerifierSource.contains("git rev-parse HEAD^"))
        #expect(previewVerifierSource.contains("must exactly equal the latest origin/main"))
        #expect(previewVerifierSource.contains("must contain exactly one release metadata commit"))
        #expect(previewVerifierSource.contains("BASE_MAIN_COMMIT:"))
        #expect(releaseVariantsSource.contains("RELEASE_VARIANT=apple-silicon"))
        #expect(releaseVariantsSource.contains("RELEASE_VARIANT=intel"))
        let candidateIndex = try #require(publishSource.range(of: "gh release create"))
        let promotionIndex = try #require(publishSource.range(of: "gh release edit"))
        #expect(candidateIndex.lowerBound < promotionIndex.lowerBound)
    }

    @Test func previewBranchPushBuildsACandidateWithoutReleaseSecrets() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflowSource = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-preview-candidate.yml"),
            encoding: .utf8
        )

        #expect(workflowSource.contains("release/pre-v*"))
        #expect(workflowSource.contains("./scripts/verify-preview-branch.sh"))
        #expect(workflowSource.contains("swift test"))
        #expect(workflowSource.contains("./scripts/test.sh"))
        #expect(workflowSource.contains("./scripts/build-dmg.sh"))
        #expect(workflowSource.contains("./scripts/verify-dmg.sh"))
        #expect(!workflowSource.contains("GetSayAll/sayall-ai"))
        #expect(!workflowSource.contains("REQUIRE_SAYALL_AI_PACKAGE=1"))
        #expect(workflowSource.contains("actions/upload-artifact@v4"))
        #expect(workflowSource.contains("contents: read"))
        #expect(!workflowSource.contains("MATCH_PASSWORD"))
        #expect(!workflowSource.contains("AuthKey_"))

        let ciWorkflowSource = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-ci.yml"),
            encoding: .utf8
        )
        #expect(ciWorkflowSource.contains("workflow_dispatch:"))
    }

    @Test func previewBranchLifecycleHasExecutableRegressionCoverage() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let lifecycleScript = root.appendingPathComponent(
            "scripts/test-preview-branch-lifecycle.sh"
        )
        let lifecycleSource = try String(
            contentsOf: lifecycleScript,
            encoding: .utf8
        )

        #expect(lifecycleSource.contains("release/pre-v1.8.15"))
        #expect(lifecycleSource.contains("release/pre-v1.8.16"))
        #expect(lifecycleSource.contains("PREVIEW BRANCH PASS"))
        #expect(lifecycleSource.contains("must exactly equal the latest origin/main"))
        #expect(lifecycleSource.contains("PREVIEW BRANCH LIFECYCLE TEST PASS"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [lifecycleScript.path]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(
            process.terminationStatus == 0,
            "preview lifecycle output:\n\(output)\nerror:\n\(error)"
        )
    }

    @Test func intelVenturaReleaseLineStaysIsolatedFromAppleSilicon() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let variantSource = try String(
            contentsOf: root.appendingPathComponent("scripts/release-variant.sh"),
            encoding: .utf8
        )
        let workflowSource = try String(
            contentsOf: root.appendingPathComponent(
                ".github/workflows/mac-ci.yml"
            ),
            encoding: .utf8
        )
        let preinstallSource = try String(
            contentsOf: root.appendingPathComponent(
                "packaging/doubao-driver/install/preinstall"
            ),
            encoding: .utf8
        )
        let packageVerifierSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/verify-doubao-driver-pkg.sh"
            ),
            encoding: .utf8
        )

        #expect(variantSource.contains("RELEASE_VARIANT=\"${RELEASE_VARIANT:-apple-silicon}\""))
        #expect(variantSource.contains("arm64-apple-macosx14.0"))
        #expect(variantSource.contains("x86_64-apple-macosx13.0"))
        #expect(variantSource.contains("RELEASE_OUTPUT_DIR=\"$ROOT/dist/intel\""))
        #expect(variantSource.contains("RELEASE_APPCAST_NAME=\"appcast-intel.xml\""))
        #expect(variantSource.contains("RELEASE_ASSET_SUFFIX=\"-AppleSilicon\""))
        #expect(variantSource.contains("RELEASE_ASSET_SUFFIX=\"-Intel\""))

        #expect(workflowSource.contains("RELEASE_VARIANT: ${{ matrix.variant }}"))
        #expect(workflowSource.contains("x86_64-apple-macosx13.0"))
        #expect(workflowSource.contains("apple-silicon"))
        #expect(workflowSource.contains("intel"))

        let architectureCheck = try #require(
            preinstallSource.range(of: "CURRENT_ARCHITECTURE")
        )
        let existingAppRemoval = try #require(
            preinstallSource.range(of: "/bin/rm -rf -- \"$APP_DESTINATION\"")
        )
        #expect(architectureCheck.lowerBound < existingAppRemoval.lowerBound)
        #expect(packageVerifierSource.contains(
            "package scripts must not require Xcode or Command Line Tools"
        ))
    }

    @Test func ordinaryDmgHasOneInstallerAndKeepsHealthyDriver() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dmgSource = try String(
            contentsOf: root.appendingPathComponent("scripts/build-dmg.sh"),
            encoding: .utf8
        )
        let postinstallSource = try String(
            contentsOf: root.appendingPathComponent(
                "packaging/doubao-driver/install/postinstall"
            ),
            encoding: .utf8
        )
        let verifierSource = try String(
            contentsOf: root.appendingPathComponent("scripts/verify-dmg.sh"),
            encoding: .utf8
        )

        #expect(dmgSource.contains("$STAGING/$INSTALL_PACKAGE"))
        #expect(!dmgSource.contains("$STAGING/$DISPLAY_NAME.app"))
        #expect(!dmgSource.contains("$STAGING/$UNINSTALL_PACKAGE"))
        #expect(!dmgSource.contains("ln -s /Applications"))
        #expect(verifierSource.contains("EXPECTED_ROOT_ENTRIES=\"$RELEASE_INSTALL_PACKAGE_NAME\""))
        #expect(postinstallSource.contains("driver_is_healthy_and_current()"))
        #expect(postinstallSource.contains("/usr/bin/file -b \"$1\""))
        #expect(postinstallSource.contains("CFBundleVersion"))
        #expect(postinstallSource.contains("/usr/bin/codesign --verify --deep --strict"))
        #expect(postinstallSource.contains("was kept in place"))
        #expect(!postinstallSource.contains("/usr/bin/lipo"))
        #expect(!postinstallSource.contains("xcrun"))
    }

    @Test func stablePromotionRequiresMainAndCandidateProvenance() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let guardWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/release-guard.yml"),
            encoding: .utf8
        )
        let promotionWorkflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-stable-promote.yml"),
            encoding: .utf8
        )
        let reconciliationSource = try String(
            contentsOf: root.appendingPathComponent("scripts/reconcile-release-event.sh"),
            encoding: .utf8
        )

        #expect(guardWorkflow.contains("types: [published, released, edited]"))
        #expect(guardWorkflow.contains("workflow_dispatch:"))
        #expect(guardWorkflow.contains("github.event.inputs.tag || github.event.release.tag_name"))
        #expect(guardWorkflow.contains("contents: write"))
        #expect(guardWorkflow.contains("pull-requests: write"))
        #expect(guardWorkflow.contains("issues: write"))
        #expect(guardWorkflow.contains("actions: write"))
        #expect(reconciliationSource.contains("restored $RELEASE_TAG to pre-release"))
        #expect(reconciliationSource.contains("candidate-provenance.json"))
        #expect(reconciliationSource.contains("stable-promotion.json"))
        #expect(reconciliationSource.contains(".candidateBranch == (\"release/pre-\" + $tag)"))
        #expect(reconciliationSource.contains(".schemaVersion == 1 or .schemaVersion == 2"))
        #expect(reconciliationSource.contains("baseMainCommit"))
        #expect(reconciliationSource.contains("Record $RELEASE_TAG preview candidate in main"))
        #expect(reconciliationSource.contains("This PR does not promote the GitHub Release to stable"))
        #expect(reconciliationSource.contains("preview candidate auto-merge"))
        #expect(reconciliationSource.contains("gh pr merge \"$PR_NUMBER\""))
        #expect(reconciliationSource.contains("--auto --merge"))
        #expect(reconciliationSource.contains("gh workflow run mac-ci.yml"))
        #expect(reconciliationSource.contains("stable-promotion-approved"))
        #expect(promotionWorkflow.contains("workflow_dispatch:"))
        #expect(promotionWorkflow.contains("workflow_run:"))
        #expect(promotionWorkflow.contains("github.event.workflow_run.conclusion == 'success'"))
        #expect(promotionWorkflow.contains("github.event.workflow_run.event == 'workflow_dispatch'"))
        #expect(promotionWorkflow.contains("stable-promotion-approved"))
        #expect(promotionWorkflow.contains("skipping promotion"))
        #expect(promotionWorkflow.contains("steps.release.outputs.should_promote == 'true'"))
        #expect(promotionWorkflow.contains("gh pr merge \"$pr_number\""))
        #expect(promotionWorkflow.contains("./scripts/publish-release.sh promote"))
        #expect(!promotionWorkflow.contains("notarize-release.sh"))
        #expect(publishSourceSupportsCrossVersionPromotion(root: root))
    }

    private func publishSourceSupportsCrossVersionPromotion(root: URL) -> Bool {
        guard let source = try? String(
            contentsOf: root.appendingPathComponent("scripts/publish-release.sh"),
            encoding: .utf8
        ) else {
            return false
        }
        return source.contains("stable promotion requires an explicit RELEASE_TAG") &&
            source.contains("VERSION=\"$(jq -r '.version' \"$provenance\")\"") &&
            source.contains(".candidateBranch == $candidateBranch")
    }

    @Test func releasePublishesLocalizedUpdateNotesWithImmutableURLs() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let notarizeSource = try String(
            contentsOf: root.appendingPathComponent("scripts/notarize-release.sh"),
            encoding: .utf8
        )
        let publishSource = try String(
            contentsOf: root.appendingPathComponent("scripts/publish-release.sh"),
            encoding: .utf8
        )

        for requiredText in [
            "Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.zh.txt",
            "Remote-Mic-$VERSION$RELEASE_ASSET_SUFFIX.en.txt",
            "--release-notes-url-prefix \"$CDN_DOWNLOAD_PREFIX\"",
        ] {
            #expect(notarizeSource.contains(requiredText))
        }
        #expect(notarizeSource.contains("GENERATE_SPARKLE_UPDATE=\"${GENERATE_SPARKLE_UPDATE:-1}\""))
        #expect(notarizeSource.contains("SPARKLE UPDATE: skipped for private test package"))
        #expect(publishSource.contains("Remote-Mic-$VERSION-AppleSilicon-Installer.pkg"))
        #expect(publishSource.contains("Remote-Mic-$VERSION-AppleSilicon-Uninstaller.pkg"))
        #expect(publishSource.contains("Remote-Mic-$VERSION-Intel-Installer.pkg"))
        #expect(publishSource.contains("Remote-Mic-$VERSION-Intel-Uninstaller.pkg"))
        #expect(publishSource.contains("$STAGING_DIR/${ZH_RELEASE_NOTES:t}"))
        #expect(publishSource.contains("$STAGING_DIR/${EN_RELEASE_NOTES:t}"))
        #expect(publishSource.contains("$STAGING_DIR/${INTEL_ZH_RELEASE_NOTES:t}"))
        #expect(publishSource.contains("$STAGING_DIR/${INTEL_EN_RELEASE_NOTES:t}"))
        #expect(publishSource.contains(".payloadAssets | length' \"$CANDIDATE_PROVENANCE\")\" = \"16\""))
        #expect(publishSource.contains("= \"17\""))
        #expect(publishSource.contains("== 12 or (.payloadAssets | length) == 14 or (.payloadAssets | length) == 16"))
        #expect(publishSource.contains("candidate-provenance.json"))
        #expect(notarizeSource.contains("GITHUB_DOWNLOAD_PREFIX=\"https://github.com/MaydayV/remote-mic-app/releases/download/$RELEASE_TAG/\""))
        #expect(publishSource.contains("appcast-intel.xml"))
        #expect(publishSource.contains("--range 0-1023"))
        #expect(publishSource.contains("x-remote-mic-cdn: cloudflare"))
    }

    @Test func protectedGitHubActionsReleasePackagesBothMacArchitectures() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let workflowSource = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/mac-release-package.yml"),
            encoding: .utf8
        )
        let bootstrapSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/package-macos-release-in-actions.sh"
            ),
            encoding: .utf8
        )
        let publishSource = try String(
            contentsOf: root.appendingPathComponent("scripts/publish-release.sh"),
            encoding: .utf8
        )

        #expect(workflowSource.contains("workflow_dispatch:"))
        #expect(workflowSource.contains("push:"))
        #expect(workflowSource.contains("branches: [main]"))
        #expect(workflowSource.contains("workflow_run:"))
        #expect(workflowSource.contains("macOS Preview Candidate"))
        #expect(workflowSource.contains("github.event.workflow_run.conclusion == 'success'"))
        #expect(workflowSource.contains("contents: write"))
        #expect(workflowSource.contains("actions: write"))
        #expect(workflowSource.contains("git tag -a \"$RELEASE_TAG\""))
        #expect(workflowSource.contains("publish-release.sh prerelease"))
        #expect(workflowSource.contains("publish-release.sh auto"))
        #expect(workflowSource.contains("prepare-main-auto-release.sh"))
        #expect(workflowSource.contains("github.event_name == 'push'"))
        #expect(workflowSource.contains("RELEASE_CANDIDATE_BRANCH"))
        #expect(workflowSource.contains("environment: mac-release"))
        #expect(workflowSource.contains("RELEASE_CREDENTIALS_DEPLOY_KEY"))
        #expect(workflowSource.contains("APPLE_SIGNING_MATCH_DEPLOY_KEY"))
        #expect(workflowSource.contains("RELEASE_AGE_IDENTITY"))
        #expect(workflowSource.contains("MaydayV/remotemic-notary-secrets"))
        #expect(workflowSource.contains("MaydayV/apple-signing-match"))
        #expect(workflowSource.contains("package-macos-release-in-actions.sh"))
        #expect(bootstrapSource.contains("GITHUB_ACTIONS"))
        #expect(bootstrapSource.contains("run-with-isolated-release-keychain.sh"))
        #expect(bootstrapSource.contains("validate-notary-secrets-repo.sh"))
        #expect(bootstrapSource.contains("validate-signing-repo.sh"))
        #expect(bootstrapSource.contains("MATCH_GIT_URL=\"file://$MATCH_REPO\""))
        #expect(bootstrapSource.contains("SPARKLE_PRIVATE_KEY_ENCRYPTED_FILE"))
        #expect(!workflowSource.contains("CERTIFICATE_BASE64"))
        #expect(!workflowSource.contains("NOTARY_API_KEY_BASE64"))
        #expect(!workflowSource.contains("SPARKLE_PRIVATE_KEY_BASE64"))
        #expect(!workflowSource.contains("pull_request:"))
        #expect(publishSource.contains("## What's New"))
        #expect(publishSource.contains("Resources/en.lproj/ReleaseHistory.md"))
    }

    @Test func mainPushPreparesANewVersionAndStableReleaseNotes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let preparationSource = try String(
            contentsOf: root.appendingPathComponent(
                "scripts/prepare-main-auto-release.sh"
            ),
            encoding: .utf8
        )
        #expect(preparationSource.contains("releases/latest"))
        #expect(preparationSource.contains("CFBundleShortVersionString"))
        #expect(preparationSource.contains("CFBundleVersion"))
        #expect(preparationSource.contains("ReleaseHistory.md"))
        #expect(preparationSource.contains("GITHUB_RUN_NUMBER"))
        #expect(preparationSource.contains("git ls-remote --exit-code --refs origin"))
        #expect(preparationSource.contains("collision_count"))
    }
}
