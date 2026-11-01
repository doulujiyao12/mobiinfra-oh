"""Archive-layout tests; no target-platform app is executed."""
import importlib.util
import plistlib
from pathlib import Path
import stat
import tempfile
import tarfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('portable', Path(__file__).parents[1] / 'build' / 'portable-desktop.py')
portable = importlib.util.module_from_spec(spec)
spec.loader.exec_module(portable)


class PortableTests(unittest.TestCase):
    def test_windows_terminal_zip_retains_unicode_names_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); stage = root / 'stage'; resources = stage / 'resources'
            (resources / 'bin').mkdir(parents=True)
            (resources / 'bin' / 'clawmate-codex.exe').write_bytes(b'MZ-launcher')
            (resources / '使用说明.md').write_text('ClawMate 使用指南', encoding='utf-8')
            destination = root / 'terminal.zip'
            portable.windows_terminal_bundle(stage, destination)
            with zipfile.ZipFile(destination) as archive:
                self.assertEqual(archive.read('bin/clawmate-codex.exe'), b'MZ-launcher')
                self.assertEqual(archive.read('使用说明.md').decode('utf-8'), 'ClawMate 使用指南')
                self.assertTrue(archive.getinfo('使用说明.md').flag_bits & 0x800)
                self.assertFalse(any('app/' in name for name in archive.namelist()))

    def test_terminal_cross_host_archive_retains_execute_bits_and_layout(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); stage = root / 'stage'; resources = stage / 'resources'
            (resources / 'bin').mkdir(parents=True)
            (resources / 'host').mkdir()
            (resources / 'bin' / 'clawmate-codex').write_bytes(b'\x7fELF-launcher')
            (resources / 'bin' / 'helper').write_bytes(b'#!/bin/sh\nexit 0\n')
            (resources / 'host' / 'cli.mjs').write_text('fixture')
            destination = root / 'terminal.tar.gz'
            portable.terminal_bundle(stage, destination)
            with tarfile.open(destination) as result:
                self.assertEqual(result.getmember('bin/clawmate-codex').mode, 0o755)
                self.assertEqual(result.getmember('bin/helper').mode, 0o755)
                self.assertEqual(result.getmember('host/cli.mjs').mode, 0o644)
                self.assertEqual(result.getmember('bin').mode, 0o755)
                self.assertEqual(result.extractfile('host/cli.mjs').read(), b'fixture')
                self.assertTrue(all(not name.startswith('/') and '..' not in Path(name).parts for name in result.getnames()))

    def test_mac_symlinks_plist_and_native_executable_modes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); stage = root / 'stage'
            (stage / 'app').mkdir(parents=True); (stage / 'resources' / 'runtime').mkdir(parents=True)
            (stage / 'app' / 'package.json').write_text('{"name":"clawmate"}')
            (stage / 'resources' / 'runtime' / 'node').write_bytes(b'\xcf\xfa\xed\xfe-native-node')
            original = root / 'electron.zip'
            with zipfile.ZipFile(original, 'w') as output:
                output.writestr('Electron.app/Contents/Info.plist', plistlib.dumps({'CFBundleExecutable': 'Electron'}))
                output.writestr('Electron.app/Contents/MacOS/Electron', b'\xcf\xfa\xed\xfe-native-electron')
                output.writestr('Electron.app/Contents/Resources/default_app.asar', b'old default')
                link = zipfile.ZipInfo('Electron.app/Contents/Frameworks/Test.framework/Versions/Current')
                link.create_system = 3; link.external_attr = (stat.S_IFLNK | 0o777) << 16
                output.writestr(link, 'A')
            destination = root / 'mac.zip'
            portable.mac_bundle(original, stage, '1.1.1', destination)
            with zipfile.ZipFile(destination) as result:
                prefix = 'ClawMate Codex.app/Contents/'
                self.assertEqual(plistlib.loads(result.read(prefix + 'Info.plist'))['CFBundleExecutable'], 'Electron')
                self.assertEqual(plistlib.loads(result.read(prefix + 'Info.plist'))['CFBundleShortVersionString'], '1.1.1')
                self.assertTrue(stat.S_ISLNK(result.getinfo(prefix + 'Frameworks/Test.framework/Versions/Current').external_attr >> 16))
                self.assertEqual(result.getinfo(prefix + 'Resources/runtime/node').external_attr >> 16 & 0o777, 0o755)
                self.assertIn(prefix + 'Resources/app/package.json', result.namelist())
                self.assertNotIn(prefix + 'Resources/default_app.asar', result.namelist())

    def test_linux_payload_layout_permissions_and_archive_path_validation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); stage = root / 'stage'
            (stage / 'app').mkdir(parents=True); (stage / 'resources' / 'bin').mkdir(parents=True)
            (stage / 'app' / 'package.json').write_text('{"name":"clawmate"}')
            (stage / 'resources' / 'bin' / 'clawmate-codex').write_bytes(b'\x7fELF-launcher')
            original = root / 'electron.zip'
            with zipfile.ZipFile(original, 'w') as output:
                output.writestr('electron', b'\x7fELF-electron')
            destination = root / 'linux.tar.gz'
            portable.linux_bundle(original, stage, '1.1.1', destination)
            with tarfile.open(destination) as result:
                self.assertEqual(result.getmember('ClawMate-Codex/clawmate-codex-desktop').mode, 0o755)
                self.assertEqual(result.getmember('ClawMate-Codex/resources/bin/clawmate-codex').mode, 0o755)
                self.assertIn('ClawMate-Codex/resources/app/package.json', result.getnames())
            with self.assertRaises(ValueError):
                portable.safe_name('../escape')


if __name__ == '__main__':
    unittest.main()
