#!/usr/bin/env python3
"""Target selection regression tests, NOT a Windows MeshKVM build.

The integration test mocks compiler output. The native fixture test really
creates tiny COFF/PE files with Clang/LLD when available; it never compiles or
runs MeshKVM, Lazarus, TurboJPEG or DXGI.
"""
import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('arch_build', ROOT/'build/build_standalone.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)


def exe_fixture(path, cpu):
    raw = bytearray(134)
    raw[:2] = b'MZ'
    struct.pack_into('<I', raw, 60, 128)
    raw[128:132] = b'PE\0\0'
    struct.pack_into('<H', raw, 132, 0x014c if cpu == 'i386' else 0x8664)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)


def dummy_tool(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/bin/sh\nexit 0\n')
    path.chmod(0o755)
    return str(path)


class Targets(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)

    def host(self, system, machine, arch):
        with patch.object(b.platform, 'system', return_value=system), \
             patch.object(b.platform, 'machine', return_value=machine):
            return b.host_target(arch)

    def test_x86_selected_on_windows_x64(self):
        self.assertEqual(self.host('Windows', 'AMD64', 'x86'), ('i386', 'win32'))

    def test_x64_selected(self):
        self.assertEqual(self.host('Windows', 'AMD64', 'x64'), ('x86_64', 'win64'))

    def test_native_x86(self):
        self.assertEqual(self.host('Windows', 'x86', 'native'), ('i386', 'win32'))

    def test_native_x64(self):
        self.assertEqual(self.host('Windows', 'AMD64', 'native'), ('x86_64', 'win64'))

    def test_wow64_python_not_used_as_target(self):
        with patch.dict(os.environ, {'PROCESSOR_ARCHITEW6432':'AMD64'}):
            self.assertEqual(self.host('Windows', 'x86', 'x64'), ('x86_64', 'win64'))

    def test_x64_rejected_on_32bit_windows(self):
        with self.assertRaises(b.BuildError):
            self.host('Windows', 'x86', 'x64')

    def test_other_system_native_preserved(self):
        self.assertEqual(self.host('Linux', 'x86_64', 'native'), ('x86_64', 'linux'))
        self.assertEqual(self.host('Darwin', 'arm64', 'native'), ('aarch64', 'darwin'))

    def test_cross_os_not_silently_added(self):
        for system, machine, arch in [('Linux','x86_64','x86'), ('Darwin','arm64','x64'),
                                      ('Windows','ARM64','x86')]:
            with self.subTest(system=system), self.assertRaises(b.BuildError):
                self.host(system, machine, arch)

    def test_unknown_arch_rejected(self):
        with self.assertRaises(b.BuildError):
            self.host('Windows', 'AMD64', 'x128')

    def test_fpc_target_switches_used_for_queries(self):
        for cpu, system in [('i386','win32'), ('x86_64','win64')]:
            with patch.object(b, 'run', side_effect=[cpu, system]) as run:
                b.check_fpc_target('fpc.exe', cpu, system)
                self.assertEqual(run.call_args_list[0].args[0],
                                 ['fpc.exe','-P'+cpu,'-T'+system,'-iTP'])
                self.assertEqual(run.call_args_list[1].args[0][-1], '-iTO')

    def test_fpc_cannot_silently_ignore_requested_cpu(self):
        with patch.object(b, 'run', side_effect=['i386','win32']), self.assertRaises(b.BuildError):
            b.check_fpc_target('fpc.exe', 'x86_64', 'win64')

    def test_fpc_missing_target_is_explained(self):
        with patch.object(b, 'run', side_effect=b.BuildError('ppcrossx64 absent')):
            with self.assertRaisesRegex(b.BuildError, 'Installer le compilateur'):
                b.check_fpc_target('fpc.exe', 'x86_64', 'win64')

    def test_c_targets_accept_both(self):
        for cpu, system, triple in [('i386','win32','i686-w64-mingw32'),
                                     ('i386','win32','i386-pc-mingw32'),
                                     ('x86_64','win64','x86_64-w64-mingw32')]:
            with patch.object(b, 'run', return_value=triple):
                b.check_c_target('gcc',cpu,system)

    def test_c_target_mismatch_is_not_overridden(self):
        for cpu, system, triple in [('i386','win32','x86_64-w64-mingw32'),
                                     ('x86_64','win64','i686-w64-mingw32'),
                                     ('i386','win32','i686-pc-linux-gnu'),
                                     ('x86_64','win64','x86_64-pc-windows-msvc')]:
            with self.subTest(triple=triple), patch.object(b, 'run', return_value=triple), \
                 self.assertRaises(b.BuildError):
                b.check_c_target('gcc',cpu,system)

    def test_x86_fpc_macro_is_cpu386(self):
        text=b.feature_include('i386','win32',[])
        self.assertIn('IFNDEF CPU386',text)
        self.assertIn('IFNDEF WIN32',text)
        self.assertNotIn('CPUI386',text)

    def test_x64_fpc_macro_preserved(self):
        text=b.feature_include('x86_64','win64',['KVM_STATIC_DXGI'])
        self.assertIn('IFNDEF CPUX86_64',text)
        self.assertIn('IFNDEF WIN64',text)
        self.assertIn('DEFINE KVM_STATIC_DXGI',text)

    def test_sdk_folder_priority_and_spaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk=Path(tmp)/'MinGW 32'/ 'bin'
            gcc=dummy_tool(sdk/'gcc.exe')
            ar=dummy_tool(sdk/'ar.exe')
            self.assertEqual(b.select_c_tool('gcc',None,sdk,cpu='i386'),gcc)
            self.assertEqual(b.select_c_tool('ar',None,sdk,gcc,cpu='i386'),ar)

    def test_prefixed_sdk_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk=Path(tmp)
            cc=dummy_tool(sdk/'i686-w64-mingw32-gcc.exe')
            ar=dummy_tool(sdk/'i686-w64-mingw32-ar.exe')
            self.assertEqual(b.select_c_tool('gcc',None,sdk,cpu='i386'),cc)
            self.assertEqual(b.select_c_tool('ar',None,sdk,cc,cpu='i386'),ar)

    def test_prefixed_gcc_on_path_matches_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdk=Path(tmp)
            wanted=dummy_tool(sdk/'i686-w64-mingw32-gcc')
            dummy_tool(sdk/'gcc')
            with patch.dict(os.environ, {'PATH':str(sdk)}):
                self.assertEqual(b.select_c_tool('gcc',None,None,cpu='i386'),wanted)

    def test_incomplete_sdk_does_not_fallback_to_path(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaisesRegex(b.BuildError, 'toolchain MinGW complete'):
            b.select_c_tool('nm',None,Path(tmp),cpu='i386')

    def test_linker_flags_and_lpi_quoting(self):
        flags=b.windows_linker_flags('/MinGW 32/bin/gcc.exe','/MinGW 32/bin/ld.exe')
        self.assertEqual(flags,['-Xe','-FD/MinGW 32/bin','-XP'])
        self.assertIn('"-FD/MinGW 32/bin"', b.option_text(flags))
        with self.assertRaises(b.BuildError):
            b.option_text(['-FDpath"invalid'])

    def test_archive_formats(self):
        for cpu,fmt in [('i386','pe-i386'), ('x86_64','pe-x86-64')]:
            with patch.object(b,'run',return_value='a.o: file format '+fmt):
                b.check_windows_archive(Path('jpeg.a'),'objdump',cpu)
                with self.assertRaises(b.BuildError):
                    b.check_windows_archive(Path('jpeg.a'),'objdump', 'i386' if cpu=='x86_64' else 'x86_64')
        for text in ['', 'file format elf64-x86-64', 'file format pe-i386\nfile format pe-x86-64']:
            with patch.object(b,'run',return_value=text), self.assertRaises(b.BuildError):
                b.check_windows_archive(Path('jpeg.a'),'objdump','i386')

    def test_pe_headers_reject_wrong_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'probe.exe'
            for cpu in ['i386','x86_64']:
                exe_fixture(p,cpu)
                b.check_pe_target(p,cpu)
                with self.assertRaises(b.BuildError):
                    b.check_pe_target(p, 'i386' if cpu=='x86_64' else 'x86_64')
            p.write_bytes(b'MZ'+bytes(100))
            with self.assertRaises(b.BuildError): b.check_pe_target(p,'i386')

    def test_projects_do_not_overwrite_other_arch(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for role,app in [('server','MeshKVMServer'),('client','MeshKVMClient')]:
                (root/role).mkdir()
                shutil.copy2(ROOT/role/(app+'.lpi'), root/role)
            with patch.object(b,'ROOT',root):
                paths=[]
                for cpu,system in [('i386','win32'),('x86_64','win64')]:
                    projects=b.make_projects(cpu+'-'+system,[],system,fpc='/FPC dir/fpc.exe',
                                             linker_flags=['-Xe','-FD/MinGW dir/bin','-XP'])
                    paths.extend(projects)
                    for p in projects:
                        tree=ET.parse(p)
                        self.assertEqual(tree.find('.//CodeGeneration/TargetCPU').get('Value'),cpu)
                        self.assertEqual(tree.find('.//CodeGeneration/TargetOS').get('Value'),system)
                        self.assertIn(cpu+'-'+system,tree.find('.//UnitOutputDirectory').get('Value'))
                        self.assertTrue(tree.find('.//Target/Filename').get('Value').endswith('.exe'))
                        self.assertIn('"-FD/MinGW dir/bin"',tree.find('.//CustomOptions').get('Value'))
                self.assertEqual(len(set(paths)),4)
                self.assertTrue(all(p.is_file() for p in paths))

    def test_full_build_orchestration_mocked(self):
        """Assert actual main() commands/paths with simulated compiler replies."""
        with tempfile.TemporaryDirectory(prefix='meshkvm arch ') as tmp:
            root=Path(tmp)
            for role,app in [('server','MeshKVMServer'),('client','MeshKVMClient')]:
                (root/role).mkdir()
                shutil.copy2(ROOT/role/(app+'.lpi'), root/role)
            sdk=root/'MinGW SDK'/'bin'
            for name in ['gcc','ar','nm','objdump','ld']:
                dummy_tool(sdk/(name+'.exe'))
            fpc=dummy_tool(root/'FPC'/'fpc.exe')
            laz=dummy_tool(root/'Lazarus'/'lazbuild.exe')
            jpeg=root/'libturbojpeg.a'; jpeg.write_bytes(b'!<arch>\n')
            for lib in ['mingw32','mingwex','gcc','msvcrt','kernel32']:
                (root/('lib'+lib+'.a')).write_bytes(b'!<arch>\n')
            for arch,cpu,system in [('x86','i386','win32'),('x64','x86_64','win64')]:
                calls=[]
                def fake_run(argv,**kwargs):
                    args=[str(x) for x in argv]; calls.append(args)
                    if '-dumpmachine' in args:
                        return ('i686' if cpu=='i386' else 'x86_64')+'-w64-mingw32'
                    if '-iTP' in args: return cpu
                    if '-iTO' in args: return system
                    if args[0].endswith('nm.exe'):
                        return '\n'.join('000 T '+('_' if cpu=='i386' else '')+n for n in [
                            'tjInitCompress','tjInitDecompress','tjCompress2','tjDecompress2',
                            'tjDecompressHeader3','tjBufSize','tjDestroy','tjGetErrorStr2'])
                    if args[0].endswith('objdump.exe'):
                        return 'jpeg.o: file format '+('pe-i386' if cpu=='i386' else 'pe-x86-64')
                    for arg in args:
                        if arg.startswith('-print-file-name='):
                            return str(root/arg.split('=',1)[1])
                    if '-o' in args: exe_fixture(Path(args[args.index('-o')+1]),cpu)
                    for arg in args:
                        if arg.startswith('-o') and len(arg)>2: exe_fixture(Path(arg[2:]),cpu)
                    if args[0]==laz:
                        project=Path(args[-1]); tree=ET.parse(project)
                        exe_fixture((project.parent/tree.find('.//Target/Filename').get('Value')).resolve(),cpu)
                    return ''
                with patch.object(b,'ROOT',root), patch.object(b.platform,'system',return_value='Windows'), \
                     patch.object(b.platform,'machine',return_value='AMD64'), patch.object(b,'run',side_effect=fake_run), \
                     patch.dict(os.environ, {'CC':'/unrelated/Strawberry/gcc.exe'}):
                    result=b.main(['--arch',arch,'--toolchain-bin',str(sdk),'--fpc',fpc,'--lazbuild',laz,
                                   '--turbojpeg-archive',str(jpeg)])
                self.assertEqual(result,0)
                pascal=[c for c in calls if c[0]==fpc and '-B' in c]
                self.assertEqual(len(pascal),1)
                self.assertIn('-P'+cpu,pascal[0]); self.assertIn('-T'+system,pascal[0])
                self.assertIn('-XP',pascal[0])
                laz_commands=[c for c in calls if c[0]==laz]
                self.assertEqual(len(laz_commands),2)
                for cmd in laz_commands:
                    self.assertIn('--cpu='+cpu,cmd); self.assertIn('--os='+system,cmd)
                self.assertTrue((root/'dist'/ (cpu+'-'+system)/'MeshKVMServer.exe').is_file())
            self.assertTrue((root/'server/MeshKVMServer_Standalone_x86.lpi').is_file())
            self.assertTrue((root/'server/MeshKVMServer_Standalone_x64.lpi').is_file())

    def test_check_toolchain_stops_before_native_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); sdk=root/'bin'
            for name in ['gcc','ar','nm','objdump','ld','fpc']:
                dummy_tool(sdk/(name+'.exe'))
            with patch.object(b,'ROOT',root), patch.object(b.platform,'system',return_value='Windows'), \
                 patch.object(b.platform,'machine',return_value='AMD64'), \
                 patch.object(b,'run',side_effect=['i686-w64-mingw32','i386','win32']) as run:
                self.assertEqual(b.main(['--arch','x86','--toolchain-bin',str(sdk),
                                         '--fpc',str(sdk/'fpc.exe'),'--check-toolchain']),0)
                self.assertEqual(run.call_count,3)
                self.assertFalse((root/'native').exists())

    def test_cli_contains_arch_choices(self):
        p=subprocess.run([sys.executable,ROOT/'build/build_standalone.py','--help'],capture_output=True,text=True)
        self.assertEqual(p.returncode,0)
        self.assertIn('--arch {native,x86,x64}',p.stdout)
        self.assertIn('--toolchain-bin',p.stdout)
        self.assertIn('--check-toolchain',p.stdout)


class RealCoffFixtures(unittest.TestCase):
    @unittest.skipUnless(all(shutil.which(t) for t in ['clang','llvm-ar','objdump','lld-link','nm']),
                         'Clang/LLVM/binutils unavailable')
    def test_real_coff_and_pe_x86_x64(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            source=root/'fixture.c'
            source.write_text('int meshkvm_probe(void) { return sizeof(void*); }\n')
            for cpu,triple,machine in [('i386','i686-w64-windows-gnu','x86'),
                                        ('x86_64','x86_64-w64-windows-gnu','x64')]:
                obj=root/(cpu+'.o'); lib=root/(cpu+'.a'); exe=root/(cpu+'.exe')
                b.run(['clang','-target',triple,'-O2','-c',source,'-o',obj])
                b.run(['llvm-ar','rcs',lib,obj])
                b.assert_archive(lib,'nm',['meshkvm_probe'])
                b.check_windows_archive(lib,'objdump',cpu)
                with self.assertRaises(b.BuildError):
                    b.check_windows_archive(lib,'objdump','i386' if cpu=='x86_64' else 'x86_64')
                b.run(['lld-link','/entry:meshkvm_probe','/subsystem:console','/nodefaultlib',
                       '/machine:'+machine,'/out:'+str(exe),obj])
                b.check_pe_target(exe,cpu)
                with self.assertRaises(b.BuildError):
                    b.check_pe_target(exe, 'i386' if cpu=='x86_64' else 'x86_64')
                print('REAL COFF/PE fixture checked, NOT executed:',cpu)


if __name__=='__main__':
    unittest.main(verbosity=2)
