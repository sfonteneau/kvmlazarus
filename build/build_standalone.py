#!/usr/bin/env python3
"""Build one MeshKVM executable per application, with no private shared modules.

No downloads, no run-time extraction, no global -static. Native archives must
match the selected FPC target (--arch x86/x64 on Windows). Optional system FFmpeg/GIO/PipeWire remain dynamic
on Linux; the default X11/JPEG profile does not need those libraries.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import struct
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

class BuildError(RuntimeError):
    pass

def run(argv: list[str | Path], *, capture: bool = False, cwd: Path | None = None) -> str:
    args = [str(a) for a in argv]
    display = subprocess.list2cmdline(args) if os.name == 'nt' else shlex.join(args)
    print('+ ' + display, flush=True)
    env = os.environ.copy()
    env['LC_ALL'] = 'C'
    p = subprocess.run(args, cwd=cwd or ROOT, text=True, errors='replace', env=env,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None)
    if p.returncode:
        raise BuildError(f'Command failed ({p.returncode}): {shlex.join(args)}\n{p.stdout or ""}')
    return (p.stdout or '').strip()

def tool(name: str) -> str:
    p = shutil.which(name)
    if not p:
        raise BuildError(f'Outil absent: {name}. Installer les outils de compilation, pas seulement les runtimes.')
    return str(Path(p).absolute())

def host_target(arch: str = 'native') -> tuple[str, str]:
    """Select the target, not the Python process bitness.

    Windows permits an explicit x86 build on an x64 host. This does not
    install a cross compiler or make a 64-bit GCC produce 32-bit objects.
    Non-Windows builds remain native to avoid changing their SDK policy.
    """
    if arch not in ('native', 'x86', 'x64'):
        raise BuildError('Architecture inconnue: ' + arch)
    system = platform.system()
    machine = platform.machine().lower()
    if system == 'Windows':
        # A 32-bit Python process can run on a 64-bit Windows installation.
        machine = os.environ.get('PROCESSOR_ARCHITEW6432', machine).lower()
    host_cpu = {'amd64':'x86_64', 'x86_64':'x86_64', 'x86':'i386',
                'i386':'i386', 'i486':'i386', 'i586':'i386', 'i686':'i386',
                'arm64':'aarch64', 'aarch64':'aarch64'}.get(machine)
    cpu = {'x86':'i386', 'x64':'x86_64'}.get(arch, host_cpu)
    if system == 'Windows':
        if host_cpu not in ('i386', 'x86_64') or cpu not in ('i386', 'x86_64'):
            raise BuildError('Windows: seules les cibles --arch x86 et --arch x64 sont gerees.')
        if host_cpu == 'i386' and cpu == 'x86_64':
            raise BuildError('Les sondes x64 exigent un Windows 64 bits; aucun test natif ne sera saute.')
        return cpu, 'win32' if cpu == 'i386' else 'win64'
    os_name = {'Linux':'linux', 'Darwin':'darwin'}.get(system)
    if not os_name or host_cpu not in ('x86_64', 'aarch64') or cpu != host_cpu:
        raise BuildError('Linux/macOS: compilation native x86_64/aarch64 uniquement. --arch x86 vise Windows.')
    return cpu, os_name


def is_windows(os_name: str) -> bool:
    return os_name in ('win32', 'win64')


def fpc_target_flags(cpu: str, os_name: str) -> list[str]:
    return ['-P' + cpu, '-T' + os_name]


def check_fpc_target(fpc: str, cpu: str, os_name: str) -> None:
    flags = fpc_target_flags(cpu, os_name)
    try:
        fc = run([fpc, *flags, '-iTP'], capture=True).splitlines()[-1].strip()
        fo = run([fpc, *flags, '-iTO'], capture=True).splitlines()[-1].strip()
    except (BuildError, IndexError) as exc:
        raise BuildError(
            f'FPC ne peut pas cibler {cpu}-{os_name}. --arch ne fournit pas les compilateurs. '
            'Installer le compilateur et les unites de cette cible, ou choisir son fpc.exe '
            'avec --fpc. Detail: ' + str(exc)) from exc
    if (fc, fo) != (cpu, os_name):
        raise BuildError(f'FPC annonce {fc}-{fo}, cible demandee {cpu}-{os_name}. '
                         'Choisir le bon --fpc; aucun changement silencieux de cible.')


def compiler_prefix(cc: str) -> str:
    # i686-w64-mingw32-gcc.exe -> i686-w64-mingw32- ; gcc.exe -> empty.
    stem = Path(cc).stem
    return stem[:-3] if stem.endswith('gcc') else ''


def select_c_tool(name: str, explicit: str | None, bin_dir: Path | None,
                  cc: str | None = None, *, cpu: str = '') -> str:
    """Prefer the selected SDK over an unrelated Strawberry/MSYS installation."""
    if explicit:
        return tool(explicit)
    directory = bin_dir.resolve() if bin_dir else (Path(cc).parent if cc else None)
    if directory:
        if not directory.is_dir():
            raise BuildError('Dossier de toolchain introuvable: ' + str(directory))
        prefix = compiler_prefix(cc) if cc else (
            'i686-w64-mingw32-' if cpu == 'i386' else 'x86_64-w64-mingw32-')
        for candidate in dict.fromkeys([prefix + name, name]):
            for suffix in ('.exe', ''):
                path = directory / (candidate + suffix)
                if path.is_file():
                    return tool(str(path))
        # For an explicit --toolchain-bin, never quietly fall back to PATH.
        if bin_dir:
            raise BuildError(f'{name} introuvable dans {directory}. Choisir une toolchain MinGW complete.')
    if name == 'gcc' and cpu in ('i386', 'x86_64'):
        prefixed = ('i686' if cpu == 'i386' else 'x86_64') + '-w64-mingw32-gcc'
        if shutil.which(prefixed):
            return tool(prefixed)
    return tool(name)


def check_windows_linker(ld: str, cpu: str) -> None:
    """Check the DEFAULT PE output architecture, not the ld.exe file name.

    MSYS2 MINGW32 commonly ships a prefixed GCC but an unprefixed ld.exe.
    Both are valid when ld defaults to the same target as GCC/FPC.
    """
    output = run([ld, '--verbose'], capture=True)
    match = re.search(r'\bOUTPUT_FORMAT\s*\(\s*"?([a-zA-Z0-9_.+-]+)', output)
    fmt = match.group(1) if match else None
    expected = {'i386': 'pei-i386', 'x86_64': 'pei-x86-64'}[cpu]
    if fmt != expected:
        raise BuildError(
            f'Linker incompatible avec {cpu}-Windows: {ld} '
            f'annonce {fmt or "un format inconnu"}, attendu {expected}. '
            'Choisir un --toolchain-bin de la bonne architecture.')


def windows_linker_flags(cc: str, ld: str) -> list[str]:
    """Tell FPC to run the linker name that ACTUALLY exists in MinGW."""
    prefix = compiler_prefix(cc)
    ld_stem = Path(ld).stem
    if ld_stem == prefix + 'ld':
        chosen_prefix = prefix
    elif ld_stem == 'ld':
        chosen_prefix = ''
    else:
        raise BuildError('Nom de linker non pris en charge par FPC: ' + ld)
    # -XP without an argument resets a cross prefix from fpc.cfg.
    # -FD points at the selected MinGW directory, not Strawberry/PATH.
    return ['-Xe', '-FD' + str(Path(ld).parent), '-XP' + chosen_prefix]


def option_text(options: list[str]) -> str:
    # Lazarus parses these options, not a POSIX shell. Keep Windows paths
    # containing spaces as a single option. Reject an embedded quote/newline.
    result = []
    for option in options:
        if any(c in option for c in ('"', '\n', '\r')):
            raise BuildError('Option non representable dans le projet Lazarus: ' + repr(option))
        result.append('"' + option + '"' if any(c.isspace() for c in option) else option)
    return ' '.join(result)


def feature_include(cpu: str, os_name: str, defines: list[str]) -> str:
    cpu_macro = {'i386':'CPU386', 'x86_64':'CPUX86_64', 'aarch64':'CPUAARCH64'}[cpu]
    os_macro = {'linux':'LINUX', 'darwin':'DARWIN', 'win32':'WIN32', 'win64':'WIN64'}[os_name]
    return ('{ Generated for ' + cpu + '-' + os_name + '. Do not copy between architectures. }\n'
            '{$IFNDEF ' + cpu_macro + '}{$FATAL Wrong CPU for standalone archives}{$ENDIF}\n'
            '{$IFNDEF ' + os_macro + '}{$FATAL Wrong OS for standalone archives}{$ENDIF}\n' +
            ''.join('{$DEFINE ' + d + '}\n' for d in defines))


def check_pe_target(path: Path, cpu: str) -> None:
    """Check the PE machine without executing a possibly wrong-CPU file."""
    expected = {'i386':0x014c, 'x86_64':0x8664}[cpu]
    with path.open('rb') as f:
        head = f.read(64)
        if len(head) != 64 or head[:2] != b'MZ':
            raise BuildError('Executable PE invalide: ' + str(path))
        offset = struct.unpack_from('<I', head, 60)[0]
        if offset < 64 or offset > path.stat().st_size - 6:
            raise BuildError('Entete PE hors limites: ' + str(path))
        f.seek(offset)
        pe = f.read(6)
    if pe[:4] != b'PE\x00\x00':
        raise BuildError('Signature PE invalide: ' + str(path))
    actual = struct.unpack_from('<H', pe, 4)[0]
    if actual != expected:
        raise BuildError(f'{path}: PE machine 0x{actual:04x}, attendu {cpu} (0x{expected:04x})')


def check_windows_archive(path: Path, objdump: str, cpu: str) -> None:
    output = run([objdump, '-f', path], capture=True)
    formats = re.findall(r'file format\s+(\S+)', output)
    allowed = {'i386':{'pe-i386', 'pe-bigobj-i386'},
               'x86_64':{'pe-x86-64', 'pe-bigobj-x86-64'}}[cpu]
    if not formats or any(fmt not in allowed for fmt in formats):
        raise BuildError(f'{path}: objets {sorted(set(formats))}, attendu {cpu} Windows. '
                         'Fournir/recompiler libturbojpeg.a pour la cible choisie.')


def audit_binary(path: Path, cpu: str, os_name: str, objdump: str | None = None,
                 report: Path | None = None) -> None:
    options: list[str | Path] = []
    if is_windows(os_name):
        check_pe_target(path, cpu)
        if objdump:
            options += ['--objdump', objdump]
    if report:
        options += ['--report', report]
    run([sys.executable, ROOT/'tools/audit_standalone.py', path, *options])

def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')

def native_archive(cc: str, ar: str, output: Path, source: Path, flags: list[str]) -> None:
    obj = output.with_suffix('.o')
    run([cc, *flags, '-DKVM_STATIC_BUILD', '-c', source, '-o', obj])
    output.unlink(missing_ok=True)
    run([ar, 'rcs', output, obj])

def symbols(nm: str, path: Path) -> str:
    # llvm-nm and GNU nm both support -g; declarations in an import archive
    # are not proof of static implementation. Check actual T/t definitions.
    return run([nm, '-g', path], capture=True)

def assert_archive(path: Path, nm: str, names: list[str]) -> None:
    if not path.is_file():
        raise BuildError(f'Archive statique introuvable: {path}')
    with path.open('rb') as f:
        if f.read(8) != b'!<arch>\n':
            raise BuildError(f'{path}: archive ar complete requise (.a), pas DLL/.so ni archive thin.')
    table = symbols(nm, path)
    for name in names:
        if not re.search(r'\b[Tt]\s+_?' + re.escape(name) + r'\s*$', table, re.M):
            raise BuildError(f'{path}: definition de {name} absente (mauvais SDK ou bibliotheque d import).')
    if any(re.search(r'\b_?__imp_' + re.escape(name) + r'\s*$', table, re.M) for name in names):
        raise BuildError(f'{path}: archive d import DLL, pas une implementation statique.')

def system_links(tokens: list[str], *, extra: list[str] | None = None) -> tuple[str, list[str]]:
    """Only accept an explicit, small pkg-config grammar; never silently drop flags."""
    directives: list[str] = []
    search: list[str] = []
    i = 0
    for t in extra or []:
        directives.append('{$LINKLIB ' + t + '}')
    while i < len(tokens):
        arg = tokens[i]
        if arg.startswith('-l') and re.fullmatch(r'[A-Za-z0-9_.+-]+', arg[2:]):
            directives.append('{$LINKLIB ' + arg[2:] + '}')
        elif arg.startswith('-L') and len(arg) > 2:
            search.append(arg[2:])
        elif arg == '-pthread':
            directives.append('{$LINKLIB pthread}')
        elif arg == '-framework' and i + 1 < len(tokens):
            i += 1
            name = tokens[i]
            if not re.fullmatch(r'[A-Za-z0-9_]+', name):
                raise BuildError('Nom framework invalide')
            directives.append('{$LINKFRAMEWORK ' + name + '}')
        else:
            raise BuildError(f'Option pkg-config non prise en charge: {arg!r}. Ne pas l ignorer; adapter le fichier de liaison pour ce SDK.')
        i += 1
    return '\n'.join(dict.fromkeys(directives)) + '\n', list(dict.fromkeys(search))

def pkg(name: str, which: str) -> list[str]:
    return shlex.split(run([tool('pkg-config'), which, *name.split()], capture=True))

def check_c_target(cc: str, cpu: str, os_name: str) -> None:
    triple = run([cc, '-dumpmachine'], capture=True).lower()
    arch_ok = ((cpu == 'i386' and re.match(r'i[3-6]86(?:-|$)', triple) is not None) or
               (cpu == 'x86_64' and triple.startswith(('x86_64-', 'amd64-'))) or
               (cpu == 'aarch64' and triple.startswith(('aarch64-', 'arm64-'))))
    os_ok = (('mingw' in triple or 'windows' in triple) if is_windows(os_name) else
             ('darwin' in triple or 'apple' in triple) if os_name == 'darwin' else
             'linux' in triple)
    if not arch_ok or not os_ok:
        raise BuildError(f'Cible C incompatible: {cc} annonce {triple}, demande {cpu}-{os_name}. '
                         'Choisir --toolchain-bin (ou --cc) pour cette architecture. '
                         'Aucun -m32/-m64 implicite et aucun choix Strawberry automatique force.')
    if is_windows(os_name) and 'mingw' not in triple:
        raise BuildError('Windows statique: utiliser MinGW-w64 (meme architecture/CRT), pas MSVC/clang-cl.')

def make_projects(target: str, search: list[str], os_name: str,
                  *, fpc: str | None = None, linker_flags: list[str] | None = None) -> list[Path]:
    projects = []
    cpu = target.rsplit('-', 1)[0]
    for role, app in [('server','MeshKVMServer'), ('client','MeshKVMClient')]:
        tree = ET.parse(ROOT / role / (app + '.lpi'))
        root = tree.getroot()
        def set_value(path: str, val: str) -> None:
            element = root
            for name in path.split('/'):
                child = element.find(name)
                if child is None:
                    child = ET.SubElement(element, name)
                element = child
            element.set('Value', val)
        modes = root.find('ProjectOptions/BuildModes')
        assert modes is not None
        modes.clear()
        ET.SubElement(modes, 'Item', Name='Standalone', Default='True')
        native = '../native/static/' + target
        set_value('ProjectOptions/General/UseAppBundle', 'False')
        set_value('CompilerOptions/SearchPaths/IncludeFiles', '../shared;' + native)
        set_value('CompilerOptions/SearchPaths/Libraries', ';'.join([native, *search]))
        set_value('CompilerOptions/SearchPaths/UnitOutputDirectory', 'lib/standalone/' + target)
        suffix = '.exe' if is_windows(os_name) else ''
        set_value('CompilerOptions/Target/Filename', '../dist/' + target + '/' + app + suffix)
        set_value('CompilerOptions/CodeGeneration/TargetCPU', cpu)
        set_value('CompilerOptions/CodeGeneration/TargetOS', os_name)
        if fpc:
            set_value('CompilerOptions/Other/CompilerPath', fpc)
        options = '-dKVM_STANDALONE'
        if os_name == 'darwin':
            options += ' -WM12.3'
        if is_windows(os_name):
            options += ' ' + option_text(linker_flags or ['-Xe'])
        set_value('CompilerOptions/Other/CustomOptions', options)
        arch_suffix = ('_x86' if cpu == 'i386' else '_x64') if is_windows(os_name) else ''
        project = ROOT / role / (app + '_Standalone' + arch_suffix + '.lpi')
        ET.indent(tree, space='  ')
        tree.write(project, encoding='utf-8', xml_declaration=True)
        projects.append(project)
    return projects

def stage_runtime(cc: str, stage: Path, library: str, output_name: str,
                  *, optional: bool = False) -> str | None:
    name = 'lib' + library + '.a'
    path = Path(run([cc, '-print-file-name=' + name], capture=True))
    if not path.is_file():
        if optional:
            return None
        raise BuildError(f'Runtime statique manquant: {name} ({cc})')
    destination = stage / ('lib' + output_name + '.a')
    shutil.copy2(path, destination)
    return output_name

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arch', choices=['native','x86','x64'], default='native',
                        help='Windows: x86=i386-win32, x64=x86_64-win64; native uses host architecture')
    parser.add_argument('--toolchain-bin', type=Path,
                        help='MinGW bin folder for the selected target; takes priority over unrelated PATH tools')
    parser.add_argument('--check-toolchain', action='store_true',
                        help='Check FPC/C target and tool selection only; no build or download')
    parser.add_argument('--only', choices=['both','server','client'], default='both')
    parser.add_argument('--with-portal', action='store_true', help='Linux: integrate portal shim; use system GIO/PipeWire')
    parser.add_argument('--with-codec', action='store_true', help='Linux/macOS: integrate FFmpeg shim; use system FFmpeg libraries')
    parser.add_argument('--with-dxgi', action='store_true', help='Windows x86/x64: integrate DXGI and MinGW C++ runtimes (experimental)')
    parser.add_argument('--turbojpeg-archive', type=Path, default=os.environ.get('TURBOJPEG_STATIC'))
    parser.add_argument('--turbojpeg-source', type=Path, help='Local libjpeg-turbo source tree to compile with SIMD')
    parser.add_argument('--prepare-only', action='store_true', help='Build native archives and generate standalone .lpi, without invoking Lazarus')
    parser.add_argument('--skip-smoke', action='store_true', help='Do not compile/run the Pascal native-link smoke test')
    parser.add_argument('--fpc', default=os.environ.get('FPC'), help='FPC driver (fpc.exe); the selected target compiler and RTL must be installed')
    parser.add_argument('--lazbuild', default=os.environ.get('LAZBUILD','lazbuild'))
    parser.add_argument('--cc', default=None)
    parser.add_argument('--cxx', default=None)
    parser.add_argument('--ar', default=None)
    parser.add_argument('--nm', default=None)
    parser.add_argument('--objdump', default=None, help='PE/archive inspector from the selected MinGW SDK')
    parser.add_argument('--widgetset', default=None)
    parser.add_argument('--mormot-dir', type=Path, default=os.environ.get('MORMOT2_DIR'))
    args = parser.parse_args(argv)
    cpu, os_name = host_target(args.arch)
    print(f'Cible demandee: {cpu}-{os_name} (--arch {args.arch})', flush=True)
    target = cpu + '-' + os_name
    if args.with_portal and os_name != 'linux':
        raise BuildError('--with-portal exige Linux')
    if args.with_dxgi and not is_windows(os_name):
        raise BuildError('--with-dxgi exige Windows x86/x64')
    if args.with_codec and is_windows(os_name):
        raise BuildError('Le profil autonome Windows livre est JPEG. FFmpeg Windows statique n est pas automatise: ne pas masquer ses DLL comme des bibliotheques systeme.')
    if args.only == 'client' and (args.with_portal or args.with_dxgi):
        raise BuildError('Portail/DXGI sont des options serveur, pas client')
    if args.turbojpeg_archive and args.turbojpeg_source:
        raise BuildError('Choisir --turbojpeg-archive OU --turbojpeg-source')
    # An explicit SDK folder overrides ambient CC/AR/etc. Individual CLI
    # switches override the folder. Without a folder, keep environment support.
    def selected(value: str | None, variable: str) -> str | None:
        return value or (os.environ.get(variable) if not args.toolchain_bin else None)
    cc = select_c_tool('gcc' if is_windows(os_name) else 'cc', selected(args.cc, 'CC'),
                       args.toolchain_bin, cpu=cpu)
    check_c_target(cc, cpu, os_name)
    ar = select_c_tool('ar', selected(args.ar, 'AR'), args.toolchain_bin, cc, cpu=cpu)
    nm = select_c_tool('nm', selected(args.nm, 'NM'), args.toolchain_bin, cc, cpu=cpu)
    objdump = None
    linker_flags: list[str] = []
    if is_windows(os_name):
        objdump = select_c_tool('objdump', selected(args.objdump, 'OBJDUMP'), args.toolchain_bin, cc, cpu=cpu)
        ld = select_c_tool('ld', None, args.toolchain_bin, cc, cpu=cpu)
        check_windows_linker(ld, cpu)
        linker_flags = windows_linker_flags(cc, ld)
    fpc = None
    laz = None
    fpc_name = args.fpc or 'fpc'
    if not args.prepare_only or args.check_toolchain or args.fpc or shutil.which(fpc_name):
        fpc = tool(fpc_name)
        check_fpc_target(fpc, cpu, os_name)
    if args.check_toolchain:
        print('FPC, GCC et linker PE annoncent la cible demandee; ar/nm/objdump trouves.')
        print('Aucun lien executable effectue: RTL/LCL, TurboJPEG et mORMot2 restent a valider au build.')
        return 0
    if not args.prepare_only:
        laz = tool(args.lazbuild)
    stage = ROOT / 'native/static' / target
    stage.mkdir(parents=True, exist_ok=True)
    # Removing the generated feature include FIRST prevents use of stale
    # features if a later native build fails.
    (stage / 'kvm_standalone_features.inc').unlink(missing_ok=True)
    search: list[str] = []
    defines: list[str] = []
    cflags = ['-std=c11','-O2','-Wall','-Wextra','-Wno-misleading-indentation']
    if not is_windows(os_name):
        cflags += ['-fPIC']
    if os_name == 'darwin':
        cflags += ['-arch','arm64' if cpu=='aarch64' else 'x86_64','-mmacosx-version-min=12.3']
    if args.turbojpeg_source:
        source = args.turbojpeg_source.resolve()
        if not (source/'CMakeLists.txt').is_file():
            raise BuildError('Source libjpeg-turbo incomplete')
        cmake = tool('cmake')
        build = stage / 'jpeg-build'
        flags = ['-DENABLE_SHARED=OFF','-DENABLE_STATIC=ON','-DWITH_TURBOJPEG=ON',
                 '-DWITH_JAVA=OFF','-DWITH_SIMD=ON','-DREQUIRE_SIMD=ON',
                 '-DWITH_SYSTEM_SPNG=OFF','-DWITH_SYSTEM_ZLIB=OFF','-DCMAKE_BUILD_TYPE=Release','-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
                 '-DCMAKE_C_COMPILER=' + Path(cc).as_posix(), '-DCMAKE_AR=' + Path(ar).as_posix()]
        if cpu in ('i386', 'x86_64'):
            flags += ['-DCMAKE_ASM_NASM_COMPILER=' + Path(tool('nasm')).as_posix()]
        if is_windows(os_name):
            flags += ['-G','MinGW Makefiles',
                      '-DCMAKE_ASM_NASM_OBJECT_FORMAT=' + ('win32' if cpu == 'i386' else 'win64')]
            # Use the same SDK for resource compilation; absolute CMake paths
            # are normalized for Windows instead of interpreted as escapes.
            rc = select_c_tool('windres', None, args.toolchain_bin, cc, cpu=cpu)
            flags += ['-DCMAKE_RC_COMPILER=' + Path(rc).as_posix()]
            make = select_c_tool('mingw32-make', None, args.toolchain_bin, cc, cpu=cpu)
            flags += ['-DCMAKE_MAKE_PROGRAM=' + Path(make).as_posix()]
        elif os_name == 'darwin':
            flags += ['-DCMAKE_OSX_ARCHITECTURES=' + ('arm64' if cpu=='aarch64' else 'x86_64'),
                      '-DCMAKE_OSX_DEPLOYMENT_TARGET=12.3']
        run([cmake,'-S',source,'-B',build,*flags])
        run([cmake,'--build',build,'--config','Release','--target','turbojpeg-static','--parallel',str(min(os.cpu_count() or 2,8))])
        found = list(build.rglob('libturbojpeg.a'))
        if len(found) != 1:
            raise BuildError(f'libturbojpeg.a attendu, trouves: {found}')
        jpeg = found[0]
    elif args.turbojpeg_archive:
        jpeg = args.turbojpeg_archive.resolve()
    else:
        jpeg = Path(run([cc,'-print-file-name=libturbojpeg.a'],capture=True))
        if not jpeg.is_file() and shutil.which('pkg-config'):
            p = subprocess.run(['pkg-config','--variable=libdir','libturbojpeg'],
                               text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            candidate = Path(p.stdout.strip()) / 'libturbojpeg.a'
            if p.returncode==0 and candidate.is_file():
                jpeg=candidate
    assert_archive(jpeg,nm,['tjInitCompress','tjInitDecompress','tjCompress2',
                           'tjDecompress2','tjDecompressHeader3','tjBufSize','tjDestroy','tjGetErrorStr2'])
    if is_windows(os_name):
        check_windows_archive(jpeg, objdump, cpu)
    destination = stage / 'libkvm_turbojpeg.a'
    if jpeg.resolve() != destination.resolve():
        shutil.copy2(jpeg,destination)
    turbo_links = ['{$LINKLIB c}', '{$LINKLIB m}'] if not is_windows(os_name) else ['{$LINKLIB msvcrt}']
    if is_windows(os_name):
        # FPC's Pascal-only runtime does not supply the compiler's native C
        # helpers. Stage real static archives, never *.dll.a import archives.
        runtime_links=[]
        # Search the selected MinGW SDK's system import archives, not an
        # unrelated 32/64-bit directory from the IDE configuration.
        for lib in ('msvcrt', 'kernel32'):
            lib_path = Path(run([cc, '-print-file-name=lib' + lib + '.a'], capture=True))
            if not lib_path.is_file():
                raise BuildError('Bibliotheque systeme MinGW introuvable: ' + str(lib_path))
            search.append(str(lib_path.resolve().parent))
        for lib in ['mingw32','mingwex','gcc']:
            name = stage_runtime(cc,stage,lib,'kvm_' + lib)
            runtime_links.append('{$LINKLIB ' + name + '}')
        turbo_links=runtime_links+turbo_links
    write(stage/'kvm_turbojpeg_link.inc','\n'.join(turbo_links)+'\n')
    # A real native executable catches wrong CPU/CRT and missing static
    # dependencies before the Pascal build. It runs from a clean directory.
    import tempfile
    probe=stage/('probe_jpeg.exe' if is_windows(os_name) else 'probe_jpeg')
    native_link=['-static-libgcc'] if is_windows(os_name) else ['-lm']
    run([cc, *cflags, ROOT/'tests/test_static_turbojpeg.c', destination,
         *native_link, '-o', probe])
    audit_binary(probe, cpu, os_name, objdump)
    with tempfile.TemporaryDirectory(prefix='meshkvm-native-link-') as clean:
        clean_dir=Path(clean)
        isolated=clean_dir/probe.name
        shutil.copy2(probe,isolated)
        run([isolated],cwd=clean_dir)
    if args.only != 'client':
        if os_name == 'linux':
            native_archive(cc,ar,stage/'libkvm_session.a',ROOT/'native/session/kvm_session_linux.c',cflags)
            assert_archive(stage/'libkvm_session.a',nm,['meshkvm_session_open_ex','meshkvm_session_poll'])
        elif os_name == 'darwin':
            native_archive(cc,ar,stage/'libkvm_sck.a',ROOT/'native/macos/kvm_sck.m',
                ['-O2','-fobjc-arc','-fblocks','-Wall','-Wextra','-Wno-unused-parameter',
                 '-arch','arm64' if cpu=='aarch64' else 'x86_64','-mmacosx-version-min=12.3'])
            assert_archive(stage/'libkvm_sck.a',nm,['kvm_sck_open','kvm_sck_session'])
        elif args.with_dxgi:
            cxx=select_c_tool('g++', selected(args.cxx, 'CXX'), args.toolchain_bin, cc, cpu=cpu)
            check_c_target(cxx,cpu,os_name)
            native_archive(cxx,ar,stage/'libkvm_dxgi.a',ROOT/'native/windows/kvm_dxgi.cpp',
                           ['-std=c++17','-O2','-Wall','-Wextra'])
            assert_archive(stage/'libkvm_dxgi.a',nm,['kvm_dxgi_open','kvm_dxgi_read'])
            links=[]; runtime_archives=[]
            for lib in ['stdc++','gcc_eh','gcc','mingwex','mingw32','winpthread']:
                name=stage_runtime(cxx,stage,lib,'kvm_' + re.sub('[^a-zA-Z0-9_]','_',lib),optional=lib=='winpthread')
                if name:
                    links.append('{$LINKLIB ' + name + '}')
                    runtime_archives.append(stage/('lib'+name+'.a'))
            links += ['{$LINKLIB ' + lib + '}' for lib in ['d3d11','dxgi','dxguid','uuid','user32','gdi32','kernel32','msvcrt','advapi32']]
            write(stage/'kvm_dxgi_link.inc','\n'.join(links)+'\n')
            # Verify the SAME archive/runtime set with a real C++ executable
            # before leaving the harder mixed Pascal/C++ link to lazbuild.
            probe=stage/'probe_dxgi.cpp'
            write(probe,'extern "C" int kvm_dxgi_abi();\nint main(){return kvm_dxgi_abi()!=1;}\n')
            run([cxx,'-static-libgcc','-static-libstdc++',probe,stage/'libkvm_dxgi.a',
                 '-Wl,--start-group',*runtime_archives,'-Wl,--end-group',
                 '-ld3d11','-ldxgi','-ldxguid','-luuid','-luser32','-lgdi32','-o',stage/'probe_dxgi.exe'])
            audit_binary(stage/'probe_dxgi.exe', cpu, os_name, objdump)
            run([stage/'probe_dxgi.exe'])
            defines += ['KVM_STATIC_DXGI']
    if args.with_portal:
        modules='gio-2.0 gio-unix-2.0 libpipewire-0.3'
        native_archive(cc,ar,stage/'libkvm_portal.a',ROOT/'native/linux/kvm_portal.c',cflags+pkg(modules,'--cflags'))
        text,dirs=system_links(pkg(modules,'--libs'),extra=['c','pthread'])
        write(stage/'kvm_portal_link.inc',text); search+=dirs
        assert_archive(stage/'libkvm_portal.a',nm,['kvm_portal_abi','kvm_portal_open','kvm_portal_read'])
        defines+=['KVM_STATIC_PORTAL']
    if args.with_codec:
        modules='libavcodec libavutil libswscale'
        native_archive(cc,ar,stage/'libkvm_codec.a',ROOT/'native/codec/kvm_codec.c',cflags+pkg(modules,'--cflags'))
        text,dirs=system_links(pkg(modules,'--libs'),extra=['c','m'])
        write(stage/'kvm_codec_link.inc',text); search+=dirs
        assert_archive(stage/'libkvm_codec.a',nm,['meshkvm_codec_abi','meshkvm_encoder_open','meshkvm_decoder_open'])
        defines+=['KVM_STATIC_CODEC']
    features = feature_include(cpu, os_name, defines)
    write(stage/'kvm_standalone_features.inc',features)
    search=list(dict.fromkeys(search))
    projects=make_projects(target,search,os_name,fpc=fpc,linker_flags=linker_flags)
    output=ROOT/'dist'/target
    output.mkdir(parents=True,exist_ok=True)
    manifest={'target':target,'requested_arch':args.arch,'fpc':fpc,'cc':cc,
              'ar':ar,'nm':nm,'objdump':objdump,'features':defines,'base':'TurboJPEG static; system libraries dynamic',
              'source_turbojpeg_archive':str(jpeg),'archives':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in stage.glob('*.a')},
              'complete_applications_built':False}
    write(stage/'build-manifest.json',json.dumps(manifest,indent=2)+'\n')
    if args.prepare_only:
        print('Archives preparees; projets: '+', '.join(str(p) for p in projects))
        print('Aucune application Pascal compilee avec --prepare-only.')
        return 0
    if not args.skip_smoke:
        units=stage/'test-units'; units.mkdir(exist_ok=True)
        executable=stage/('test_standalone_link.exe' if is_windows(os_name) else 'test_standalone_link')
        opts=[*fpc_target_flags(cpu, os_name),'-B','-O2','-dKVM_STANDALONE','-Fu'+str(ROOT/'shared'),'-Fu'+str(ROOT/'server'),
              '-Fu'+str(ROOT/'client'),'-Fi'+str(ROOT/'shared'),'-Fi'+str(stage),
              '-Fl'+str(stage),'-FU'+str(units),'-o'+str(executable)]
        # Skip the server-only session ABI check for a client-only preparation.
        if args.only=='client': opts+=['-dKVM_TEST_CLIENT_ONLY']
        if os_name=='darwin': opts+=['-WM12.3']
        if is_windows(os_name): opts+=linker_flags
        opts += ['-Fl' + path for path in search]
        run([fpc,*opts,ROOT/'tests/test_standalone_link.lpr'])
        audit_binary(executable, cpu, os_name, objdump)
        run([executable])
    if args.mormot_dir:
        package=args.mormot_dir.resolve()/'packages/lazarus/mormot2.lpk'
        if not package.is_file(): raise BuildError('Paquet mORMot2 introuvable: '+str(package))
        run([laz,'--add-package-link='+str(package)])
    # Force rebuilding after feature changes; no stale standalone .ppu reuse.
    for role,app,project in zip(['server','client'],['MeshKVMServer','MeshKVMClient'],projects):
        if args.only not in ['both',role]: continue
        exe=output/(app+('.exe' if is_windows(os_name) else ''))
        exe.unlink(missing_ok=True)
        opts=['--build-all','--compiler='+fpc,'--cpu='+cpu,'--os='+os_name]
        if role=='client':
            widgetset=args.widgetset or ('cocoa' if os_name=='darwin' else None)
            if widgetset: opts+=['--widgetset='+widgetset]
        run([laz,*opts,project])
        if not exe.is_file(): raise BuildError('Executable non produit: '+str(exe))
        audit_binary(exe, cpu, os_name, objdump, output/(app+'-dependencies.txt'))
    manifest['complete_applications_built']=True
    manifest['built_roles']=args.only
    write(stage/'build-manifest.json',json.dumps(manifest,indent=2)+'\n')
    print('\nTermine: executables dans '+str(output))
    print('Copier seulement le serveur OU le client necessaire; conserver les notices tierces de distribution.')
    return 0

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (BuildError, OSError) as exc:
        print('ERREUR: '+str(exc), file=sys.stderr)
        sys.exit(2)
