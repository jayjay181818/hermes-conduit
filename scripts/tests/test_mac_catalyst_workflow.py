"""Contract for the fork's credential-free Mac Catalyst merge check."""

import os
import unittest

from _util import SCRIPTS_DIR

REPO_ROOT = os.path.dirname(SCRIPTS_DIR)
WORKFLOW = os.path.join(REPO_ROOT, ".github", "workflows", "mac-catalyst.yml")


def _read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


class MacCatalystWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = _read(WORKFLOW)

    def test_only_the_fork_branch_triggers_builds(self):
        self.assertRegex(self.workflow, r"(?m)^  pull_request:\n    branches: \[macos-port\]$")
        self.assertRegex(self.workflow, r"(?m)^  push:\n    branches: \[macos-port\]$")
        self.assertIn("  workflow_dispatch:", self.workflow)

    def test_uses_supported_runner_and_debug_catalyst_scheme(self):
        self.assertIn("runs-on: macos-26", self.workflow)
        self.assertIn("timeout-minutes: 45", self.workflow)
        self.assertIn("--spec scripts/mac-catalyst/project.yml", self.workflow)
        self.assertIn("-scheme ConduitMac", self.workflow)
        self.assertIn("-configuration Debug", self.workflow)
        self.assertIn("platform=macOS,variant=Mac Catalyst", self.workflow)

    def test_selected_tests_cover_requested_regression_areas(self):
        for suite in (
            "MacWheelSwipeGuardTests",
            "CredentialVaultTests",
            "DashboardRequestAuthorizerTests",
            "NotificationE2ETests",
            "CarPlayVoiceCoordinatorTests",
            "ComposerFullEditorTests",
            "NotificationCopyTests",
            "ComposerPasteTextViewTests",
            "ComposerReturnKeyTests",
            "WidgetLaunchLinkTests",
            "AppStateReasoningStreamTests",
        ):
            with self.subTest(suite=suite):
                self.assertIn("-only-testing:ConduitTests/" + suite, self.workflow)

    def test_provider_backed_review_jobs_stay_on_upstream(self):
        workflow = _read(os.path.join(REPO_ROOT, ".github", "workflows", "opencode-review.yml"))
        plan = workflow[workflow.index("  plan:\n"):workflow.index("  review:\n")]
        self.assertIn("github.repository == 'kaishi00/hermes-conduit' && (", plan)

    def test_failure_logs_are_bounded_and_no_retry_or_artifact_flow(self):
        self.assertIn("tail -30", self.workflow)
        self.assertIn("tail -40", self.workflow)
        self.assertNotRegex(self.workflow, r"(?i)retry|upload-artifact|download-artifact")
        self.assertNotRegex(self.workflow, r"(?i)\bsecrets\.")
        self.assertIn("persist-credentials: false", self.workflow)
        self.assertNotRegex(self.workflow, r"(?m)^\s*(?:path|name):.*(?:\.app|DerivedData)")


if __name__ == "__main__":
    unittest.main()
