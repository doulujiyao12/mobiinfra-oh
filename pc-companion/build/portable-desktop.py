"""Preserve official Electron archive symlinks/modes without extracting them on Windows.

Only local, checksum-verified release archives are inputs. This creates unsigned
evaluation apps; signing/notarization and native smoke tests require target hosts.
"""
import argparse
import copy
import io
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import tarfile
import zipfile


def safe_name(value):
    parts = PurePosixPath(value).parts
    if value.startswith('/') or '..' in parts or '\\' in value:
        raise ValueError('Unsafe archive member')
    return value


def executable(filename):
    with open(filename, 'rb') as stream:
        magic = stream.read(4)
    return magic in (b'\x7fELF', b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe') or magic.startswith(b'#!')


def payload(stage):
    for folder, prefix in ((stage / 'app', 'app'), (stage / 'resources', '')):
        for filename in sorted(folder.rglob('*')):
            if filename.is_symlink():
                raise ValueError('Staged payload must not contain symlinks')
            if filename.is_file():
                yield filename, '/'.join(p for p in (prefix, filename.relative_to(folder).as_posix()) if p)


def mac_bundle(source, stage, version, destination):
    product = 'ClawMate Codex.app/'
    with zipfile.ZipFile(source) as electron, zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for entry in electron.infolist():
            name = safe_name(entry.filename)
            if not name.startswith('Electron.app/'):
                name = 'ClawMate-Codex-Licenses/' + name
            else:
                name = product + name[len('Electron.app/'):]
            if name == product + 'Contents/MacOS/Electron':
                name = product + 'Contents/MacOS/clawmate-codex-desktop'
            if name.startswith(product + 'Contents/_CodeSignature/') or name == product + 'Contents/Resources/default_app.asar':
                continue
            changed = copy.copy(entry)
            changed.filename = name
            if name == product + 'Contents/Info.plist':
                info = plistlib.loads(electron.read(entry))
                info.update(CFBundleDisplayName='ClawMate Codex', CFBundleName='ClawMate Codex',
                            CFBundleExecutable='clawmate-codex-desktop',
                            CFBundleIdentifier='com.clawmate.codex.companion', CFBundleShortVersionString=version,
                            CFBundleVersion=version)
                output.writestr(changed, plistlib.dumps(info))
            else:
                with electron.open(entry) as incoming, output.open(changed, 'w', force_zip64=True) as outgoing:
                    shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
        for filename, relative in payload(stage):
            entry = zipfile.ZipInfo(product + 'Contents/Resources/' + relative)
            entry.create_system = 3
            entry.external_attr = (stat.S_IFREG | (0o755 if executable(filename) else 0o644)) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            with filename.open('rb') as incoming, output.open(entry, 'w', force_zip64=True) as outgoing:
                shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
        output.writestr('BUILD-NOTES.txt',
                        'ClawMate Codex ' + version + '\nUnsigned evaluation bundle built on a different host.\n'
                        'This .app contains native macOS Electron, Node and Codex runtimes.\n'
                        'Developer ID signing/notarization and native macOS validation are pending.\n'
                        'Production distribution must be built and signed on macOS.\n')


def linux_bundle(source, stage, version, destination):
    root = 'ClawMate-Codex/'
    with zipfile.ZipFile(source) as electron, tarfile.open(destination, 'w:gz', compresslevel=6) as output:
        for entry in electron.infolist():
            name = safe_name(entry.filename)
            if name == 'resources/default_app.asar':
                continue
            if name == 'electron':
                name = 'clawmate-codex-desktop'
            item = tarfile.TarInfo(root + name)
            mode = entry.external_attr >> 16
            item.mode = stat.S_IMODE(mode) or (0o755 if entry.is_dir() else 0o644)
            if stat.S_ISLNK(mode):
                item.type = tarfile.SYMTYPE
                item.linkname = electron.read(entry).decode()
                if item.linkname.startswith('/') or '..' in PurePosixPath(item.linkname).parts:
                    raise ValueError('Unsafe archive symlink')
                output.addfile(item)
            elif entry.is_dir():
                item.type = tarfile.DIRTYPE
                output.addfile(item)
            else:
                item.size = entry.file_size
                if name in ('clawmate-codex-desktop', 'chrome-sandbox', 'chrome_crashpad_handler'):
                    item.mode = 0o755
                with electron.open(entry) as incoming:
                    output.addfile(item, incoming)
        for filename, relative in payload(stage):
            item = tarfile.TarInfo(root + 'resources/' + relative)
            item.size = filename.stat().st_size
            item.mode = 0o755 if executable(filename) else 0o644
            with filename.open('rb') as incoming:
                output.addfile(item, incoming)
        notes = ('ClawMate Codex ' + version + '\nRun ./clawmate-codex-desktop from this directory.\n'
                 'Keep the resources directory beside the executable.\n'
                 'This unsigned cross-host bundle has not been run on Linux.\n'
                 'Use the native Linux build for a .deb package and system sandbox integration.\n').encode()
        item = tarfile.TarInfo(root + 'BUILD-NOTES.txt'); item.size = len(notes); item.mode = 0o644
        output.addfile(item, io.BytesIO(notes))


def windows_terminal_bundle(stage, destination):
    """Write UTF-8 filename flags instead of Windows tar's locale-dependent ZIP names."""
    resources = stage / 'resources'
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as output:
        for filename in sorted(resources.rglob('*')):
            if filename.is_symlink():
                raise ValueError('Staged terminal payload must not contain symlinks')
            relative = safe_name(filename.relative_to(resources).as_posix())
            if filename.is_dir():
                entry = zipfile.ZipInfo(relative + '/')
                entry.create_system = 3
                entry.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
                output.writestr(entry, b'')
            elif filename.is_file():
                entry = zipfile.ZipInfo(relative)
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | (0o755 if filename.suffix.lower() == '.exe' else 0o644)) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                with filename.open('rb') as incoming, output.open(entry, 'w', force_zip64=True) as outgoing:
                    shutil.copyfileobj(incoming, outgoing, 1024 * 1024)


def terminal_bundle(stage, destination):
    """Windows tar does not retain Unix execute bits, even for ELF binaries."""
    resources = stage / 'resources'
    with tarfile.open(destination, 'w:gz', compresslevel=6) as output:
        for filename in sorted(resources.rglob('*')):
            if filename.is_symlink():
                raise ValueError('Staged terminal payload must not contain symlinks')
            relative = safe_name(filename.relative_to(resources).as_posix())
            item = tarfile.TarInfo(relative)
            if filename.is_dir():
                item.type = tarfile.DIRTYPE
                item.mode = 0o755
                output.addfile(item)
            elif filename.is_file():
                item.size = filename.stat().st_size
                item.mode = 0o755 if executable(filename) else 0o644
                with filename.open('rb') as incoming:
                    output.addfile(item, incoming)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for name in ('stage', 'target', 'version', 'output'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--electron')
    parser.add_argument('--terminal', action='store_true')
    args = parser.parse_args()
    stage = Path(args.stage).resolve()
    if args.terminal:
        if args.target.startswith('win32-'):
            windows_terminal_bundle(stage, args.output)
        elif args.target.startswith(('linux-', 'darwin-')):
            terminal_bundle(stage, args.output)
        else:
            parser.error('Terminal tar requires a Linux/macOS target')
    elif not args.electron:
        parser.error('--electron is required for desktop bundles')
    elif args.target.startswith('darwin-'):
        mac_bundle(args.electron, stage, args.version, args.output)
    elif args.target.startswith('linux-'):
        linux_bundle(args.electron, stage, args.version, args.output)
    else:
        raise ValueError('Unsupported portable target')
