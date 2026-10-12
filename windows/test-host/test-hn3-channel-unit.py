"""Compile the production HN3 codec; no host or stack is started."""
from pathlib import Path
import json
import os
import subprocess
ROOT = Path(__file__).resolve().parents[2]

def main():
    spec = json.loads((ROOT / 'docs/contracts/hn3-frames-v1.json').read_text('utf-8'))
    assert spec['header_bytes'] == 52 and spec['limits']['payload_bytes'] == 262144
    out = ROOT / 'build/w/hn3-channel-unit'
    out.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'windows/test-host/hn3_channel_unit.cpp').as_posix()
    (out / 'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.24)
project(hn3_unit LANGUAGES CXX)
add_executable(hn3-unit "{source}")
target_compile_features(hn3-unit PRIVATE cxx_std_20)
target_compile_options(hn3-unit PRIVATE /utf-8)
add_executable(hn3-adapter-unit "{(ROOT / 'windows/test-host/hn3_adapter_unit.cpp').as_posix()}" "{(ROOT / 'windows/src/local_index.cpp').as_posix()}" "{(ROOT / 'windows/src/engine_protocol.cpp').as_posix()}")
target_compile_features(hn3-adapter-unit PRIVATE cxx_std_20)
target_compile_definitions(hn3-adapter-unit PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
target_compile_options(hn3-adapter-unit PRIVATE /utf-8)
target_link_libraries(hn3-adapter-unit PRIVATE ws2_32 advapi32 bcrypt)
''', encoding='utf-8', newline='\n')
    subprocess.run(['cmake','-S',str(out),'-B',str(out / 'build'),'-G','Visual Studio 17 2022','-A','x64'], check=True, timeout=30)
    subprocess.run(['cmake','--build',str(out / 'build'),'--config','Release'], check=True, timeout=60)
    subprocess.run([str(out / 'build/Release/hn3-unit.exe')], check=True, timeout=10)
    subprocess.run([str(out / 'build/Release/hn3-adapter-unit.exe')], check=True, timeout=75 if os.environ.get('HN_IME_RUNTIME') else 10)
    subprocess.run(['emacs', '-Q', '--batch', '--eval', "(require 'cl-lib)", '-L', str(ROOT),
                    '-l', str(ROOT / 'windows/test-host/hn3_dispatch_unit.el')], cwd=ROOT, check=True, timeout=20)
    if runtime := os.environ.get('HN_IME_RUNTIME'):
        subprocess.run(['python', '-B', str(ROOT / 'windows/test-host/test-hn3-child-unit.py'),
                        '--runtime', runtime], cwd=ROOT, check=True, timeout=90)

if __name__ == '__main__':
    main()
