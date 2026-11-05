"""Retention safety tests; all releases and data live in temporary directories."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('retention_adapter', Path(__file__).with_name('adapter.py'))
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


class ReleaseRetentionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = Path(self.tmp.name).resolve() / 'releases'
        self.store.mkdir()
        self.ids = ['sha256:' + format(i, '064x') for i in range(1, 6)]
        for i, identifier in enumerate(self.ids):
            directory = self.directory(identifier)
            directory.mkdir()
            ready = directory / '.release-ready.json'
            ready.write_text('{}')
            os.utime(ready, (i + 1, i + 1))
        self.retention = adapter.ReleaseRetention(self.store, lambda identifier: True)

    def directory(self, identifier):
        return self.store / identifier[7:]

    def write(self, name, value):
        (self.store / name).write_text(json.dumps(value))

    def history(self):
        return json.loads((self.store / 'retention.json').read_text())

    def prune(self, **kwargs):
        with patch.object(self.retention, '_live', return_value=set()):
            return self.retention.prune(**kwargs)

    def test_successful_activation_retains_previous_success(self):
        self.retention.remember(self.ids[1])
        self.retention.remember(self.ids[2])
        self.assertEqual(self.history(), dict(current=self.ids[2], rollback=self.ids[1]))
        self.prune()
        self.assertEqual({p.name for p in self.store.iterdir() if p.is_dir()},
                         {self.ids[1][7:], self.ids[2][7:]})

    def test_stopping_partial_failed_activation_preserves_success_history(self):
        self.retention.remember(self.ids[1])
        original = self.history()
        result = SimpleNamespace(returncode=0, stdout=b'', stderr=b'')
        with patch.object(adapter, 'STORE', self.store), \
             patch.object(adapter, 'ACTIVE', self.store / 'active.json'), \
             patch.object(adapter, 'verified', return_value=True), \
             patch.object(adapter, 'legacy', return_value=result), \
             patch.object(adapter, 'signature', return_value=None), \
             patch.object(adapter, 'identities', return_value=[dict(pid=999999, identity='test')]), \
             patch.object(adapter, 'attach_runtime'), \
             patch.dict(os.environ, PROJECT_TARGET_REVISION=self.ids[2], PROJECT_ARTIFACT_ID=self.ids[2]):
            # Failed startup can still create active.json for the partially started process.
            with patch.object(adapter, 'legacy', return_value=SimpleNamespace(
                    returncode=1, stdout=b'', stderr=b'')):
                with self.assertRaises(RuntimeError):
                    adapter.activate()
            self.assertTrue((self.store / 'active.json').exists())
            adapter.stop()
            self.assertEqual(self.history(), original)
            self.retention.remember(self.ids[3])
            self.assertEqual(self.history()['rollback'], self.ids[1])

    def test_stop_seeds_history_for_legacy_release(self):
        self.write('active.json', dict(artifactId=self.ids[1], processes=[]))
        with patch.object(adapter, 'STORE', self.store), \
             patch.object(adapter, 'ACTIVE', self.store / 'active.json'), \
             patch.object(adapter, 'verified', return_value=True), \
             patch.object(adapter, 'legacy', return_value=SimpleNamespace(
                 returncode=0, stdout=b'', stderr=b'')):
            adapter.stop()
        self.assertEqual(self.history(), dict(current=self.ids[1], rollback=self.ids[0]))

    def test_activation_marks_success_only_after_health_check(self):
        self.retention.remember(self.ids[1])
        result = SimpleNamespace(returncode=0, stdout=b'', stderr=b'')
        def legacy(action, directory=adapter.ROOT, check=True):
            if action == 'status' and directory == adapter.ROOT:
                return SimpleNamespace(returncode=1, stdout=b'', stderr=b'')
            return result
        with patch.object(adapter, 'STORE', self.store), \
             patch.object(adapter, 'ACTIVE', self.store / 'active.json'), \
             patch.object(adapter, 'verified', return_value=True), \
             patch.object(adapter, 'legacy', side_effect=legacy), \
             patch.object(adapter, 'identities', return_value=[dict(pid=999999, identity='test')]), \
             patch.object(adapter, 'attach_runtime'), \
             patch.dict(os.environ, PROJECT_TARGET_REVISION=self.ids[2], PROJECT_ARTIFACT_ID=self.ids[2]):
            adapter.activate()
        self.assertTrue(json.loads((self.store / 'active.json').read_text())['activationSucceeded'])
        self.assertEqual(self.history(), dict(current=self.ids[2], rollback=self.ids[1]))

    def test_health_check_exception_keeps_partial_process_record(self):
        calls = [SimpleNamespace(returncode=1), SimpleNamespace(returncode=0, stdout=b'', stderr=b''),
                 subprocess.TimeoutExpired('status', 1)]
        with patch.object(adapter, 'STORE', self.store), \
             patch.object(adapter, 'ACTIVE', self.store / 'active.json'), \
             patch.object(adapter, 'verified', return_value=True), \
             patch.object(adapter, 'legacy', side_effect=calls), \
             patch.object(adapter, 'identities', return_value=[dict(pid=999999, identity='test')]), \
             patch.object(adapter, 'attach_runtime'), \
             patch.dict(os.environ, PROJECT_TARGET_REVISION=self.ids[2], PROJECT_ARTIFACT_ID=self.ids[2]):
            with self.assertRaises(subprocess.TimeoutExpired):
                adapter.activate()
        record = json.loads((self.store / 'active.json').read_text())
        self.assertFalse(record['activationSucceeded'])
        self.assertEqual(record['processes'][0]['pid'], 999999)
        self.assertFalse((self.store / 'retention.json').exists())

    def test_first_failed_activation_never_seeds_success_history(self):
        self.write('active.json', dict(artifactId=self.ids[1], processes=[],
                                      activationSucceeded=False))
        self.assertEqual(self.prune()['removed'], [])
        self.assertFalse((self.store / 'retention.json').exists())
        with patch.object(adapter, 'STORE', self.store), \
             patch.object(adapter, 'ACTIVE', self.store / 'active.json'), \
             patch.object(adapter, 'verified', return_value=True), \
             patch.object(adapter, 'legacy', return_value=SimpleNamespace(
                 returncode=0, stdout=b'', stderr=b'')):
            adapter.stop()
        self.assertFalse((self.store / 'retention.json').exists())

    def test_pending_active_and_live_releases_are_protected(self):
        self.retention.remember(self.ids[1])
        self.write('active.json', dict(artifactId=self.ids[2]))
        self.write('built.json', dict(builtRevision=self.ids[3]))
        with patch.object(self.retention, '_live', return_value={self.ids[4][7:]}):
            self.assertEqual(self.retention.prune()['removed'], [])

    def test_invalid_rollback_or_failed_inspection_prevents_deletion(self):
        self.retention.remember(self.ids[1])
        for failure in ('rollback', 'inspection'):
            with self.subTest(failure=failure):
                with patch.object(self.retention, 'verify', return_value=failure != 'rollback'), \
                     patch.object(self.retention, '_live', side_effect=OSError('inspection failed')):
                    with self.assertRaises((ValueError, OSError)):
                        self.retention.prune()
                self.assertTrue(all(self.directory(i).exists() for i in self.ids))

    def test_dry_run_does_not_initialize_or_delete(self):
        self.write('active.json', dict(artifactId=self.ids[1]))
        self.prune(dry_run=True)
        self.assertFalse((self.store / 'retention.json').exists())
        self.retention.remember(self.ids[1])
        original = self.history()
        self.assertEqual(len(self.prune(dry_run=True)['removed']), 3)
        self.assertEqual(self.history(), original)
        self.assertTrue(all(self.directory(i).exists() for i in self.ids))

    def test_recent_incomplete_build_and_external_data_survive(self):
        self.retention.remember(self.ids[1])
        recent = self.directory(self.ids[2])
        (recent / '.release-ready.json').unlink()
        os.utime(recent, None)
        old = self.directory(self.ids[3])
        (old / '.release-ready.json').unlink()
        data = Path(self.tmp.name) / 'user-data'
        data.mkdir()
        (data / 'important').write_text('preserve')
        (old / 'data').symlink_to(data, target_is_directory=True)
        os.utime(old, (1, 1))
        self.prune()
        self.assertTrue(recent.exists())
        self.assertFalse(old.exists())
        self.assertEqual((data / 'important').read_text(), 'preserve')

    def test_live_detection_matches_commands_and_working_directories(self):
        commands = SimpleNamespace(stdout='123 node ' + str(self.directory(self.ids[2]) / 'server.js'))
        cwd = SimpleNamespace(stdout='p456\nn' + str(self.directory(self.ids[3])) + '\n')
        with patch('release_retention.subprocess.run', side_effect=[commands, cwd]):
            self.assertEqual(self.retention._live(self.retention._candidates()),
                             {self.ids[2][7:], self.ids[3][7:]})

    def test_symlinked_metadata_and_missing_current_prevent_deletion(self):
        self.retention.remember(self.ids[1])
        (self.store / 'retention.json').unlink()
        external = Path(self.tmp.name) / 'history.json'
        external.write_text(json.dumps(dict(current=self.ids[1], rollback=self.ids[0])))
        (self.store / 'retention.json').symlink_to(external)
        with self.assertRaises(ValueError):
            self.prune()
        (self.store / 'retention.json').unlink()
        self.write('retention.json', dict(current='sha256:' + 'f' * 64))
        with self.assertRaises(ValueError):
            self.prune()
        self.assertTrue(all(self.directory(i).exists() for i in self.ids))


if __name__ == '__main__':
    unittest.main()

