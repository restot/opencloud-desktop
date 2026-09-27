import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('macos_bundle', Path(__file__).resolve().parents[1] / 'tools/macos_bundle.py')
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


@unittest.skipUnless(sys.platform == 'darwin', 'Mach-O tools require macOS')
class BundleTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='bundle test ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / 'Example.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'example'}))
        self.source = self.root / 'source.c'
        self.source.write_text('int value(void) { return 42; }')
        self.main = self.root / 'main.c'
        self.main.write_text('int value(void); int main(void) { return value() != 42; }')

    def compile(self, library):
        library.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['xcrun', 'clang', '-dynamiclib', str(self.source), '-o', str(library),
                        '-Wl,-headerpad_max_install_names'], check=True)
        subprocess.run(['xcrun', 'clang', str(self.main), str(library), '-o',
                        str(self.app / 'Contents/MacOS/example'), '-Wl,-headerpad_max_install_names'], check=True)

    def test_relocates_library_and_runs_without_build_tree(self):
        library = self.root / 'external/libvalue.dylib'
        self.compile(library)
        bundle.Bundle(self.app).repair()
        library.unlink()
        bundle.Bundle(self.app).verify()
        subprocess.run([str(self.app / 'Contents/MacOS/example')], check=True)

    def test_preserves_framework_version_path(self):
        library = self.root / 'external/Value.framework/Versions/A/Value'
        self.compile(library)
        bundle.Bundle(self.app).repair()
        self.assertTrue((self.app / 'Contents/Frameworks/Value.framework/Versions/A/Value').is_file())
        library.unlink()
        bundle.Bundle(self.app).verify()
        subprocess.run([str(self.app / 'Contents/MacOS/example')], check=True)

    def test_explicit_build_directory_overrides_stale_rpath(self):
        stale = self.root / 'installed/libvalue.dylib'
        self.source.write_text('int old_value(void) { return 0; }')
        stale.parent.mkdir()
        subprocess.run(['xcrun', 'clang', '-dynamiclib', str(self.source), '-o', str(stale),
                        '-Wl,-install_name,@rpath/libvalue.dylib'], check=True)
        current = self.root / 'build/libvalue.dylib'
        self.source.write_text('int value(void) { return 42; }')
        self.compile(current)
        executable = self.app / 'Contents/MacOS/example'
        subprocess.run(['install_name_tool', '-change', str(current), '@rpath/libvalue.dylib',
                        '-add_rpath', str(stale.parent), str(executable)], check=True)
        bundle.Bundle(self.app, [current.parent]).repair()
        current.unlink()
        stale.unlink()
        subprocess.run([str(executable)], check=True)

    def test_fails_for_missing_dependency(self):
        library = self.root / 'external/libvalue.dylib'
        self.compile(library)
        library.unlink()
        with self.assertRaisesRegex(RuntimeError, 'Missing dependency'):
            bundle.Bundle(self.app).repair()

    def test_verification_rejects_external_library(self):
        library = self.root / 'external/libvalue.dylib'
        self.compile(library)
        with self.assertRaisesRegex(RuntimeError, 'External dependency'):
            bundle.Bundle(self.app).verify()


if __name__ == '__main__':
    unittest.main()
