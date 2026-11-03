#!/usr/bin/env python3
"""Bounded headless export diagnosis: actual build/render functions, inert manifest.

Compares named OS icon, deterministic bitmap and nil. A named-icon stall is
diagnostic counterevidence, never a full-profile PASS. No app, key or model starts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output-dir', type=Path, default=Path('source-grounded-evidence/mcp-bundle-probe'))
parser.add_argument('--timeout', type=int, default=12)
args = parser.parse_args()
if not 2 <= args.timeout <= 30:
    parser.error('timeout must be2..30 seconds')
root = Path(__file__).resolve().parents[1]
source = (root/'Parrot/Services/MCPBundle.swift').read_text()
profile = (root/'Parrot/ProfileTest.swift').read_text()
out = args.output_dir.resolve()
out.mkdir(parents=True, exist_ok=False)


def block(text, name, indent='    '):
    start = text.index(name)
    end = text.index('\n'+indent+'}', start)+len('\n'+indent+'}')
    return text[start:end]


build = block(source, '    static func build(')
for before, after in [
    ('        if let png = icon.flatMap(pngData) { try png.write(to: root.appendingPathComponent("icon.png")) }',
     '        print("PNG_START")\n        if let png = icon.flatMap(pngData) { try png.write(to: root.appendingPathComponent("icon.png")) }\n        print("PNG_END")'),
    ('        try zip.run()', '        print("DITTO_START")\n        try zip.run()\n        print("DITTO_PID=\\(zip.processIdentifier)")'),
    ('        zip.waitUntilExit()', '        zip.waitUntilExit()\n        print("DITTO_END")'),
]:
    assert build.count(before) == 1
    build = build.replace(before, after)
subject = 'import Foundation\nimport AppKit\nenum MCPBundle {\n'
subject += next(line for line in source.splitlines() if 'static let bundleID =' in line)+'\n'
subject += '    static func manifest(version:String)->[String:Any] { ["name":"Fictional diagnostic", "version":version, "icon":"icon.png"] }\n'
subject += '\n'.join([block(source,'    static func shellQuoted('),
    block(source,'    static func launcher('),build,block(source,'    private static func pngData(')])
subject += '\n}\n'
main = r'''
import Foundation
import AppKit
import Darwin
setbuf(stdout,nil)
print("ICON_START")
let mode = CommandLine.arguments[1]
let icon:NSImage?
if mode == "named" { icon = NSImage(named:NSImage.applicationIconName) }
else if mode == "bitmap" {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1,pixelsHigh:1,
        bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
        bytesPerRow:4,bitsPerPixel:32)!
    rep.bitmapData![0]=220; rep.bitmapData![1]=20; rep.bitmapData![2]=60; rep.bitmapData![3]=255
    let image = NSImage(size:NSSize(width:1,height:1)); image.addRepresentation(rep); icon=image
} else { icon=nil }
print("ICON_END=\(icon != nil)")
let built = try MCPBundle.build(appPath:"/fictional/Parrot.app",version:"1.2.3",icon:icon)
print("ARCHIVE="+built.path)
'''
# Exercise the same subprocess/read/wait helper that the stalled test calls.
main += '\n'+block(profile,'        func run(_ tool: String, _ args: [String])',indent='        ')+'\n'
main += r'''
print("UNZIP_START")
let listing=run("/usr/bin/unzip",["-l",built.path])
print("UNZIP_END")
guard listing.contains(" manifest.json\n"),listing.contains(" server/launch.sh\n") else { exit(3) }
print("PROBE_COMPLETED")
'''

results = []
with tempfile.TemporaryDirectory(prefix='parrot-mcp-bundle-probe-') as directory:
    temp = Path(directory)
    (temp/'Subject.swift').write_text(subject)
    (temp/'main.swift').write_text(main)
    binary = temp/'probe'
    subprocess.run(['swiftc','-swift-version','5','-module-cache-path',str(temp/'module-cache'),
        str(temp/'Subject.swift'),str(temp/'main.swift'),'-o',str(binary)],check=True,timeout=120)
    for mode in ['named','bitmap','nil']:
        phase = temp/mode
        phase.mkdir(mode=0o700)
        env = os.environ.copy(); env['TMPDIR']=str(phase)+'/'
        started = time.monotonic()
        child = subprocess.Popen([str(binary),mode],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
            env=env,start_new_session=True)
        status='completed'
        try:
            output,_=child.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            status='timeout'
            try:
                subprocess.run(['/usr/bin/sample',str(child.pid),'2','1','-file',str(out/(mode+'-sample.txt'))],
                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=6)
            except subprocess.TimeoutExpired:
                pass
            os.killpg(child.pid,signal.SIGTERM)
            try: output,_=child.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL); output,_=child.communicate(timeout=2)
        log=output.decode('utf-8',errors='replace')
        (out/(mode+'.log')).write_text(log)
        row=dict(mode=mode,status=status,returncode=child.returncode,
                 elapsed_seconds=round(time.monotonic()-started,3),markers=log.splitlines())
        if status=='completed' and child.returncode==0:
            archives=[line[8:] for line in log.splitlines() if line.startswith('ARCHIVE=')]
            assert len(archives)==1
            archive=Path(archives[0]).resolve()
            assert archive.is_relative_to(phase.resolve()) and archive.stat().st_size<1000000
            with zipfile.ZipFile(archive) as z:
                row['entries']=z.namelist()
                row['crc_error']=z.testzip()
                assert row['crc_error'] is None and 'manifest.json' in row['entries'] and 'server/launch.sh' in row['entries']
                if mode=='bitmap':
                    png=z.read('icon.png')
                    assert png[:8]==b'\x89PNG\r\n\x1a\n' and png[16:24]==(512).to_bytes(4,'big')*2
                    row['bitmap_png_512']=True
                if mode=='nil': assert 'icon.png' not in row['entries']
        results.append(row)
        print(json.dumps(row))
record=dict(scope='Focused extracted production build/png and actual test subprocess helper, inert manifest; no full-profile or app/native acceptance.',
    production_source_sha256=hashlib.sha256(source.encode()).hexdigest(),results=results)
(out/'RESULT.json').write_text(json.dumps(record,indent=2)+'\n')
assert all(r['status']=='completed' and r['returncode']==0 for r in results if r['mode']!='named'), 'Deterministic bitmap/nil export did not complete'
print('MCP BUNDLE PROBE: deterministic bitmap and nil controls completed; named-icon outcome is diagnostic only; full profile remains separate')
