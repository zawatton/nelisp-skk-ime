"""Instrument disposable private bundle copies; never edit the runtime or source."""
import argparse
import hashlib
import json
from pathlib import Path
import concurrent_pressure as pressure


def prepare(previous, bundle):
    root = Path(__file__).resolve().parents[2]
    records = []
    assert previous != bundle
    for path in (previous, bundle):
        assert path.resolve().is_relative_to(root/'build'), 'private build bundles required'
        manifest = path/'bundle.manifest'
        fields = dict(line.split('=', 1) for line in manifest.read_text('utf-8').splitlines())
        assert fields['mode'] == 'policy' and fields['policy_ipc'] == 'HP2'
        files = {process: path/'repository/engine'/name for process, name in
                 (('engine','ddskk-engine.el'),('policy','host-policy.el'))}
        record = dict(bundle=str(path), files={})
        for process, file in files.items():
            before = hashlib.sha256(file.read_bytes()).hexdigest()
            after = pressure.instrument(file, process)
            record['files'][process] = dict(original_sha256=before, pressure_sha256=after)
        fields['policy_sha256'] = record['files']['policy']['pressure_sha256']
        manifest.write_text(''.join(f'{key}={value}\n' for key,value in fields.items()), encoding='utf-8')
        records.append(record)
    (bundle.parent/'pressure-artifacts.json').write_text(json.dumps(records, indent=2)+'\n', encoding='utf-8')
    print('PASS EH8 pressure artifacts bundles=2 engine_gc=forced policy_gc=forced HP2=1 runtime_edits=0')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--previous', type=Path, required=True)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.dry_run:
        print('DRYRUN EH8 sources=GC(engine+HP2),loopback-DNS+slow-failing-skkserv,sharing-refusal(checkpoint+outbox) phases=deploy,traffic,rollback,cold-restart clients=3 inline=1 stacks=0 executed=false')
    else:
        prepare(args.previous.resolve(), args.bundle.resolve())
