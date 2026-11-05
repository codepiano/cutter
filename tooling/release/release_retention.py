"""Bound project-owned immutable releases. Call while holding operation.lock."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


class ReleaseRetention:
    def __init__(self, store, verify):
        self.store = Path(store)
        self.verify = verify
        self.history = self.store / 'retention.json'

    @staticmethod
    def _name(identifier):
        if not isinstance(identifier, str) or not re.fullmatch(r'sha256:[0-9a-f]{64}', identifier):
            raise ValueError('Invalid release identifier in retention metadata')
        return identifier[7:]

    def _read(self, path):
        if path.is_symlink():
            raise ValueError('Refusing symlinked retention metadata')
        try:
            value = json.loads(path.read_text())
        except FileNotFoundError:
            return {}
        if not isinstance(value, dict):
            raise ValueError('Invalid retention metadata')
        return value

    def _write(self, value):
        temporary = self.history.with_name('retention.' + str(os.getpid()) + '.tmp')
        try:
            with temporary.open('x') as stream:
                json.dump(value, stream)
            temporary.chmod(0o600)
            temporary.replace(self.history)
        finally:
            temporary.unlink(missing_ok=True)

    def _candidates(self):
        if self.store.is_symlink() or self.store.resolve() != self.store.absolute():
            raise ValueError('Refusing redirected release store')
        return [p for p in self.store.iterdir()
                if re.fullmatch(r'[0-9a-f]{64}', p.name) and p.is_dir() and not p.is_symlink()]

    def _valid(self, identifier):
        name = self._name(identifier)
        path = self.store / name
        return not path.is_symlink() and path.is_dir() and self.verify(identifier)

    def remember(self, identifier, *, seed_only=False):
        """Record a successful activation, or seed the existing active release before stop."""
        self._candidates()  # Validate the store before writing activation history.
        current = self._name(identifier)
        history = self._read(self.history)
        # stop() may address a partial failed activation. Only activate() can
        # advance existing successful history; stop() seeds legacy stores only.
        if seed_only and history:
            return
        if history.get('current') == identifier:
            return
        previous = history.get('current')
        rollback = previous if previous and previous != identifier and self._valid(previous) else None
        if not rollback:
            # Migration from adapters without activation history: choose an older verified build.
            ready = self.store / current / '.release-ready.json'
            cutoff = ready.stat().st_mtime
            older = [p for p in self._candidates()
                     if p.name != current and (p / '.release-ready.json').is_file()
                     and (p / '.release-ready.json').stat().st_mtime <= cutoff]
            older.sort(key=lambda p: ((p / '.release-ready.json').stat().st_mtime, p.name), reverse=True)
            for path in older:
                candidate = 'sha256:' + path.name
                if self._valid(candidate):
                    rollback = candidate
                    break
        self._write(dict(current=identifier, rollback=rollback))

    def _live(self, candidates):
        # Fail closed if process inspection is unavailable. Never infer ownership from app names.
        result = subprocess.run(['ps', '-axo', 'pid=,command='], capture_output=True, text=True,
                                check=True, timeout=20)
        live = {p.name for p in candidates if str(p) + '/' in result.stdout}
        result = subprocess.run(['lsof', '-a', '-d', 'cwd', '-F', 'pn'], capture_output=True,
                                text=True, check=True, timeout=20)
        for line in result.stdout.splitlines():
            if line.startswith('n'):
                for path in candidates:
                    if line[1:] == str(path) or line[1:].startswith(str(path) + '/'):
                        live.add(path.name)
        return live

    def prune(self, dry_run=False):
        candidates = self._candidates()
        active_record = self._read(self.store / 'active.json')
        active = active_record.get('artifactId')
        history = self._read(self.history)
        if active and not history and active_record.get('activationSucceeded', True):
            if not dry_run:
                self.remember(active)
                history = self._read(self.history)
            else:
                # Preview must not create metadata or invent a rollback choice.
                return dict(removed=[], skipped='initialize activation history first')
        if not history.get('current'):
            return dict(removed=[], skipped='no successful activation recorded')
        current = self._name(history['current'])
        if current not in {p.name for p in candidates}:
            raise ValueError('Current release is missing; retaining all releases')
        protected = {current}
        rollback = history.get('rollback')
        if rollback:
            if not self._valid(rollback):
                raise ValueError('Rollback verification failed; retaining all releases')
            protected.add(self._name(rollback))
        if active:
            protected.add(self._name(active))  # Also protects partial/failed activations.
        built = self._read(self.store / 'built.json').get('builtRevision')
        if built:
            protected.add(self._name(built))  # A pending build can temporarily be the third copy.
        protected.update(self._live(candidates))
        removed = []
        for path in sorted(candidates):
            if path.name in protected:
                continue
            # Abandoned partial builds are eligible only after a day, under the build lock.
            if not (path / '.release-ready.json').is_file() and time.time() - path.stat().st_mtime < 86400:
                continue
            if not dry_run:
                shutil.rmtree(path)  # Does not follow persistent-data symlinks.
            removed.append(path.name)
        return dict(removed=removed, kept=sorted(p.name for p in candidates if p.name not in removed))
