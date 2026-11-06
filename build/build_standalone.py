#!/usr/bin/env python3
"""Build one MeshKVM executable per application, with no private shared modules.

No downloads, no run-time extraction, no global -static. Native archives must
match the host/FPC target. Optional system FFmpeg/GIO/PipeWire remain dynamic
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
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]

class BuildError(RuntimeError):
    pass

def run(argv: list[str | Path], *, capture: bool = False, cwd: Path | None = None) -> str:
    args = [str(a) for a in argv]
    print('+ ' + shlex.join(args), flush=True)
    p = subprocess.run(args, cwd=cwd or ROOT, text=True,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.STDOUT if capture else None)
    if p.returncode:
        raise BuildError(f'Command failed ({p.returncode}): {shlex.join(args)}\n{p.stdout or ""}')
    return (p.stdout or '').strip()

def tool(name: str) -> str:
    p = shutil.which(name)
    if not p:
        raise BuildError(f'Outil absent: {name}. Installer les outils de compilation, pas seulement les runtimes.')
    return p

def host_target() -> tuple[str, str]:
    os_name = {'Linux':'linux', 'Darwin':'darwin', 'Windows':'win64'}.get(platform.system())
    cpu = {'amd64':'x86_64', 'x86_64':'x86_64', 'arm64':'aarch64',
           'aarch64':'aarch64'}.get(platform.machine().lower())
    if not os_name or not cpu or (os_name == 'win64' and cpu != 'x86_64'):
        raise BuildError('Cibles natives: Linux x86_64/aarch64, macOS x86_64/aarch64, Windows x86_64. Pas de cross-compilation dans ce script.')
    return cpu, os_name

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
    arch_ok = ((cpu == 'x86_64' and ('x86_64' in triple or 'amd64' in triple)) or
               (cpu == 'aarch64' and ('aarch64' in triple or 'arm64' in triple)))
    os_ok = (('mingw' in triple or 'windows' in triple) if os_name == 'win64' else
             ('darwin' in triple or 'apple' in triple) if os_name == 'darwin' else
             'linux' in triple)
    if not arch_ok or not os_ok:
        raise BuildError(f'C/FPC incompatibles: compilateur C={triple}, cible={cpu}-{os_name}')
    if os_name == 'win64' and 'mingw' not in triple:
        raise BuildError('Windows statique: utiliser MinGW-w64 (meme architecture/CRT), pas les objets MSVC/clang-cl.')

def make_projects(target: str, search: list[str], os_name: str) -> list[Path]:
    projects = []
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
        set_value('CompilerOptions/Target/Filename', '../dist/' + target + '/' + app)
        options = '-dKVM_STANDALONE'
        if os_name == 'darwin':
            options += ' -WM12.3'
        if os_name == 'win64':
            options += ' -Xe'  # GNU ld understands MinGW C/C++ archive objects.
        set_value('CompilerOptions/Other/CustomOptions', options)
        project = ROOT / role / (app + '_Standalone.lpi')
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
    parser.add_argument('--only', choices=['both','server','client'], default='both')
    parser.add_argument('--with-portal', action='store_true', help='Linux: integrate portal shim; use system GIO/PipeWire')
    parser.add_argument('--with-codec', action='store_true', help='Linux/macOS: integrate FFmpeg shim; use system FFmpeg libraries')
    parser.add_argument('--with-dxgi', action='store_true', help='Windows x64: integrate DXGI and MinGW C++ runtimes (experimental)')
    parser.add_argument('--turbojpeg-archive', type=Path, default=os.environ.get('TURBOJPEG_STATIC'))
    parser.add_argument('--turbojpeg-source', type=Path, help='Local libjpeg-turbo source tree to compile with SIMD')
    parser.add_argument('--prepare-only', action='store_true', help='Build native archives and generate standalone .lpi, without invoking Lazarus')
    parser.add_argument('--skip-smoke', action='store_true', help='Do not compile/run the Pascal native-link smoke test')
    parser.add_argument('--fpc', default=os.environ.get('FPC','fpc'))
    parser.add_argument('--lazbuild', default=os.environ.get('LAZBUILD','lazbuild'))
    parser.add_argument('--cc', default=os.environ.get('CC','gcc' if os.name=='nt' else 'cc'))
    parser.add_argument('--cxx', default=os.environ.get('CXX','g++' if os.name=='nt' else 'c++'))
    parser.add_argument('--ar', default=os.environ.get('AR','ar'))
    parser.add_argument('--nm', default=os.environ.get('NM','nm'))
    parser.add_argument('--widgetset', default=None)
    parser.add_argument('--mormot-dir', type=Path, default=os.environ.get('MORMOT2_DIR'))
    args = parser.parse_args(argv)
    cpu, os_name = host_target()
    target = cpu + '-' + os_name
    if args.with_portal and os_name != 'linux':
        raise BuildError('--with-portal exige Linux')
    if args.with_dxgi and os_name != 'win64':
        raise BuildError('--with-dxgi exige Windows x64')
    if args.with_codec and os_name == 'win64':
        raise BuildError('Le profil autonome Windows livre est JPEG. FFmpeg Windows statique n est pas automatise: ne pas masquer ses DLL comme des bibliotheques systeme.')
    if args.only == 'client' and (args.with_portal or args.with_dxgi):
        raise BuildError('Portail/DXGI sont des options serveur, pas client')
    if args.turbojpeg_archive and args.turbojpeg_source:
        raise BuildError('Choisir --turbojpeg-archive OU --turbojpeg-source')
    cc, ar, nm = tool(args.cc), tool(args.ar), tool(args.nm)
    check_c_target(cc, cpu, os_name)
    if not args.prepare_only:
        fpc, laz = tool(args.fpc), tool(args.lazbuild)
        fc = run([fpc,'-iTP'], capture=True).splitlines()[-1].strip()
        fo = run([fpc,'-iTO'], capture=True).splitlines()[-1].strip()
        if (fc,fo) != (cpu,os_name):
            raise BuildError(f'FPC cible {fc}-{fo}, C cible {target}. Utiliser le meme CPU/OS, sans cross-compilation implicite.')
    stage = ROOT / 'native/static' / target
    stage.mkdir(parents=True, exist_ok=True)
    # Removing the generated feature include FIRST prevents use of stale
    # features if a later native build fails.
    (stage / 'kvm_standalone_features.inc').unlink(missing_ok=True)
    search: list[str] = []
    defines: list[str] = []
    cflags = ['-std=c11','-O2','-Wall','-Wextra','-Wno-misleading-indentation']
    if os_name != 'win64':
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
                 '-DCMAKE_C_COMPILER=' + cc, '-DCMAKE_AR=' + ar]
        if cpu == 'x86_64':
            flags += ['-DCMAKE_ASM_NASM_COMPILER=' + tool('nasm')]
        if os_name == 'win64':
            flags += ['-G','MinGW Makefiles']
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
    destination = stage / 'libkvm_turbojpeg.a'
    if jpeg.resolve() != destination.resolve():
        shutil.copy2(jpeg,destination)
    turbo_links = ['{$LINKLIB c}', '{$LINKLIB m}'] if os_name!='win64' else ['{$LINKLIB msvcrt}']
    if os_name == 'win64':
        # FPC's Pascal-only runtime does not supply the compiler's native C
        # helpers. Stage real static archives, never *.dll.a import archives.
        runtime_links=[]
        for lib in ['mingw32','mingwex','gcc']:
            name = stage_runtime(cc,stage,lib,'kvm_' + lib)
            runtime_links.append('{$LINKLIB ' + name + '}')
        turbo_links=runtime_links+turbo_links
    write(stage/'kvm_turbojpeg_link.inc','\n'.join(turbo_links)+'\n')
    # A real native executable catches wrong CPU/CRT and missing static
    # dependencies before the Pascal build. It runs from a clean directory.
    import tempfile
    probe=stage/('probe_jpeg.exe' if os_name=='win64' else 'probe_jpeg')
    native_link=['-static-libgcc'] if os_name=='win64' else ['-lm']
    run([cc, *cflags, ROOT/'tests/test_static_turbojpeg.c', destination,
         *native_link, '-o', probe])
    run([sys.executable,ROOT/'tools/audit_standalone.py',probe])
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
            cxx=tool(args.cxx)
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
            run([sys.executable,ROOT/'tools/audit_standalone.py',stage/'probe_dxgi.exe'])
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
    features = '{ Generated for '+target+'. Do not copy between architectures. }\n'
    features += '{$IFNDEF '+cpu.upper()+'}{$FATAL Wrong CPU for standalone archives}{$ENDIF}\n'
    # FPC defines CPUX86_64/CPUAARCH64, not a free-standing architecture macro.
    features = features.replace('{$IFNDEF '+cpu.upper()+'}', '{$IFNDEF CPU'+cpu.upper()+'}')
    os_macro={'linux':'LINUX','darwin':'DARWIN','win64':'WIN64'}[os_name]
    features += '{$IFNDEF '+os_macro+'}{$FATAL Wrong OS for standalone archives}{$ENDIF}\n'
    features += ''.join('{$DEFINE '+d+'}\n' for d in defines)
    write(stage/'kvm_standalone_features.inc',features)
    search=list(dict.fromkeys(search))
    projects=make_projects(target,search,os_name)
    output=ROOT/'dist'/target
    output.mkdir(parents=True,exist_ok=True)
    manifest={'target':target,'features':defines,'base':'TurboJPEG static; system libraries dynamic',
              'source_turbojpeg_archive':str(jpeg),'archives':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in stage.glob('*.a')},
              'complete_applications_built':False}
    write(stage/'build-manifest.json',json.dumps(manifest,indent=2)+'\n')
    if args.prepare_only:
        print('Archives preparees; projets: '+', '.join(str(p) for p in projects))
        print('Aucune application Pascal compilee avec --prepare-only.')
        return 0
    if not args.skip_smoke:
        units=stage/'test-units'; units.mkdir(exist_ok=True)
        executable=stage/('test_standalone_link.exe' if os_name=='win64' else 'test_standalone_link')
        opts=['-B','-O2','-dKVM_STANDALONE','-Fu'+str(ROOT/'shared'),'-Fu'+str(ROOT/'server'),
              '-Fu'+str(ROOT/'client'),'-Fi'+str(ROOT/'shared'),'-Fi'+str(stage),
              '-Fl'+str(stage),'-FU'+str(units),'-o'+str(executable)]
        # Skip the server-only session ABI check for a client-only preparation.
        if args.only=='client': opts+=['-dKVM_TEST_CLIENT_ONLY']
        if os_name=='darwin': opts+=['-WM12.3']
        if os_name=='win64': opts+=['-Xe']
        run([fpc,*opts,ROOT/'tests/test_standalone_link.lpr'])
        run([executable])
        run([sys.executable,ROOT/'tools/audit_standalone.py',executable])
    if args.mormot_dir:
        package=args.mormot_dir.resolve()/'packages/lazarus/mormot2.lpk'
        if not package.is_file(): raise BuildError('Paquet mORMot2 introuvable: '+str(package))
        run([laz,'--add-package-link='+str(package)])
    # Force rebuilding after feature changes; no stale standalone .ppu reuse.
    for role,app,project in zip(['server','client'],['MeshKVMServer','MeshKVMClient'],projects):
        if args.only not in ['both',role]: continue
        exe=output/(app+('.exe' if os_name=='win64' else ''))
        exe.unlink(missing_ok=True)
        opts=['--build-all','--compiler='+fpc]
        if role=='client':
            widgetset=args.widgetset or ('cocoa' if os_name=='darwin' else None)
            if widgetset: opts+=['--widgetset='+widgetset]
        run([laz,*opts,project])
        if not exe.is_file(): raise BuildError('Executable non produit: '+str(exe))
        run([sys.executable,ROOT/'tools/audit_standalone.py',exe,'--report',output/(app+'-dependencies.txt')])
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
