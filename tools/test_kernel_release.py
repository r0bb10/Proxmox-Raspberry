#!/usr/bin/env python3
"""Tests for missing-flavour planning and immutable release publication."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('kernel_release', Path(__file__).with_name('kernel-release.py'))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
BASE = '6.18.57-rpi'
V8 = f'linux-image-{BASE}-v8.deb'
PI5 = f'linux-image-{BASE}-2712.deb'


class ReleaseTests(unittest.TestCase):
    def test_new_release_builds_both(self):
        matrix = release.plan_builds(BASE, 'all', None)
        self.assertEqual([item['flavour'] for item in matrix['include']], ['v8', '2712'])

    def test_existing_pi4_only_builds_missing_pi5(self):
        matrix = release.plan_builds(BASE, 'all', [{'name': V8}])
        self.assertEqual(matrix, {'include': [{'flavour': '2712', 'kernel_version': BASE + '-2712'}]})

    def test_complete_release_is_noop(self):
        self.assertEqual(release.plan_builds(BASE, 'all', [{'name': V8}, {'name': PI5}]), {'include': []})

    def test_explicit_flavour(self):
        self.assertEqual(release.plan_builds(BASE, 'v8', [{'name': V8}]), {'include': []})
        matrix = release.plan_builds(BASE, '2712', None)
        self.assertEqual(len(matrix['include']), 1)

    def test_force_plans_rebuild_without_allowing_replacement(self):
        matrix = release.plan_builds(BASE, 'all', [{'name': V8}, {'name': PI5}], force=True)
        self.assertEqual(len(matrix['include']), 2)

    def test_invalid_inputs(self):
        for base, flavour in [('../invalid', 'all'), (BASE, 'invalid')]:
            with self.assertRaises(ValueError):
                release.plan_builds(base, flavour, None)

    @patch.object(release.subprocess, 'run')
    def test_api_failure_is_not_treated_as_missing_release(self, run):
        run.return_value = subprocess.CompletedProcess([], 1, '', 'HTTP 500')
        with self.assertRaises(RuntimeError):
            release.release_assets('owner/repo', BASE)
        run.return_value = subprocess.CompletedProcess([], 1, '', 'gh: Not Found (HTTP 404)')
        self.assertIsNone(release.release_assets('owner/repo', BASE))

    @patch.object(release.subprocess, 'run')
    @patch.object(release, 'release_assets')
    def test_publish_only_adds_missing_asset(self, assets, run):
        assets.return_value = [{'name': V8}]
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, PI5).write_bytes(b'kernel')
            matrix = release.plan_builds(BASE, '2712', assets.return_value)
            release.publish('owner/repo', BASE, matrix, directory)
        run.assert_called_once()
        self.assertEqual(run.call_args.args[0][:4], ['gh', 'release', 'upload', BASE])
        self.assertNotIn('--clobber', run.call_args.args[0])

    @patch.object(release.subprocess, 'run')
    @patch.object(release, 'release_assets')
    def test_refuse_changed_published_asset(self, assets, run):
        assets.return_value = [{'name': PI5, 'digest': 'sha256:old'}]
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, PI5).write_bytes(b'new kernel')
            matrix = release.plan_builds(BASE, '2712', [], force=True)
            with self.assertRaisesRegex(ValueError, 'Refusing to replace'):
                release.publish('owner/repo', BASE, matrix, directory)
        run.assert_not_called()

    @patch.object(release.subprocess, 'run')
    @patch.object(release, 'release_assets')
    def test_identical_published_asset_is_noop(self, assets, run):
        data = b'kernel'
        assets.return_value = [{'name': PI5, 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}]
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, PI5).write_bytes(data)
            matrix = release.plan_builds(BASE, '2712', [], force=True)
            release.publish('owner/repo', BASE, matrix, directory)
        run.assert_not_called()

    def test_unexpected_artifact_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, V8).touch()
            with self.assertRaisesRegex(ValueError, 'Expected'):
                release.publish('owner/repo', BASE, release.plan_builds(BASE, '2712', []), directory)


if __name__ == '__main__':
    unittest.main()
