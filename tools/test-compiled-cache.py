#!/usr/bin/env python3
"""Exercise cached execution across real compiler and process boundaries."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import os
from pathlib import Path
import shutil
import sys
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HEADERS = ROOT / 'Sources/FotufilmHalide'
HALIDE = next((Path(root) for root in [os.environ.get('HALIDE_ROOT'), '/opt/homebrew', '/usr/local']
               if root and (Path(root)/'include/Halide.h').is_file()
               and (Path(root)/'lib/libHalide.dylib').is_file()), None)
SOURCE = r'''
#define FOTUFILM_ENABLE_COMPILED_CACHE 1
#include "FotufilmCompiledCache.h"
#include <iostream>
#include <algorithm>
#include <string>
int main(int argc, char **argv) {
    bool reverse=false, fallback=false, wait=false, retry=false;
    for(int i=1;i<argc;++i) {
        std::string arg(argv[i]);
        reverse |= arg=="reverse"; fallback |= arg=="fallback"; wait |= arg=="wait"; retry |= arg=="retry";
    }
    if(wait) { std::cout << "waiting" << std::endl; std::string line; std::getline(std::cin,line); }
    Halide::Var x("x");
    Halide::ImageParam image(Halide::Float(32),1,"image");
    Halide::Param<float> gain("gain");
    Halide::Param<int32_t> offset("offset");
    Halide::Param<uint32_t> seed("seed");
    Halide::Func f("test_output");
    constexpr float bias = BIAS;
    f(x)=image(x)*gain + Halide::cast<float>(offset) + Halide::cast<float>(seed) + bias;
    f.vectorize(x,8,Halide::TailStrategy::GuardWithIf);
    Halide::Pipeline p(f);
    auto target=Halide::get_host_target().with_feature(Halide::Target::StrictFloat);
    fotufilm::compiled_cache::Pipeline cached;
    std::vector<fotufilm::compiled_cache::Argument> args{image,gain,offset,seed};
    if(reverse) std::reverse(args.begin(),args.end());
    bool ready=cached.prepare(p,"gain",args,target);
    if(ready==fallback) { std::cerr << "unexpected cache availability " << ready << '\n'; return 1; }
    if(retry) {
        Halide::Param<double> unsupported("unsupported");
        if(cached.prepare(p,"unsupported",{image,unsupported},target) || bool(cached)) return 3;
        ready=false;
    }
    Halide::Buffer<float> input(31),output(31);
    for(int frame=0;frame<4;++frame) {
        for(int i=0;i<31;++i) input(i)=float(i)+float(frame)/4;
        image.set(input);gain.set(1+float(frame));offset.set(frame-2);seed.set(41+frame);
        if(ready) cached.realize(output); else p.realize(output,target);
        for(int i=0;i<31;++i) {
            float expected=input(i)*(1+float(frame))+float(frame-2)+float(41+frame)+bias;
            if(output(i)!=expected) { std::cerr << "changed frame mismatch\n"; return 2; }
        }
    }
    std::cout << "correct\n";
    return 0;
}
'''

@unittest.skipUnless(sys.platform == 'darwin' and HALIDE is not None,
                     'Compiled kernel cache tests require macOS and Halide')
class CacheTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        cls.clang = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--find', 'clang++'], text=True).strip()
        cls.temporary = tempfile.TemporaryDirectory(prefix='fotufilm-compiled-cache-')
        cls.root = Path(cls.temporary.name)
        cls.program = cls.compile_program('probe', '0.25f')
        cls.changed = cls.compile_program('changed', '1.25f')

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    @classmethod
    def compile_program(cls, name, bias):
        source = cls.root / (name+'.cpp')
        source.write_text(SOURCE.replace('BIAS',bias))
        output = cls.root / name
        subprocess.run([cls.clang,'-std=c++17','-O2','-Wno-deprecated-declarations',
                        '-isysroot',cls.sdk,'-I'+str(HEADERS),'-I'+str(HALIDE/'include'),
                        '-L'+str(HALIDE/'lib'),'-lHalide','-Wl,-rpath,'+str(HALIDE/'lib'),
                        str(source),'-o',str(output)],check=True,capture_output=True,text=True)
        return output

    def setUp(self):
        self.case = self.root / self._testMethodName
        self.case.mkdir(mode=0o700)
        self.cache = self.case / 'kernels'

    def environment(self, **updates):
        env = dict(os.environ, SDKROOT=self.sdk, FOTUFILM_COMPILED_CACHE_DIRECTORY=str(self.cache))
        env.pop('FOTUFILM_COMPILED_CACHE',None)
        env.update(updates)
        return env

    def run_probe(self, *arguments, program=None, **updates):
        result = subprocess.run([str(program or self.program),*arguments],env=self.environment(**updates),
                                capture_output=True,text=True,timeout=60)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('correct',result.stdout)

    def kernels(self):
        return [p for p in self.cache.rglob('*.dylib') if not p.name.startswith('runtime-')]

    def test_cold_and_warm_values_and_argument_order(self):
        self.run_probe()
        original = self.kernels()
        self.assertEqual(len(original),1)
        stamp = original[0].stat().st_mtime_ns
        self.run_probe()
        self.assertEqual(original[0].stat().st_mtime_ns,stamp)
        self.run_probe('reverse')
        self.assertEqual(len(self.kernels()),2)

    def test_concurrent_first_use_publishes_one_kernel(self):
        with ThreadPoolExecutor(max_workers=8) as workers:
            list(workers.map(lambda _: self.run_probe(),range(8)))
        self.assertEqual(len(self.kernels()),1)
        self.assertEqual(len(list(self.cache.rglob('runtime-*.dylib'))),1)
        self.assertFalse(list(self.cache.rglob('pending-*')))

    def test_corruption_and_missing_stamps_recompile(self):
        self.run_probe()
        kernel = self.kernels()[0]
        stamp = Path(str(kernel)+'.sha256')
        for mutation in ['kernel','empty','stamp','oversized','missing']:
            if mutation=='kernel': kernel.write_bytes(b'broken')
            elif mutation=='empty': kernel.write_bytes(b'')
            elif mutation=='stamp': stamp.write_text('0'*64+'\n')
            elif mutation=='oversized': stamp.write_text('0'*4096)
            else: stamp.unlink()
            self.run_probe()
            self.assertEqual(hashlib.sha256(kernel.read_bytes()).hexdigest(),stamp.read_text().strip())

    def test_disabled_and_unavailable_compiler_fall_back(self):
        self.run_probe('fallback',FOTUFILM_COMPILED_CACHE='0')
        self.assertFalse(self.cache.exists())
        self.run_probe('fallback',DEVELOPER_DIR=str(self.case/'missing-xcode'))
        self.assertFalse(self.kernels())

    def test_untrusted_directory_and_lock_fall_back_without_writing(self):
        self.cache.mkdir(mode=0o777)
        self.cache.chmod(0o777)
        self.run_probe('fallback')
        self.assertEqual(list(self.cache.iterdir()),[])
        self.cache.rmdir()
        target = self.case/'target'
        target.mkdir(mode=0o700)
        self.cache.symlink_to(target,target_is_directory=True)
        self.run_probe('fallback')
        self.assertEqual(list(target.iterdir()),[])
        self.cache.unlink()
        self.run_probe()
        kernel = self.kernels()[0]
        lock = kernel.with_suffix('.lock')
        lock.unlink()
        sentinel = self.case/'sentinel'
        sentinel.write_text('unchanged')
        lock.symlink_to(sentinel)
        self.run_probe('fallback')
        self.assertEqual(sentinel.read_text(),'unchanged')

    def test_failed_repreparation_clears_the_previous_binding(self):
        self.run_probe('retry')

    def test_changed_executable_gets_new_identity(self):
        self.run_probe()
        self.run_probe(program=self.changed)
        self.assertEqual(len(self.kernels()),2)
        self.assertEqual(len([p for p in self.cache.iterdir() if p.is_dir()]),2)

    def test_replaced_running_executable_does_not_cache_under_new_identity(self):
        running = self.case/'running'
        replacement = self.case/'replacement'
        shutil.copy2(self.program,running)
        shutil.copy2(self.changed,replacement)
        process = subprocess.Popen([str(running),'wait','fallback'],env=self.environment(),
                                   stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(),'waiting')
            os.replace(replacement,running)
            output,error = process.communicate('\n',timeout=60)
            self.assertEqual(process.returncode,0,output+error)
            self.assertIn('correct',output)
            self.assertFalse(self.kernels())
            self.run_probe(program=running)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

if __name__=='__main__': unittest.main(verbosity=2)
