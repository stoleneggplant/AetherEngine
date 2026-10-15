#!/usr/bin/env python3
"""Generate a public variable-cadence H.264 twin, never consume real media.

Run the timestamp runtime on missing-head.mp4 at 0 1.5 0 20 40, and on
healthy-head.mp4 at 0. The former must remove frame-PTS regressions while
preserving DTS/audio/payload; the latter must remain byte-for-byte unchanged.
This fixture proves display ordering, not recovery of an arbitrary writer's
lost original composition timestamps or physical A/V synchronization.
"""
import argparse
from pathlib import Path
import struct
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('output', type=Path)
parser.add_argument('--partial-hierarchical', action='store_true', help='Generate healthy/tail/middle B3 twins for the partial-region path')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
if args.partial_hierarchical:
    healthy = args.output / 'healthy-b3.mp4'
    subprocess.run([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-n',
        '-f', 'lavfi', '-i', 'color=c=blue:s=96x64:r=25:d=24',
        '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=24',
        '-c:v', 'libx264', '-preset', 'fast', '-pix_fmt', 'yuv420p', '-g', '49', '-bf', '3',
        '-x264-params', 'scenecut=0:b-adapt=0', '-c:a', 'aac', '-video_track_timescale', '90000',
        '-metadata', 'comment=Aether synthetic timestamp fixture', '-movflags', '+faststart', str(healthy),
    ], check=True)
    # 49-picture GOPs align the IDR boundaries with ctts runs; mutate offsets only.
    for mode in ('tail', 'middle'):
        subprocess.run(['ruby', str(Path(__file__).with_name('make-partial-ctts-fixture.rb')),
                        str(healthy), str(args.output / (mode + '-b3.mp4')), mode, '196', '392', '600'], check=True)
    raise SystemExit(0)

healthy = args.output / 'healthy-head.mp4'
missing = args.output / 'missing-head.mp4'
if healthy.exists() or missing.exists():
    raise SystemExit('Refusing to replace an existing fixture')
subprocess.run([
    'ffmpeg', '-hide_banner', '-loglevel', 'error', '-n',
    '-f', 'lavfi', '-i', 'testsrc2=s=96x64:r=25:d=60',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000:duration=60',
    '-vf', "settb=1/1200000,setpts='if(lt(N,8),N*48000,384000+(N-8)*40040)'",
    '-fps_mode', 'passthrough', '-enc_time_base', '1/1200000',
    '-c:v', 'libx264', '-preset', 'fast', '-pix_fmt', 'yuv420p',
    '-g', '60', '-bf', '2', '-x264-params', 'scenecut=0:b-adapt=0:b-pyramid=none',
    '-c:a', 'aac', '-video_track_timescale', '1200000',
    '-metadata', 'comment=Aether synthetic timestamp fixture',
    '-movflags', '+faststart', str(healthy),
], check=True)
data = bytearray(healthy.read_bytes())
changed = 0


def zero_offsets(start, end):
    global changed
    while start < end:
        size, kind = struct.unpack_from('>I4s', data, start)
        assert size >= 8 and start + size <= end
        if kind in (b'moov', b'trak', b'mdia', b'minf', b'stbl'):
            zero_offsets(start + 8, start + size)
        elif kind == b'ctts':
            count = struct.unpack_from('>I', data, start + 12)[0]
            assert size == 16 + 8 * count
            for index in range(count):
                offset = start + 16 + 8 * index
                changed += struct.unpack_from('>I', data, offset)[0]
                struct.pack_into('>I', data, offset + 4, 0)
        start += size


zero_offsets(0, len(data))
assert changed == 1500
with missing.open('xb') as output:
    output.write(data)
print('PASS generated missing-head twin: 1500 frames, retained edit/index/audio/payload')
