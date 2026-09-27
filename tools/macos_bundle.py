#!/usr/bin/env python3
"""Bundle and verify Mach-O dependencies without requiring signing credentials."""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

MAGIC = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe', 'cafebabe', 'bebafeca',
    'cafebabf', 'bfbafeca')}


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def is_macho(path):
    if not path.is_file() or path.is_symlink():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MAGIC


def binaries(root):
    return sorted(path for path in root.rglob('*') if is_macho(path))


def dependencies(binary):
    # Universal otool output includes one heading per architecture. Keep paths
    # containing spaces intact and deduplicate entries across slices.
    return list(dict.fromkeys(re.findall(
        r'^\s+(.+?) \(compatibility version ', run('otool', '-L', str(binary)), re.M)))


def install_id(binary):
    return {line.strip() for line in run('otool', '-D', str(binary)).splitlines()
            if line.strip() and not line.endswith(':')}


def rpaths(binary):
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.+?) \(offset',
                      run('otool', '-l', str(binary)))


def executable_for(binary, app):
    for parent in binary.parents:
        if parent.suffix in ('.app', '.appex', '.xpc'):
            info = parent / 'Contents/Info.plist'
            if info.exists():
                data = plistlib.loads(info.read_bytes())
                return parent / 'Contents/MacOS' / data['CFBundleExecutable']
        if parent == app:
            break
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    return app / 'Contents/MacOS' / info['CFBundleExecutable']


def system_library(name):
    return name.startswith(('/usr/lib/', '/System/Library/'))


def dependency_suffix(name):
    # Framework version directories must survive relocation.
    match = re.search(r'([^/]+\.framework/.*)$', name)
    return match.group(1) if match else Path(name).name


class Bundle:
    def __init__(self, app, search=()):
        self.app = Path(app).resolve()
        self.search = [Path(path).resolve() for path in search]
        self.frameworks = self.app / 'Contents/Frameworks'
        self.copied_sources = {}

    def resolve(self, binary, name):
        executable = executable_for(binary, self.app)

        def expand(value):
            return Path(value.replace('@loader_path', str(binary.parent))
                        .replace('@executable_path', str(executable.parent)))

        if not name.startswith('@rpath/'):
            path = expand(name)
            if path.is_file():
                return path.resolve()
        else:
            suffix = name[len('@rpath/'):]
            # Explicit build inputs take precedence over embedded build-machine
            # rpaths, which may still point at an older installed Craft library.
            for directory in self.search:
                candidate = directory / suffix
                if candidate.is_file():
                    return candidate.resolve()
            for entry in rpaths(binary) + rpaths(executable):
                candidate = expand(entry) / suffix
                if candidate.is_file():
                    return candidate.resolve()
            candidate = self.frameworks / suffix
            if candidate.is_file():
                return candidate.resolve()
        for directory in self.search:
            candidate = directory / dependency_suffix(name)
            if candidate.is_file():
                return candidate.resolve()
        raise RuntimeError(f'Missing dependency {name!r} required by {binary}')

    def copy_dependency(self, source, name):
        if source in self.copied_sources:
            return self.copied_sources[source]
        suffix = dependency_suffix(str(source))
        destination = self.frameworks / suffix
        self.frameworks.mkdir(parents=True, exist_ok=True)
        if '.framework/' in suffix:
            framework = next(parent for parent in source.parents if parent.suffix == '.framework')
            target = self.frameworks / framework.name
            if not target.exists():
                shutil.copytree(framework, target, symlinks=True)
        elif destination.exists():
            # Two unrelated libraries with the same basename must not silently
            # replace each other. System dependency aliases resolve to one source.
            if destination.read_bytes() != source.read_bytes():
                raise RuntimeError(f'Conflicting dependency filename: {name}')
        else:
            shutil.copy2(source, destination)
        if not destination.is_file():
            raise RuntimeError(f'Copied framework lacks dependency: {destination}')
        self.copied_sources[source] = destination.resolve()
        return destination.resolve()

    def repair(self):
        processed = set()
        while True:
            pending = [binary for binary in binaries(self.app) if binary not in processed]
            if not pending:
                break
            for binary in pending:
                processed.add(binary)
                own_ids = install_id(binary)
                for name in dependencies(binary):
                    if system_library(name) or name in own_ids:
                        continue
                    target = self.resolve(binary, name)
                    if not target.is_relative_to(self.app):
                        target = self.copy_dependency(target, name)
                    portable = '@loader_path/' + os.path.relpath(target, binary.parent)
                    if portable != name:
                        subprocess.run(['install_name_tool', '-change', name, portable, str(binary)], check=True)
                if own_ids:
                    subprocess.run(['install_name_tool', '-id', '@rpath/' + dependency_suffix(str(binary)), str(binary)], check=True)
                for entry in set(rpaths(binary)):
                    if entry.startswith('/') and not system_library(entry):
                        subprocess.run(['install_name_tool', '-delete_rpath', entry, str(binary)], check=True)
        self.verify()

    def verify(self):
        architectures = {}
        # Verification deliberately has no fallback to external build directories.
        verifier = Bundle(self.app)
        for binary in binaries(self.app):
            own_ids = install_id(binary)
            for name in dependencies(binary):
                if system_library(name) or name in own_ids:
                    continue
                target = verifier.resolve(binary, name)
                if not target.is_relative_to(self.app):
                    raise RuntimeError(f'External dependency {name!r} in {binary}')
                for path in (binary, target):
                    if path not in architectures:
                        architectures[path] = set(run('lipo', '-archs', str(path)).split())
                missing = architectures[binary] - architectures[target]
                if missing:
                    raise RuntimeError(f'{target} lacks {sorted(missing)} required by {binary}')
        print(f'Verified {len(binaries(self.app))} Mach-O files in {self.app}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--search', action='append', default=[],
                        help='Preferred @rpath dependency directory, in priority order')
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    bundle = Bundle(args.app, args.search)
    if args.verify_only:
        bundle.verify()
    else:
        bundle.repair()


if __name__ == '__main__':
    main()
