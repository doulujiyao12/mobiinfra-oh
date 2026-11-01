import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('portable', Path(__file__).parent.parent / 'build' / 'portable-desktop.py')
portable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(portable)


class MacBundleTest(unittest.TestCase):
    def test_installed_bundle_has_branded_executable_and_runtimes_with_execute_bits(self):
        with tempfile.TemporaryDirectory(prefix='clawmate-mac-bundle-') as directory:
            root = Path(directory)
            stage = root / 'stage'
            (stage / 'app' / 'desktop').mkdir(parents=True)
            (stage / 'resources' / 'runtime' / 'bin').mkdir(parents=True)
            (stage / 'app' / 'package.json').write_text('{"main":"desktop/main.mjs"}')
            (stage / 'app' / 'desktop' / 'main.mjs').write_text('// app')
            for name in ['node', 'bin/codex']:
                (stage / 'resources' / 'runtime' / name).write_bytes(b'\xcf\xfa\xed\xfe' + b'payload')
            source, output = root / 'electron.zip', root / 'clawmate.zip'
            with zipfile.ZipFile(source, 'w') as z:
                z.writestr('Electron.app/Contents/Info.plist', plistlib.dumps({'CFBundleExecutable': 'Electron'}))
                entry = zipfile.ZipInfo('Electron.app/Contents/MacOS/Electron')
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o755) << 16
                z.writestr(entry, b'\xcf\xfa\xed\xfe' + b'electron')
                link = zipfile.ZipInfo('Electron.app/Contents/Frameworks/Test.framework/Test')
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(link, b'Versions/Current/Test')
                z.writestr('Electron.app/Contents/_CodeSignature/CodeResources', 'old signature')
                z.writestr('Electron.app/Contents/Resources/default_app.asar', 'default app')
            portable.mac_bundle(source, stage, '1.1.14', output)
            with zipfile.ZipFile(output) as z:
                base = 'ClawMate Codex.app/Contents/'
                info = plistlib.loads(z.read(base + 'Info.plist'))
                self.assertEqual(info['CFBundleExecutable'], 'clawmate-codex-desktop')
                self.assertEqual(info['CFBundleVersion'], '1.1.14')
                for name in ['MacOS/clawmate-codex-desktop', 'Resources/runtime/node', 'Resources/runtime/bin/codex']:
                    self.assertTrue(z.getinfo(base + name).external_attr >> 16 & 0o111)
                self.assertNotIn(base + 'MacOS/Electron', z.namelist())
                self.assertNotIn(base + 'Resources/default_app.asar', z.namelist())
                self.assertNotIn(base + '_CodeSignature/CodeResources', z.namelist())
                self.assertTrue(stat.S_ISLNK(z.getinfo(base + 'Frameworks/Test.framework/Test').external_attr >> 16))
                self.assertEqual(z.read(base + 'Frameworks/Test.framework/Test'), b'Versions/Current/Test')


if __name__ == '__main__':
    unittest.main()
