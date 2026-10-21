"""Query fixtures use the schema of the database created by the Swift capture test."""
import contextlib
import csv
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import threading
from unittest import mock
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / '.agents/skills/inkflow-quality-analysis/scripts/quality.py'
ENGINE_DB = ROOT / 'build/quality-evidence/engine-controller.sqlite3'
with contextlib.closing(sqlite3.connect(ENGINE_DB.as_uri() + '?mode=ro', uri=True)) as schema_db:
    DDL = dict(schema_db.execute("SELECT name, sql FROM sqlite_master WHERE type='table'"))
STAMP = '2026-09-06T16:00:00.000Z'
OPS = dict(keypresses=5, pageRequests=1, pageTurns=1, candidateMoves=2, preeditEdits=0)


def window(commit, end, elapsed, **counts):
    """A post-commit window as the recorder writes it into the operations of the composition after its commit."""
    return dict(dict(commitID=commit, end=end, elapsedMilliseconds=elapsed, deletions=0, forwardDeletions=0, undo=0,
                     directText=0, paste=0, leadingDeletions=0, leadingForwardDeletions=0, leadingUndo=0), **counts)


# The fixture's `raw-only` composition is their carrier; the commits they describe belong to compositions a to d.
WINDOWS = [window('commit-a', 'next_code', 1500, deletions=2, leadingDeletions=2),
           window('commit-b', 'timeout', 10000, deletions=1, directText=1, paste=1),
           window('commit-c', 'client_changed', 250),
           window('commit-d', 'deactivated', 400, forwardDeletions=2, leadingForwardDeletions=2, undo=1, leadingUndo=1)]


def insert(db, table, **values):
    db.execute(f'INSERT INTO {table} ({",".join(values)}) VALUES ({",".join("?" for _ in values)})', list(values.values()))


def empty_db(path):
    db = sqlite3.connect(path)
    db.execute('PRAGMA foreign_keys=ON')
    db.execute('PRAGMA application_id=1229345073')
    db.execute('PRAGMA user_version=4')
    for sql in DDL.values():
        db.execute(sql)
    return db


def fixture(path):
    db = empty_db(path)
    insert(db, 'recording_runs', id='run', started_at=STAMP, status='closed', engine_version='1.17.0',
           build_metadata_json='{}', metric_rule_version=1,
           stats_json=json.dumps(dict(written=21, submitted=30, droppedBusy=2, droppedQueue=3,
                                      droppedOversized=1, errors=1, truncatedEnvelopes=1)))
    for source, event, count, reason in [
            ('voice_session', 'finalized', 4, None), ('voice_correction', 'detected', 2, None),
            ('voice_correction', 'learned', 1, None), ('voice_correction', 'rejected', 1, 'immediate_undo'),
            ('voice_alias', 'hit', 2, None), ('voice_alias', 'later_reuse', 1, None),
            ('canonical_lexicon', 'hit', 3, None), ('canonical_lexicon', 'later_reuse', 2, None)]:
        insert(db, 'effectiveness_events', run_id='run', occurred_at=STAMP, source=source,
               event=event, reason=reason, count=count)
    identities = {
        'rev1': ('fingerprint-A', 'ranking-A', 'settings-A', 'measurement-A', 'build-A'),
        'rev2': ('fingerprint-A', 'ranking-A', 'settings-B', 'measurement-A', 'build-B'),
        'rev3': ('fingerprint-B', 'ranking-B', 'settings-C', 'measurement-A', 'build-C'),
    }
    for rid, values in identities.items():
        fp, ranking, settings, measurement, build = values
        insert(db, 'config_revisions', id=rid, fingerprint=fp, created_at=STAMP,
               applied_config_json=json.dumps({'revision': rid}),
               build_metadata_json=json.dumps({
                   'sourceRevision': build, 'appVersion': '1.1' if rid == 'rev3' else '1.0',
                   'appBuild': '2' if rid == 'rev3' else '1', 'raw': rid}),
               engine_version='1.17.0', metric_rule_version=1,
               ranking_fingerprint=ranking, settings_fingerprint=settings,
               measurement_fingerprint=measurement, build_identity=build)

    def add(cid, *, outcome='committed', regular=1, issued=1, presentation='candidates_requested',
            first=True, index=0, chosen='使', kind='chinese', caret=3, context='', custom=0,
            revision='rev1', rank=4, prefix_valid=True, truncated=0):
        insert(db, 'compositions', id=cid, run_id='run', started_at=STAMP, ended_at=STAMP,
               app_bundle_id="app'quoted", outcome='committed' if outcome == 'committed' else 'unknown',
               operations_json=json.dumps(OPS), page_history_truncated=truncated, dropped_page_count=2*truncated)
        commit_id = f'commit-{cid}' if outcome == 'committed' else None
        if commit_id:
            insert(db, 'commits', id=commit_id, composition_id=cid, issued_at=STAMP, text=chosen,
                   kind='candidate' if regular else 'punctuation', insertion_issued=issued,
                   character_count=len(chosen))
        page = dict(generation=7, rawInput='shi', caret=caret, selectedPrefix='', selectedPrefixValid=prefix_valid,
                    precedingContext=context, configurationRevisionID=revision, configuration={},
                    page=0 if rank == 1 else 1, pageSize=3, highlightedDisplayIndex=0,
                    presentation=presentation, capturedAt=STAMP,
                    candidates=[dict(text=chosen, displayIndex=0, displayRank=rank,
                                     nativeIndex=0 if rank == 1 else 1, nativeRank=1 if rank == 1 else 5,
                                     type='phrase', corrected=False, evidence='0,3,n,1,0,n,phrase,0')])
        first_page = dict(page, page=0, candidates=[dict(text='是', displayIndex=0, displayRank=1, nativeIndex=0, nativeRank=1)])
        insert(db, 'candidate_decisions', id=f'decision-{cid}', composition_id=cid, config_revision_id=revision,
               commit_id=commit_id, occurred_at=STAMP, sequence=0, trigger='space' if regular else 'punctuation',
               outcome=outcome, selected_display_index=index, selected_text=chosen, text_kind=kind,
               snapshot_json=json.dumps(page, ensure_ascii=False), first_page_json=json.dumps(first_page) if first else None,
               visited_pages_json='[]', page_history_truncated=truncated, dropped_page_count=2*truncated,
               operations_json=json.dumps(OPS), regular_ranked_selection=regular, matches_custom_phrase=custom,
               unknown_rank_reason='ambiguous_candidate_text' if index is None else None,
               selected_character_count=len(chosen))

    add('a'); add('b', revision='rev2'); add('c', truncated=1)
    add('d', chosen='是', rank=1)
    add('e', first=False)
    add('f', index=None)
    add('g', outcome='reverted'); add('h', outcome='edited'); add('i', outcome='cancelled')
    add('j', regular=0); add('k', issued=0); add('l', presentation='not_shown')
    add('m', prefix_valid=False); add('n', chosen='😀', kind='emoji')
    add('o', caret=2); add('p', context='前文'); add('q', custom=1); add('r', revision='rev3')
    add('s', outcome='unknown'); add('t', outcome='interrupted')
    insert(db, 'compositions', id='raw-only', run_id='run', started_at=STAMP, ended_at=STAMP,
           app_bundle_id='other.app', outcome='committed',
           operations_json=json.dumps(dict(OPS, postCommitWindows=WINDOWS)),
           page_history_truncated=0, dropped_page_count=0)
    insert(db, 'commits', id='raw-commit', composition_id='raw-only', issued_at=STAMP, text='raw',
           kind='raw_return', insertion_issued=1, character_count=3)
    db.commit()
    db.close()


EARLIER = '2026-08-01T16:00:00.000Z'


def fake_hash(kind, value):
    """Stands in for the store's keyed hash: deterministic, 32 hex characters, no key involved."""
    return hashlib.sha256(f'{kind}:{value}'.encode()).hexdigest()[:32]


def replay_fixture(path):
    """Decisions for `replay-cases` and the trend buckets, apart from `fixture` so its counts stay put."""
    db = empty_db(path)
    insert(db, 'recording_runs', id='run', started_at=STAMP, status='closed', engine_version='1.17.0',
           build_metadata_json='{}', metric_rule_version=1, stats_json='{}')
    insert(db, 'config_revisions', id='rev1', fingerprint='fingerprint-A', created_at=STAMP,
           applied_config_json='{}', build_metadata_json='{}', engine_version='1.17.0', metric_rule_version=1,
           ranking_fingerprint='ranking-A', settings_fingerprint='settings-A',
           measurement_fingerprint='measurement-A', build_identity='build-A')

    def page(raw, texts, *, number=0, context='', generation=7, facts=None, natives=None, text=True, end=None):
        """`facts` is how many leading candidates carry type, corrected and evidence (all by default).
        `end` is where the span they consumed ends in the raw input (all of it by default)."""
        candidates = []
        for index, shown in enumerate(texts):
            native = index if natives is None else natives[index]
            item = dict(text=shown, displayIndex=index, displayRank=number * 9 + index + 1,
                        nativeIndex=native, nativeRank=number * 9 + native + 1)
            if index < (len(texts) if facts is None else facts):
                item.update(type='phrase', corrected=False,
                            evidence=f'0,{len(raw) if end is None else end},n,1,0,n,phrase,0')
            candidates.append(item)
        result = dict(generation=generation, rawInput=raw, caret=len(raw), selectedPrefix='',
                      selectedPrefixValid=True, precedingContext=context, configurationRevisionID='rev1',
                      configuration={}, page=number, pageSize=9, highlightedDisplayIndex=0,
                      presentation='candidates_requested', capturedAt=STAMP, candidates=candidates)
        if not text:
            result.update(rawInput='', precedingContext='', textCaptured=False)
            for item in candidates:
                item['text'] = ''
        return result

    def add(cid, raw, texts, chosen, *, committed=None, number=0, index=None, first=None, first_generation=7,
            kind='chinese', started=STAMP, trigger='space', outcome='committed', regular=1, text=True,
            counts='written', **options):
        """`counts` is what the writer stores: its own scalar counts, nothing (before v4) or an explicit number."""
        committed_count, selected_count = counts, counts
        if counts == 'written':
            committed_count, selected_count = len(committed or chosen), len(chosen)
        insert(db, 'compositions', id=cid, run_id='run', started_at=started, ended_at=started, app_bundle_id='app',
               outcome='committed', operations_json=json.dumps(OPS), page_history_truncated=0,
               dropped_page_count=0)
        insert(db, 'commits', id=f'commit-{cid}', composition_id=cid, issued_at=started, kind='candidate',
               text=(committed or chosen) if text else '', insertion_issued=1, character_count=committed_count)
        snapshot = page(raw, texts, number=number, text=text, **options)
        selected = texts.index(chosen) if index is None else index
        # The store hashes the selected candidate before it redacts the text; the span is the evidence row's.
        if chosen and 'evidence' in snapshot['candidates'][selected]:
            snapshot['codeHash'] = fake_hash('code', raw[:options.get('end') or len(raw)])
            snapshot['candidates'][selected]['textHash'] = fake_hash('text', chosen)
        first_page = None
        if first is not None:
            first_page = json.dumps(page(raw, first, generation=first_generation, text=text, **options),
                                    ensure_ascii=False)
        insert(db, 'candidate_decisions', id=f'decision-{cid}', composition_id=cid, config_revision_id='rev1',
               commit_id=f'commit-{cid}', occurred_at=started, sequence=0, trigger=trigger, outcome=outcome,
               selected_display_index=selected,
               selected_text=chosen if text else None, text_kind=kind,
               snapshot_json=json.dumps(snapshot, ensure_ascii=False), first_page_json=first_page,
               visited_pages_json='[]', page_history_truncated=0, dropped_page_count=0,
               operations_json=json.dumps(OPS), regular_ranked_selection=regular, matches_custom_phrase=0,
               selected_character_count=selected_count)

    # Page 0: the snapshot list is the case, whatever the first page held.
    add('r1', 'kaihui', ['凯会', '开会', '开汇'], '开会', natives=[1, 0, 2], first=['开会', '开汇', '凯会'],
        context='他说')
    # Paged: the first page is the case.
    add('r2', 'hui', ['辉', '晖'], '辉', number=1, first=['汇', '会', '灰'])
    # Paged without a usable first page: no list to replay.
    add('r3', 'zhunbeiwu', ['准备午', '准备五'], '准备午', number=1)
    add('r4', 'womenqukaihui', ['我们去开会', '我们去开汇'], '我们去开会', number=1, first=['我们去开会'],
        first_generation=99)
    # Records from before the facts existed: all or some candidates lack them.
    add('r5', 'tianqi', ['天气', '田七'], '天气', facts=0, counts=None)
    add('r6', 'de', ['的', '得'], '的', facts=1)
    # Text-free, another kind, not regular, not committed.
    add('r7', 'ke', ['课', '可'], '课', text=False)
    add('r8', 'xiao', ['😀'], '😀', kind='emoji')
    # Lengths that cannot be known, in their own kind so the Chinese series stays put: a text-free decision written
    # before v4, an empty selection (a zero count) and a text-mode decision before v4, which buckets by its text.
    add('r11', 'ke', ['课'], '课', kind='symbol', text=False, counts=None)
    add('r12', 'kong', [''], '', kind='symbol', counts=0)
    add('r13', 'pu', ['——'], '——', kind='symbol', counts=None)
    add('r9', 'pu', ['，'], '，', trigger='punctuation', regular=0)
    add('r10', 'shi', ['是'], '是', outcome='reverted')
    # Before the 28-day window of the trend and the --since of the replay tests.
    add('w1', 'shi', ['使', '是'], '使', started=EARLIER)
    db.commit()
    db.close()


@contextlib.contextmanager
def utc():
    """The local calendar days of a window are the UTC days."""
    previous = os.environ.get('TZ')
    os.environ['TZ'] = 'UTC'
    time.tzset()
    try:
        yield
    finally:
        if previous is None:
            os.environ.pop('TZ', None)
        else:
            os.environ['TZ'] = previous
        time.tzset()


LEARNING_START = datetime(2026, 9, 3, 12, tzinfo=timezone.utc)
LEARNING_ARGS = ('--until', '2026-10-01')


def learning_fixture(path, rows):
    """Regular committed decisions for `learning`, one composition each. `day` counts from the first day of the
    28-day window that ends before 2026-10-01 (2026-09-03, with TZ=UTC), `order` is minutes within the day.
    A row is (day, order, code, word, rank) and options: `end` (where the consumed span ends in the code),
    `type`, `revision`, `hashed`, `evidence`, `text` (text mode) and `prefix`."""
    db = empty_db(path)
    insert(db, 'recording_runs', id='run', started_at=STAMP, status='closed', engine_version='1.17.0',
           build_metadata_json='{}', metric_rule_version=1, stats_json='{}')
    for revision, measurement in [('rev0', 'measurement-0'), ('rev1', 'measurement-A'), ('revU', None)]:
        insert(db, 'config_revisions', id=revision, fingerprint='fingerprint-A', created_at=STAMP,
               applied_config_json='{}', build_metadata_json='{}', engine_version='1.17.0', metric_rule_version=1,
               ranking_fingerprint='ranking-A', settings_fingerprint='settings-A',
               measurement_fingerprint=measurement, build_identity='build-A')
    for number, (day, order, code, word, rank, *rest) in enumerate(rows):
        options = rest[0] if rest else {}
        cid = f'c{number}'
        started = (LEARNING_START + timedelta(days=day, minutes=order)).isoformat(
            timespec='milliseconds').replace('+00:00', 'Z')
        text = options.get('text', True)
        index, paged = (rank - 1) % 9, (rank - 1) // 9
        candidates = [dict(text=f'other{shown}', displayIndex=shown, displayRank=paged * 9 + shown + 1,
                           nativeIndex=shown, nativeRank=paged * 9 + shown + 1) for shown in range(index + 1)]
        selected = candidates[index]
        selected['text'] = word
        if options.get('evidence', True):
            end = options.get('end', len(code))
            selected.update(type=options.get('type', 'phrase'), corrected=False,
                            evidence=f'0,{end},n,1,0,n,{options.get("type", "phrase")},0')
        snapshot = dict(generation=7, rawInput=code, caret=len(code), selectedPrefix=options.get('prefix', ''),
                        selectedPrefixValid=True, precedingContext='', configurationRevisionID='rev1',
                        configuration={}, page=paged, pageSize=9, highlightedDisplayIndex=index,
                        presentation='candidates_requested', capturedAt=started, candidates=candidates)
        if options.get('hashed', True) and 'evidence' in selected and not options.get('prefix'):
            snapshot['codeHash'] = fake_hash('code', code[:end])
            selected['textHash'] = fake_hash('text', word)
        if not text:
            snapshot.update(rawInput='', textCaptured=False)
            for shown in candidates:
                shown['text'] = ''
        insert(db, 'compositions', id=cid, run_id='run', started_at=started, ended_at=started, app_bundle_id='app',
               outcome='committed', operations_json=json.dumps(OPS), page_history_truncated=0, dropped_page_count=0)
        insert(db, 'commits', id=f'commit-{cid}', composition_id=cid, issued_at=started, kind='candidate',
               text=word if text else '', insertion_issued=1, character_count=len(word))
        insert(db, 'candidate_decisions', id=f'decision-{cid}', composition_id=cid,
               config_revision_id=options.get('revision', 'rev1'), commit_id=f'commit-{cid}', occurred_at=started,
               sequence=0, trigger=options.get('trigger', 'space'), outcome=options.get('outcome', 'committed'),
               selected_display_index=index, selected_text=word if text else None, text_kind='chinese',
               snapshot_json=json.dumps(snapshot, ensure_ascii=False), visited_pages_json='[]',
               page_history_truncated=0, dropped_page_count=0, operations_json=json.dumps(OPS),
               regular_ranked_selection=options.get('regular', 1), matches_custom_phrase=0,
               selected_character_count=len(word))
    db.commit()
    db.close()


# The pairs of the main fixture, each a sequence of (day, rank, type); pair J is the same word as E under another code.
LEARNING_PAIRS = {
    ('nihao', '你好'): [(0, 3, 'phrase'), (1, 1, 'phrase'), (2, 1, 'phrase')],
    ('pengyou', '朋友'): [(1, 2, 'user_phrase'), (3, 4, 'phrase'), (5, 1, 'phrase'), (9, 1, 'phrase'),
                          (10, 5, 'phrase')],
    ('zhongguo', '中国'): [(2, 2, 'phrase'), (4, 2, 'phrase')],
    ('shijie', '世界'): [(8, 6, 'phrase'), (9, 2, 'phrase'), (12, 3, 'phrase')],
    ('xihuan', '喜欢'): [(6, 1, 'phrase'), (7, 1, 'phrase'), (8, 3, 'english_personal_2')],
    ('women', '我们'): [(10, 4, 'phrase'), (11, 4, 'phrase'), (12, 4, 'phrase'), (13, 1, 'phrase')],
    ('tianqi', '天气'): [(15, 2, 'mixed_personal_0')],
    ('de', '的'): [(16, 1, 'phrase')],
    ('xh', '喜欢'): [(20, 1, 'phrase')],
}


def learning_rows():
    rows = [(day, order, code, word, rank, dict(type=kind))
            for order, ((code, word), sequence) in enumerate(LEARNING_PAIRS.items())
            for day, rank, kind in sequence]
    # The same word chosen again as the leading segment of a longer code: the same pair as the whole input.
    rows.append((16, 30, 'nihaoshijie', '你好', 1, dict(end=5)))
    # Inside the cohort but with no pair identity: no evidence row to name a span, a text record written before the
    # hashes, a text-free record without them, and a decision after a selected prefix.
    rows += [(5, 40, 'wu', '无', 2, dict(evidence=False, text=False)),
             (5, 41, 'jiu', '旧', 2, dict(hashed=False)),
             (5, 42, 'mian', '免', 2, dict(hashed=False, text=False)),
             (5, 43, 'houmian', '后', 3, dict(prefix='前', text=False))]
    # Not counted: another metric rule (known, then unknown), before the window, and outside the regular cohort.
    rows += [(1, 50, 'qita', '其', 2, dict(revision='rev0')),
             (1, 51, 'weizhi', '未', 2, dict(revision='revU')),
             (-1, 0, 'pengyou', '朋友', 1),
             (5, 52, 'zhongguo', '中国', 1, dict(trigger='punctuation', regular=0))]
    return rows


class QueryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('quality', SCRIPT)
        cls.quality = importlib.util.module_from_spec(spec)
        sys.dont_write_bytecode = True
        spec.loader.exec_module(cls.quality)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='inkflow-query-')
        self.addCleanup(self.temp.cleanup)
        self.db = Path(self.temp.name) / 'fixture ?#.sqlite3'
        fixture(self.db)

    def run_cli(self, *args, db=None, success=True):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = self.quality.main([*args, '--db', str(db or self.db)])
        self.assertEqual(code, 0 if success else 2, stderr.getvalue())
        if not success:
            self.assertEqual(stdout.getvalue(), '', 'Failed input must not emit a partial summary')
        return stdout.getvalue() if success else stderr.getvalue()

    def result(self, command='summary', *args, db=None):
        return json.loads(self.run_cli(command, *args, '--format', 'json', db=db))

    def export_file(self, name='A.json'):
        path = Path(self.temp.name) / name
        self.run_cli('export', '--output', str(path), '--format', 'json')
        return path

    def test_export_roundtrip_overlap_and_two_devices(self):
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE config_revisions SET applied_config_json=?", (json.dumps(dict(customPhrases=[dict(code='private', text='unused-private-phrase')])),))
            for rid, raw in db.execute('SELECT id,snapshot_json FROM candidate_decisions').fetchall():
                page = json.loads(raw); page['configuration'] = dict(customPhrases=['unused-private-phrase'])
                db.execute('UPDATE candidate_decisions SET snapshot_json=? WHERE id=?', (json.dumps(page), rid))
        before = self.db.read_bytes()
        a = self.export_file()
        self.assertEqual(before, self.db.read_bytes())
        self.assertNotIn('unused-private-phrase', a.read_text())
        document = json.loads(a.read_text())
        self.assertEqual(document['format_version'], 1)
        self.assertEqual(document['range'], dict(first=STAMP, last=STAMP))
        self.assertEqual(document['tables']['config_revisions'][0]['applied_config_json'], '{}')
        self.assertNotIn('configuration', json.loads(document['tables']['candidate_decisions'][0]['snapshot_json']))
        self.assertEqual(document['schema_version'], 4)
        self.assertEqual({r['character_count'] for r in document['tables']['commits']}, {1, 3})
        self.assertEqual({r['selected_character_count'] for r in document['tables']['candidate_decisions']}, {1})
        # Same device, another export after extending an active run and adding an event.
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE recording_runs SET stats_json=?", (json.dumps(dict(written=22)),))
            db.execute("INSERT INTO effectiveness_events(run_id,occurred_at,source,event,count) VALUES('run',?,'voice_session','finalized',1)", (STAMP,))
        overlap = self.export_file('overlap.json')
        local = self.result()
        merged = self.result('summary', '--input', str(a), '--input', str(a), '--input', str(overlap))
        self.assertEqual(merged['coverage'], local['coverage'])
        self.assertEqual(merged['recording_runs'], local['recording_runs'])
        self.assertEqual(merged['learning_effectiveness'], local['learning_effectiveness'])
        self.assertEqual(len(merged['sources']), 1)
        external = json.loads(self.run_cli('summary', '--exports-only', '--input', str(a), '--format', 'json'))
        self.assertEqual(external['coverage']['compositions'], 21)
        for field in ('groups', 'rank_counts', 'identity_coverage'):
            self.assertEqual(external[field], local[field])
        # Device B intentionally uses identical fixture IDs, but must remain a distinct cohort.
        document['source_id'] = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        b = Path(self.temp.name) / 'B.json'; b.write_text(json.dumps(document))
        union = self.result('summary', '--input', str(a), '--input', str(b))
        self.assertEqual(union['coverage']['compositions'], 42)
        self.assertEqual(len(union['sources']), 2)
        self.assertEqual(union['by_source'][document['source_id']]['coverage'], external['coverage'])
        isolated = self.result('summary', '--input', str(b), '--source', document['source_id'])
        self.assertEqual(isolated['coverage'], external['coverage'])
        inspected = self.result('inspect', document['source_id'] + ':a', '--input', str(b))
        self.assertEqual(inspected['composition']['source_id'], document['source_id'])
        # Local file stayed unchanged by analysis (the deliberate fixture writes above are excluded).
        current = self.db.read_bytes()
        self.result('trend', '--input', str(b), '--until', '2026-09-08', '--days', '7')
        self.assertEqual(current, self.db.read_bytes())
        self.assertNotEqual(before, current)
        # Retention can free INTEGER PRIMARY KEY 1 within the same recording run.
        with sqlite3.connect(self.db) as db:
            db.execute('DELETE FROM effectiveness_events')
            db.execute("INSERT INTO effectiveness_events(id,run_id,occurred_at,source,event,count) VALUES(1,'run','2026-09-07T16:00:00.000Z','voice_session','finalized',1)")
        after_cleanup = self.export_file('after-cleanup.json')
        retained = self.result('summary', '--exports-only', '--input', str(overlap), '--input', str(after_cleanup))
        self.assertEqual(retained['sources'][0]['counts']['effectiveness_events'], 10)

    def test_export_empty_invalid_and_conflicting_inputs_fail_without_summary(self):
        empty = Path(self.temp.name) / 'empty.sqlite3'; db = empty_db(empty); db.close()
        out = Path(self.temp.name) / 'empty.json'
        self.run_cli('export', '--output', str(out), db=empty)
        result = self.result('summary', '--exports-only', '--input', str(out))
        self.assertEqual(result['coverage']['compositions'], 0)
        self.assertIsNone(json.loads(out.read_text())['range']['first'])
        # Text history expires before content-free events; versions must remain traceable.
        with sqlite3.connect(empty) as db:
            insert(db, 'recording_runs', id='events-run', started_at=STAMP, status='closed', engine_version='1.17.0',
                   build_metadata_json=json.dumps(dict(appVersion='0.5.0', appBuild='80')), metric_rule_version=1, stats_json='{}')
            insert(db, 'effectiveness_events', run_id='events-run', occurred_at=STAMP, source='voice_session', event='finalized', count=1)
        events_file = Path(self.temp.name) / 'events-only.json'
        self.run_cli('export', '--output', str(events_file), db=empty)
        events = self.result('summary', '--exports-only', '--input', str(events_file))
        self.assertEqual(events['sources'][0]['versions'][0]['app_version'], '0.5.0')
        self.assertEqual(events['sources'][0]['counts']['compositions'], 0)
        a = self.export_file()
        for mutation in ('version', 'schema-v3', 'negative-count', 'missing-parent', 'bad-json', 'duplicate', 'shape',
                         'type', 'range', 'huge-integer', 'offset-time'):
            doc = json.loads(a.read_text())
            if mutation == 'version': doc['format_version'] = 99
            elif mutation == 'schema-v3': doc['schema_version'] = 3
            elif mutation == 'negative-count': doc['tables']['commits'][0]['character_count'] = -1
            elif mutation == 'missing-parent': doc['tables']['compositions'][0]['run_id'] = 'missing'
            elif mutation == 'bad-json': doc['tables']['candidate_decisions'][0]['snapshot_json'] = '{'
            elif mutation == 'duplicate': doc['tables']['commits'].append(doc['tables']['commits'][0])
            elif mutation == 'type': doc['tables']['compositions'][0]['page_history_truncated'] = '1'
            elif mutation == 'range': doc['range']['first'] = None
            elif mutation == 'huge-integer': doc['tables']['compositions'][0]['dropped_page_count'] = 1 << 70
            elif mutation == 'offset-time':
                doc['tables']['compositions'][0]['started_at'] = '2026-09-07T00:00:00.000+08:00'
                doc['range']['last'] = '2026-09-07T00:00:00.000+08:00'
            else: doc['tables']['commits'] = None
            bad = Path(self.temp.name) / 'bad.json'; bad.write_text(json.dumps(doc))
            message = self.run_cli('summary', '--exports-only', '--input', str(bad), success=False)
            if mutation == 'schema-v3':
                self.assertIn('schema v4', message)
        bad.write_text('{')
        self.run_cli('summary', '--input', str(bad), success=False)
        doc = json.loads(a.read_text()); doc['tables']['commits'][0]['text'] = 'conflict'
        bad.write_text(json.dumps(doc))
        self.assertIn('conflicting', self.run_cli('summary', '--input', str(a), '--input', str(bad), success=False))
        self.run_cli('export', '--output', str(self.db), success=False)
        self.run_cli('export', '--output', str(a), success=False)
        # The pair key beside the database is never an export destination and never in an export.
        key = Path(self.temp.name) / 'quality-pair-key'
        secret = os.urandom(32)
        key.write_bytes(secret)
        self.assertIn('pair key', self.run_cli('export', '--output', str(key), success=False))
        self.assertEqual(key.read_bytes(), secret)
        keyed = Path(self.temp.name) / 'keyed.json'
        self.run_cli('export', '--output', str(keyed))
        self.assertNotIn(secret, keyed.read_bytes())
        self.assertNotIn(secret.hex().encode(), keyed.read_bytes())

    def test_native_settings_export_is_readable_and_preserves_database(self):
        executable = os.environ.get('INKFLOW_QUALITY_EXPORT_FIXTURE')
        if not executable:
            self.skipTest('Native export fixture not built; use test-quality-query.sh')
        import subprocess
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE commits SET text=? WHERE id='raw-commit'", ('raw\0tail',))
        before = self.db.read_bytes()
        out = Path(self.temp.name) / 'native.json'
        key = Path(self.temp.name) / 'quality-pair-key'
        secret = os.urandom(32)
        key.write_bytes(secret)
        subprocess.run([executable, str(self.db), str(out)], check=True, capture_output=True)
        self.assertNotIn(secret, out.read_bytes())
        self.assertNotIn(secret.hex().encode(), out.read_bytes())
        refused_key = subprocess.run([executable, str(self.db), str(key)], capture_output=True)
        self.assertEqual(refused_key.returncode, 2)
        self.assertIn('配对密钥', refused_key.stderr.decode())
        self.assertEqual(key.read_bytes(), secret)
        result = self.result('summary', '--exports-only', '--input', str(out))
        self.assertEqual(result['coverage'], self.result()['coverage'])
        self.assertEqual(self.db.read_bytes(), before)
        document = json.loads(out.read_text())
        self.assertEqual(len(document['tables']), 6)
        self.assertEqual(next(r['text'] for r in document['tables']['commits'] if r['id'] == 'raw-commit'), 'raw\0tail')
        self.assertEqual((document['schema_version'], {r['character_count'] for r in document['tables']['commits']}),
                         (4, {1, 3}))
        self.assertTrue(all(r['applied_config_json'] == '{}' for r in document['tables']['config_revisions']))
        self.assertTrue(all('configuration' not in json.loads(r['snapshot_json']) for r in document['tables']['candidate_decisions']))
        # Invalid native source schemas are rejected before any output is saved.
        bad = Path(self.temp.name) / 'bad-native.sqlite3'; bad.write_bytes(self.db.read_bytes())
        with sqlite3.connect(bad) as db:
            db.execute('PRAGMA user_version=99')
        rejected = Path(self.temp.name) / 'rejected-native.json'
        failure = subprocess.run([executable, str(bad), str(rejected)], capture_output=True)
        self.assertEqual(failure.returncode, 2)
        self.assertFalse(rejected.exists())

    def test_inspect_compact_and_legacy_page_revisions(self):
        with sqlite3.connect(self.db) as db:
            raw = db.execute("SELECT snapshot_json FROM candidate_decisions WHERE composition_id='a'").fetchone()[0]
            compact = json.loads(raw)
            compact.pop('configuration')
            first = dict(compact, configurationRevisionID='rev2', page=0)
            visited = dict(compact, configurationRevisionID='rev3', page=2)
            db.execute("UPDATE candidate_decisions SET snapshot_json=?, first_page_json=?, visited_pages_json=? WHERE composition_id='a'",
                       (json.dumps(compact), json.dumps(first), json.dumps([visited])))
        result = self.result('inspect', 'a', '--config', 'fingerprint-A')
        self.assertEqual([r['id'] for r in result['configurations']], ['rev1', 'rev2', 'rev3'])
        self.assertNotIn('configuration', result['decisions'][0]['snapshot'])
        self.assertIn('configuration', self.result('inspect', 'b')['decisions'][0]['snapshot'])
        with sqlite3.connect(self.db) as db:
            visited['configurationRevisionID'] = 'missing'
            db.execute("UPDATE candidate_decisions SET visited_pages_json=? WHERE composition_id='a'", (json.dumps([visited]),))
        self.assertIn('missing configuration', self.run_cli('inspect', 'a', success=False))

    def test_post_commit_windows_are_found_through_their_commit(self):
        args = self.quality.parser().parse_args(['summary', '--db', str(self.db)])
        with contextlib.closing(self.quality.connect(self.db)) as db:
            sql, parameters = self.quality.ctes(args)
            observed = {row['composition_id']: row
                        for row in self.quality.rows(db, sql + 'SELECT * FROM observations', parameters)}
        columns = lambda row: {key: value for key, value in row.items() if key.startswith('window_')}
        self.assertEqual(columns(observed['a']), dict(
            window_end='next_code', window_elapsed_ms=1500, window_deletions=2, window_forward_deletions=0,
            window_undo=0, window_direct_text=0, window_paste=0, window_leading_deletions=2,
            window_leading_forward_deletions=0, window_leading_undo=0))
        timeout = observed['b']
        self.assertEqual((timeout['window_end'], timeout['window_elapsed_ms'], timeout['window_paste'],
                          timeout['window_direct_text'], timeout['window_leading_deletions']),
                         ('timeout', 10000, 1, 1, 0))
        self.assertEqual((observed['d']['window_forward_deletions'], observed['d']['window_undo'],
                          observed['d']['window_leading_forward_deletions'], observed['d']['window_leading_undo']),
                         (2, 1, 2, 1))
        # Not observed is null, never zero.
        self.assertEqual(set(columns(observed['e']).values()), {None})
        # The decisions keep their own identity: the join adds columns and no rows.
        self.assertEqual(len(observed), 20)

    def test_inspect_lists_the_windows_of_its_own_commits(self):
        windows = self.result('inspect', 'a')['windows']
        self.assertEqual(windows, [dict(commit_id='commit-a', end='next_code', elapsed_ms=1500, deletions=2,
                                        forward_deletions=0, undo=0, direct_text=0, paste=0, leading_deletions=2,
                                        leading_forward_deletions=0, leading_undo=0)])
        self.assertIn('$.windows[0].end | "next_code"', self.run_cli('inspect', 'a'))
        # The carrier holds four windows in its operations, none of them for its own commit.
        self.assertEqual(self.result('inspect', 'raw-only')['windows'], [])
        self.assertEqual(self.result('inspect', 'e')['windows'], [])

    def test_coverage_counts_windows_of_the_selected_commits(self):
        every = dict(next_code=1, client_changed=1, deactivated=1, timeout=1)
        coverage = self.result()['coverage']
        self.assertEqual((coverage['commit_windows'], coverage['windows_by_end']), (4, every))
        # The carrier is outside this filter and the commits it describes are inside.
        quoted = self.result('summary', '--app', "app'quoted")['coverage']
        self.assertEqual((quoted['commit_windows'], quoted['windows_by_end']), (4, every))
        none = dict(next_code=0, client_changed=0, deactivated=0, timeout=0)
        other = self.result('summary', '--app', 'other.app')['coverage']
        self.assertEqual((other['commit_windows'], other['windows_by_end']), (0, none))
        exported = self.export_file()
        imported = self.result('summary', '--exports-only', '--input', str(exported))['coverage']
        self.assertEqual((imported['commit_windows'], imported['windows_by_end']), (4, every))

    def test_inspect_shows_candidate_ranking_facts(self):
        candidate = self.result('inspect', 'a')['decisions'][0]['snapshot']['candidates'][0]
        self.assertEqual((candidate['type'], candidate['corrected'], candidate['evidence']),
                         ('phrase', False, '0,3,n,1,0,n,phrase,0'))
        table = self.run_cli('inspect', 'a')
        for field, value in [('type', '"phrase"'), ('corrected', 'false'), ('evidence', '"0,3,n,1,0,n,phrase,0"')]:
            self.assertIn(f'$.decisions[0].snapshot.candidates[0].{field} | {value}', table)
        # Pages recorded without the facts, such as the first page here, still inspect.
        older = self.result('inspect', 'a')['decisions'][0]['first_page']['candidates'][0]
        self.assertNotIn('type', older)

    def replay_cases(self, *args, db=None, name='cases.jsonl'):
        """Run replay-cases into the temporary directory; returns the header and the cases."""
        out = Path(self.temp.name) / name
        self.run_cli('replay-cases', '--output', str(out), *args, '--format', 'json', db=db)
        lines = out.read_text(encoding='utf-8').splitlines()
        return json.loads(lines[0]), [json.loads(line) for line in lines[1:]]

    def test_replay_cases_take_candidates_from_the_snapshot_or_the_first_page(self):
        db = Path(self.temp.name) / 'replay.sqlite3'
        replay_fixture(db)
        header, cases = self.replay_cases('--since', '2026-09-01', '--until', '2026-09-08', db=db)
        self.assertEqual({key: header[key] for key in ('cases', 'text_free_excluded', 'without_evidence',
                                                       'without_first_page')},
                         dict(cases=4, text_free_excluded=1, without_evidence=2, without_first_page=2))
        self.assertEqual(header['window'], dict(since=self.quality.timestamp('2026-09-01'),
                                                until=self.quality.timestamp('2026-09-08')))
        self.assertLess(abs(datetime.now(timezone.utc) - datetime.fromisoformat(
            header['generated_at'].replace('Z', '+00:00'))), timedelta(minutes=5))
        self.assertEqual([case['composition_id'] for case in cases], ['r1', 'r2', 'r5', 'r6'])
        listed, first_page = cases[0], cases[1]
        # Page 0 keeps the commit-time list even though the first page differs.
        self.assertEqual(listed['candidates_from'], 'snapshot')
        self.assertEqual([c['text'] for c in listed['candidates']], ['凯会', '开会', '开汇'])
        self.assertEqual(listed['candidates'][1], dict(
            text='开会', display_index=1, native_index=0, native_rank=1, type='phrase', corrected=False,
            evidence='0,6,n,1,0,n,phrase,0', source=None))
        self.assertEqual([c['native_rank'] for c in listed['candidates']], [2, 1, 3])
        self.assertEqual((listed['decision_id'], listed['raw_input'], listed['preceding_context'], listed['page']),
                         ('decision-r1', 'kaihui', '他说', 0))
        self.assertEqual((listed['selected_display_index'], listed['selected_text'], listed['committed_text']),
                         (1, '开会', '开会'))
        self.assertEqual(listed['occurred_at'], STAMP)
        # A paged decision replays the first page; its selection index belongs to the snapshot page.
        self.assertEqual(first_page['candidates_from'], 'first_page')
        self.assertEqual(first_page['page'], 1)
        self.assertEqual([c['text'] for c in first_page['candidates']], ['汇', '会', '灰'])
        self.assertEqual((first_page['selected_display_index'], first_page['selected_text']), (0, '辉'))
        # Records without the facts keep null fields instead of guesses.
        before_facts, partial = cases[2], cases[3]
        self.assertTrue(all(c['type'] is None and c['corrected'] is None and c['evidence'] is None
                            for c in before_facts['candidates']))
        self.assertEqual([c['evidence'] is None for c in partial['candidates']], [False, True])
        # Without a window the earlier decision is a case too.
        header, cases = self.replay_cases(db=db, name='all.jsonl')
        self.assertEqual((header['cases'], header['window']), (5, dict(since=None, until=None)))
        self.assertEqual(cases[0]['composition_id'], 'w1')

    def test_replay_cases_default_to_chinese_and_skip_text_free_records(self):
        db = Path(self.temp.name) / 'replay.sqlite3'
        replay_fixture(db)
        header, cases = self.replay_cases(db=db)
        self.assertNotIn('r7', [case['composition_id'] for case in cases])
        self.assertNotIn('r8', [case['composition_id'] for case in cases])
        self.assertEqual(header['text_free_excluded'], 1)
        header, cases = self.replay_cases('--kind', 'emoji', db=db, name='emoji.jsonl')
        self.assertEqual([case['composition_id'] for case in cases], ['r8'])
        self.assertEqual(header['text_free_excluded'], 0)

    def test_replay_cases_read_exports_too(self):
        db = Path(self.temp.name) / 'replay.sqlite3'
        replay_fixture(db)
        exported = Path(self.temp.name) / 'replay-export.json'
        self.run_cli('export', '--output', str(exported), db=db)
        header, cases = self.replay_cases('--exports-only', '--input', str(exported), db=db, name='exchange.jsonl')
        expected, _ = self.replay_cases(db=db, name='local.jsonl')
        self.assertEqual(header['cases'], expected['cases'])
        self.assertEqual(len({case['composition_id'].split(':')[0] for case in cases}), 1)

    def test_replay_cases_refuse_an_output_inside_the_repository_or_an_existing_file(self):
        db = Path(self.temp.name) / 'replay.sqlite3'
        replay_fixture(db)
        for inside in (ROOT / 'replay-cases-refused.jsonl', ROOT / 'macOS/Tests/no-such-directory/cases.jsonl'):
            self.assertIn('outside the repository', self.run_cli('replay-cases', '--output', str(inside),
                                                                  db=db, success=False))
            self.assertFalse(inside.exists())
        out = Path(self.temp.name) / 'once.jsonl'
        self.run_cli('replay-cases', '--output', str(out), db=db)
        before = out.read_bytes()
        self.run_cli('replay-cases', '--output', str(out), db=db, success=False)
        self.assertEqual(out.read_bytes(), before)
        self.assertEqual(out.stat().st_mode & 0o077, 0, 'replay files hold typed text')
        self.run_cli('replay-cases', db=db, success=False)

    def test_wilson_interval_matches_published_values(self):
        low, high = self.quality.wilson(8, 10)
        self.assertAlmostEqual(low, 0.4902, places=4)
        self.assertAlmostEqual(high, 0.9433, places=4)
        self.assertEqual(self.quality.wilson(0, 0), (None, None))
        self.assertEqual(self.quality.wilson(0, 20)[0], 0.0)
        self.assertEqual(self.quality.wilson(20, 20)[1], 1.0)

    def test_trend_reports_wilson_paging_and_selection_length(self):
        db = Path(self.temp.name) / 'replay.sqlite3'
        replay_fixture(db)
        trend = self.result('trend', '--days', '28', '--until', '2026-09-08', db=db)
        for name, series in trend['series'].items():
            for point in series:
                for window in ('daily', 'rolling_7d', 'rolling_28d'):
                    metric = point[window]
                    for key in ('top1_wilson_low', 'top1_wilson_high', 'paged_selected', 'paged_rate',
                                'by_selection_length', 'text_free', 'length_unavailable'):
                        self.assertIn(key, metric, f'{name} {point["date"]} {window}')
                    self.assertEqual(list(metric['by_selection_length']), ['1', '2', '3+'])
                    if metric['top1_rate'] is None:
                        self.assertEqual((metric['top1_wilson_low'], metric['top1_wilson_high']), (None, None))
                        self.assertIsNone(metric['paged_rate'])
                    else:
                        self.assertLessEqual(metric['top1_wilson_low'], metric['top1_rate'])
                        self.assertLessEqual(metric['top1_rate'], metric['top1_wilson_high'])
        month = trend['series']['chinese'][-1]['rolling_28d']
        self.assertEqual((month['known_rank'], month['top1_selected'], month['top3_selected']), (7, 3, 4))
        self.assertEqual((month['paged_selected'], month['text_free'], month['length_unavailable']), (3, 1, 0))
        self.assertAlmostEqual(month['paged_rate'], 3 / 7)
        self.assertAlmostEqual(month['top1_wilson_low'], 0.1582, places=4)
        self.assertAlmostEqual(month['top1_wilson_high'], 0.7495, places=4)
        buckets = month['by_selection_length']
        counts = {key: (b['known_rank'], b['top1_selected'], b['top3_selected'], b['paged_selected'])
                  for key, b in buckets.items()}
        # The text-free 课 (r7) is in bucket 1 through its stored count; 天气 (r5) has none and buckets by its text.
        self.assertEqual(counts, {'1': (3, 2, 2, 1), '2': (2, 1, 2, 0), '3+': (2, 0, 0, 2)})
        self.assertEqual(sum(b['known_rank'] for b in buckets.values()) + month['length_unavailable'],
                         month['known_rank'])
        self.assertAlmostEqual(buckets['2']['top3_rate'], 1.0)
        self.assertAlmostEqual(buckets['1']['top1_wilson_low'], self.quality.wilson(2, 3)[0])
        self.assertEqual((buckets['3+']['top1_rate'], buckets['3+']['top1_wilson_low']), (0.0, 0.0))
        self.assertNotIn('by_selection_length', buckets['1'])
        self.assertNotIn('text_free', buckets['1'])
        self.assertNotIn('length_unavailable', buckets['1'])
        # The decision outside the window and the emoji one stay out of the Chinese series.
        overall = trend['series']['overall'][-1]['rolling_28d']
        self.assertEqual(overall['known_rank'], 11)
        # A text-free decision before v4 and an empty selection have no length; a text-mode one before v4 still has.
        symbols = trend['series']['symbol'][-1]['rolling_28d']
        self.assertEqual((symbols['known_rank'], symbols['text_free'], symbols['length_unavailable']), (3, 1, 2))
        self.assertEqual({key: b['known_rank'] for key, b in symbols['by_selection_length'].items()},
                         {'1': 0, '2': 1, '3+': 0})
        self.assertEqual(sum(b['known_rank'] for b in overall['by_selection_length'].values())
                         + overall['length_unavailable'], overall['known_rank'])
        for point in trend['series']['overall']:
            for window in ('daily', 'rolling_7d', 'rolling_28d'):
                metric = point[window]
                self.assertEqual(sum(b['known_rank'] for b in metric['by_selection_length'].values())
                                 + metric['length_unavailable'], metric['known_rank'], point['date'])
        # Table and CSV list every leaf, so the interval, paged rate and buckets appear in both.
        for output in (self.run_cli('trend', '--days', '28', '--until', '2026-09-08', db=db),
                       self.run_cli('trend', '--days', '28', '--until', '2026-09-08', '--format', 'csv', db=db)):
            for field in ('rolling_28d.top1_wilson_low', 'rolling_28d.paged_rate',
                          'rolling_28d.by_selection_length.1.top1_rate',
                          'rolling_28d.by_selection_length.2.top1_rate',
                          'rolling_28d.by_selection_length.3+.top1_rate'):
                self.assertIn(field, output)

    def test_trend_fields_exist_on_the_base_fixture(self):
        trend = self.result('trend', '--days', '7', '--until', '2026-09-08')
        month = trend['series']['overall'][-1]['rolling_28d']
        # Eleven known-rank decisions: 使 or 是 or 😀 chosen at rank 4 on page 1, except 是 at rank 1.
        self.assertEqual((month['known_rank'], month['top1_selected'], month['paged_selected']), (11, 1, 10))
        self.assertAlmostEqual(month['paged_rate'], 10 / 11)
        self.assertEqual(month['length_unavailable'], 0)
        buckets = month['by_selection_length']
        self.assertEqual((buckets['1']['known_rank'], buckets['1']['top1_selected']), (11, 1))
        self.assertEqual((buckets['2']['known_rank'], buckets['2']['top1_rate'], buckets['3+']['top1_wilson_low']),
                         (0, None, None))
        self.assertEqual(self.result('trend', '--days', '7')['series']['overall'][0]['daily']['top1_wilson_low'],
                         None)

    def test_summary_exact_denominators_and_ranks(self):
        result = self.result()
        self.assertEqual(result['coverage']['compositions'], 21)
        self.assertEqual(result['coverage']['commits'], 16)
        self.assertEqual(result['coverage']['decisions'], 20)
        group = next(g for g in result['groups'] if g['ranking_fingerprint']=='ranking-A'
                     and g['measurement_fingerprint']=='measurement-A'
                     and g['text_kind']=='chinese' and g['presentation']=='candidates_requested')
        expected = dict(decisions=17, committed=12, unknown=1, reverted=1, edited=1, cancelled=1,
                        interrupted=1, regular_not_issued=1, valid=10, known_rank=9, unknown_rank=1,
                        comparable=7, first_page_unavailable=2, top1_selected=1, top3_selected=1,
                        top1_matches=1,
                        truncated=1, dropped_page_count=2)
        for key, value in expected.items():
            self.assertEqual(group[key], value, key)
        self.assertAlmostEqual(group['top1_rate'], 1/9)
        self.assertAlmostEqual(group['top3_rate'], 1/9)
        self.assertAlmostEqual(group['top1_match_rate'], 1/7)
        self.assertEqual(group['mean_display_rank'], 33/9)
        ranks = [r for r in result['rank_counts'] if r['ranking_fingerprint']=='ranking-A'
                 and r['measurement_fingerprint']=='measurement-A'
                 and r['text_kind']=='chinese' and r['presentation']=='candidates_requested']
        self.assertEqual([(r['display_rank'],r['count']) for r in ranks], [(1,1),(4,8)])
        hidden = next(g for g in result['groups'] if g['presentation']=='not_shown')
        self.assertEqual(hidden['regular_issued'], 1)
        self.assertEqual(hidden['valid'], 0)
        self.assertIsNone(hidden['top1_rate'])
        self.assertIsNone(hidden['top3_rate'])
        self.assertEqual(result['recording_runs']['scope'], 'whole_db_lifetime_unfiltered')
        self.assertEqual(result['recording_runs']['totals']['droppedQueue'], 3)
        effectiveness = result['learning_effectiveness']
        self.assertEqual(effectiveness['scope'], 'content_free_events_separate_from_candidate_accuracy')
        self.assertEqual(effectiveness['voice']['finalized'], 4)
        self.assertEqual(effectiveness['voice']['corrections_detected'], 2)
        self.assertEqual(effectiveness['voice']['corrections_learned'], 1)
        self.assertEqual(effectiveness['voice']['corrections_rejected'], 1)
        self.assertEqual(effectiveness['voice']['rejection_reasons'],
                         [{'reason': 'immediate_undo', 'count': 1}])
        self.assertEqual(effectiveness['voice']['correction_detection_rate'], 0.5)
        self.assertEqual(effectiveness['voice']['correction_learning_rate'], 0.5)
        self.assertEqual(effectiveness['voice']['alias_reuse_rate'], 0.5)
        self.assertEqual(effectiveness['canonical_lexicon']['reuse_rate'], 2 / 3)
        filtered = self.result('summary', '--kind', 'english')['learning_effectiveness']
        self.assertEqual(filtered['status'], 'unavailable_for_candidate_filters')
        self.assertIsNone(filtered['voice']['correction_detection_rate'])

    def test_top3_uses_the_known_rank_denominator_and_includes_ranks_two_and_three(self):
        with sqlite3.connect(self.db) as db:
            for cid, rank in [('a', 2), ('b', 3)]:
                snapshot = json.loads(db.execute(
                    "SELECT snapshot_json FROM candidate_decisions WHERE composition_id=?", (cid,)
                ).fetchone()[0])
                snapshot['page'] = 0
                snapshot['highlightedDisplayIndex'] = rank - 1
                snapshot['candidates'] = [
                    dict(text='使' if display_rank == rank else f'候{display_rank}',
                         displayIndex=display_rank - 1, displayRank=display_rank,
                         nativeIndex=display_rank - 1, nativeRank=display_rank)
                    for display_rank in range(1, rank + 1)
                ]
                db.execute("""UPDATE candidate_decisions SET selected_display_index=?,
                    snapshot_json=?,first_page_json=? WHERE composition_id=?""",
                    (rank - 1, json.dumps(snapshot, ensure_ascii=False),
                     json.dumps(snapshot, ensure_ascii=False), cid))
        result = self.result()
        group = next(g for g in result['groups'] if g['ranking_fingerprint']=='ranking-A'
                     and g['measurement_fingerprint']=='measurement-A'
                     and g['text_kind']=='chinese' and g['presentation']=='candidates_requested')
        self.assertEqual(group['known_rank'], 9)
        self.assertEqual(group['top1_selected'], 1)
        self.assertEqual(group['top3_selected'], 3)
        self.assertAlmostEqual(group['top1_rate'], 1/9)
        self.assertAlmostEqual(group['top3_rate'], 3/9)
        trend = self.result('trend', '--days', '7', '--until', '2026-09-08')
        daily = trend['series']['overall'][-1]['daily']
        self.assertEqual(daily['top3_selected'], result['coverage']['top3_selected'])
        self.assertAlmostEqual(daily['top3_rate'], result['coverage']['top3_rate'])

    def test_trend_is_calendar_continuous_rolls_counts_and_marks_versions(self):
        previous = os.environ.get('TZ')
        chart = Path(self.temp.name) / 'trend.svg'
        try:
            os.environ['TZ']='Asia/Taipei'; time.tzset()
            result = self.result('trend', '--days', '7', '--until', '2026-09-08', '--chart', str(chart))
        finally:
            if previous is None: os.environ.pop('TZ',None)
            else: os.environ['TZ']=previous
            time.tzset()
        self.assertEqual(result['window']['days'], 7)
        self.assertEqual(result['window']['first_day'], '2026-09-01')
        self.assertEqual(result['window']['last_day'], '2026-09-07')
        overall = result['series']['overall']
        self.assertEqual([point['date'] for point in overall], [
            '2026-09-01','2026-09-02','2026-09-03','2026-09-04',
            '2026-09-05','2026-09-06','2026-09-07'])
        self.assertTrue(all(point['daily']['decisions'] == 0 for point in overall[:-1]))
        self.assertEqual(overall[-1]['daily']['decisions'], 20)
        self.assertEqual(overall[-1]['rolling_7d']['decisions'], 20)
        self.assertEqual(overall[-1]['rolling_28d']['decisions'], 20)
        self.assertEqual({marker['app_version'] for marker in result['version_markers']}, {'1.0','1.1'})
        self.assertEqual(result['attribution'], 'version_markers_only_not_statistical_partitions')
        self.assertTrue(chart.is_file())
        chart_text = chart.read_text()
        self.assertIn('<svg', chart_text)
        self.assertIn('Top1', chart_text)
        self.assertIn('Top3', chart_text)

    def test_trend_uses_latest_measurement_and_reports_exclusions(self):
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE config_revisions SET measurement_fingerprint='measurement-B' WHERE id='rev2'")
        result = self.result('trend', '--days', '7', '--until', '2026-09-08')
        daily = result['series']['overall'][-1]['daily']
        self.assertIsNotNone(daily['top1_rate'])
        self.assertEqual(daily['quality_rate_status'], 'available_within_measurement_fingerprint')
        self.assertEqual(result['metric_scope']['rule_fingerprint'], 'measurement-A')
        self.assertEqual(result['metric_scope']['excluded_decisions'], 1)

    def test_issues_grouping_and_inspect_ids(self):
        result = self.result('ranking-issues')
        self.assertEqual(len(result['issues']), 1)
        issue = result['issues'][0]
        self.assertEqual(issue['occurrences'], 3)
        self.assertEqual(issue['mean_display_rank'], 4)
        self.assertEqual(issue['mean_native_rank'], 5)
        self.assertEqual(issue['page_turns'], 3)
        self.assertEqual(issue['candidate_moves'], 6)
        self.assertEqual(issue['composition_ids'], ['a','b','c'])
        self.assertEqual(issue['first_page_top1'], '是')
        self.assertEqual(len(self.result('ranking-issues','--min-count','1')['issues']), 6)
        self.assertEqual(len(self.result('ranking-issues','--min-count','1','--limit','2')['issues']), 2)
        for cid in issue['composition_ids']:
            data = self.result('inspect', cid)
            self.assertEqual(data['composition']['id'],cid)
            self.assertEqual(data['decisions'][0]['snapshot']['candidates'][0]['text'], '使')
            self.assertIsNone(data['decisions'][0]['snapshot']['candidates'][0].get('source'))

    def test_filters_and_parameter_binding(self):
        filtered = self.result('summary', '--app', "app'quoted", '--config','fingerprint-A','--kind','emoji')
        self.assertEqual(filtered['coverage']['compositions'], 1)
        self.assertEqual(filtered['coverage']['decisions'], 1)
        self.assertEqual(filtered['groups'][0]['text_kind'], 'emoji')
        self.assertEqual(filtered['recording_runs']['totals']['droppedQueue'], 3)
        self.assertEqual(self.result('summary','--app', "x' OR 1=1 --")['coverage']['compositions'], 0)
        self.assertEqual(self.result('summary','--config','fingerprint')['coverage']['compositions'], 0)
        self.assertEqual(self.result('summary','--ranking-config','ranking-A')['coverage']['compositions'], 19)
        self.assertEqual(self.result('summary','--ranking-config','ranking')['coverage']['compositions'], 0)
        self.assertEqual(self.result('summary','--config','fingerprint-B')['coverage']['compositions'], 1)
        self.assertEqual(self.result('summary','--ranking-config','ranking-B')['coverage']['compositions'], 1)
        self.assertEqual(self.result('summary','--since',STAMP)['coverage']['compositions'],21)
        self.assertEqual(self.result('summary','--until',STAMP)['coverage']['compositions'],0)
        self.assertEqual(self.result('summary','--since','2026-09-06T16:00:00.000001Z')['coverage']['compositions'],0)
        self.assertEqual(self.result('summary','--until','2026-09-06T16:00:00.000001Z')['coverage']['compositions'],21)
        self.assertEqual(self.result('summary','--since','2026-09-06T15:59:59.999999Z')['coverage']['compositions'],21)
        self.assertEqual(self.result('summary','--until','2026-09-06T15:59:59.999999Z')['coverage']['compositions'],0)
        self.assertEqual(self.result('summary','--since','2026-09-07T00:00:00+08:00')['coverage']['compositions'],21)
        self.assertIn('does not match',self.run_cli('inspect','a','--kind','emoji',success=False))

    def test_layered_identity_grouping_coverage_and_inspect(self):
        result = self.result()
        groups = [g for g in result['groups'] if g['ranking_fingerprint']=='ranking-A'
                  and g['measurement_fingerprint']=='measurement-A'
                  and g['text_kind']=='chinese' and g['presentation']=='candidates_requested']
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['decisions'], 17)
        coverage = result['identity_coverage']
        self.assertEqual(coverage['cohort'], 'filtered_decisions')
        self.assertEqual(coverage['ranking']['known'], 20)
        self.assertEqual(coverage['ranking']['unknown'], 0)
        self.assertEqual(coverage['ranking']['distinct'], 2)
        self.assertEqual(coverage['build']['distinct'], 3)
        self.assertEqual(coverage['build']['identities'], [
            {'identity': 'build-A', 'count': 18},
            {'identity': 'build-B', 'count': 1},
            {'identity': 'build-C', 'count': 1},
        ])
        inspected = self.result('inspect', 'a')
        revision = inspected['configurations'][0]
        self.assertEqual(revision['ranking_fingerprint'], 'ranking-A')
        self.assertEqual(revision['settings_fingerprint'], 'settings-A')
        self.assertEqual(revision['measurement_fingerprint'], 'measurement-A')
        self.assertEqual(revision['build_identity'], 'build-A')
        self.assertEqual(revision['fingerprint'], 'fingerprint-A')
        self.assertEqual(revision['applied_config'], {'revision': 'rev1'})
        self.assertEqual(revision['build_metadata'], {
            'sourceRevision': 'build-A', 'appVersion': '1.0', 'appBuild': '1', 'raw': 'rev1'})
        self.assertEqual(revision['engine_version'], '1.17.0')
        self.assertEqual(revision['metric_rule_version'], 1)
        self.assertEqual(inspected['identity_coverage']['cohort'], 'returned_configuration_revisions')

    def test_unknown_identity_is_separate_and_inspect_preserves_null(self):
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE config_revisions SET ranking_fingerprint=NULL, settings_fingerprint=NULL, "
                       "measurement_fingerprint=NULL, build_identity=NULL WHERE id='rev3'")
        result = self.result()
        unknown = next(g for g in result['groups'] if g['ranking_fingerprint']=='unknown')
        self.assertEqual(unknown['measurement_fingerprint'], 'unknown')
        self.assertEqual(unknown['decisions'], 1)
        self.assertIsNone(unknown['top1_rate'])
        self.assertIsNone(unknown['top3_rate'])
        self.assertEqual(unknown['quality_rate_status'], 'unavailable_unknown_measurement_fingerprint')
        self.assertEqual(result['coverage']['quality_rate_status'],
                         'unavailable_across_measurement_fingerprints')
        self.assertEqual(result['identity_coverage']['ranking']['unknown'], 1)
        inspected = self.result('inspect', 'r')
        self.assertIsNone(inspected['configurations'][0]['ranking_fingerprint'])
        self.assertIsNone(inspected['configurations'][0]['build_identity'])

    def test_measurement_cohorts_never_publish_a_pooled_quality_rate(self):
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE config_revisions SET measurement_fingerprint='measurement-B', "
                       "metric_rule_version=2 WHERE id='rev2'")
        result = self.result()
        self.assertIsNone(result['coverage']['top1_rate'])
        self.assertIsNone(result['coverage']['top3_rate'])
        self.assertIsNone(result['coverage']['top1_match_rate'])
        self.assertEqual(result['coverage']['quality_rate_status'], 'unavailable_across_measurement_fingerprints')
        groups = [g for g in result['groups'] if g['ranking_fingerprint']=='ranking-A'
                  and g['text_kind']=='chinese' and g['presentation']=='candidates_requested']
        self.assertEqual({g['measurement_fingerprint'] for g in groups}, {'measurement-A','measurement-B'})
        self.assertTrue(all(g['quality_rate_status']=='available_within_measurement_fingerprint' for g in groups))
        issues = self.result('ranking-issues', '--min-count', '1')['issues']
        relevant = [i for i in issues if i['ranking_fingerprint']=='ranking-A' and i['caret']==3
                    and i['preceding_context']=='' and i['matches_custom_phrase']==0
                    and i['text_kind']=='chinese' and i['selected_prefix_valid']==1]
        self.assertEqual(sorted((i['measurement_fingerprint'], i['occurrences']) for i in relevant),
                         [('measurement-A', 2), ('measurement-B', 1)])

    def test_every_command_reports_identity_coverage_for_its_cohort(self):
        for command, args in [('summary', ()), ('ranking-issues', ('--min-count','1')),
                              ('inspect', ('a',)), ('timing', ())]:
            result = self.result(command, *args)
            coverage = result['identity_coverage']
            self.assertIn('cohort', coverage)
            for layer in ('ranking','settings','measurement','build'):
                self.assertEqual(set(coverage[layer]), {'known','unknown','distinct','identities'})
                self.assertEqual(coverage[layer]['known'] + coverage[layer]['unknown'],
                                 sum(item['count'] for item in coverage[layer]['identities']))

    def test_local_calendar_date_and_invalid_arguments(self):
        previous = os.environ.get('TZ')
        try:
            os.environ['TZ']='Asia/Taipei'; time.tzset()
            self.assertEqual(self.quality.timestamp('2026-09-07'),'2026-09-06T16:00:00.000Z')
        finally:
            if previous is None: os.environ.pop('TZ',None)
            else: os.environ['TZ']=previous
            time.tzset()
        for args in [('summary','--since','nonsense'),('summary','--since','2026-09-07T12:00:00'),
                     ('summary','--since',STAMP,'--until',STAMP),('ranking-issues','--min-count','0')]:
            self.run_cli(*args,success=False)

    def test_formats_are_lossless_and_readable(self):
        for args in [('summary',),('ranking-issues','--min-count','1'),('inspect','n')]:
            table = self.run_cli(*args)
            self.assertTrue(table.strip())
            exported = list(csv.DictReader(io.StringIO(self.run_cli(*args,'--format','csv'))))
            self.assertTrue(exported)
            self.assertEqual(set(exported[0]), {'path','value'})
        self.assertIn('😀',self.run_cli('inspect','n'))
        self.assertIn('N/A',self.run_cli('summary','--kind','unknown'))
        self.assertIn('ranking-A',self.run_cli('summary'))

    def test_empty_missing_schema_and_readonly(self):
        empty = Path(self.temp.name)/'empty.sqlite3'; empty_db(empty).close()
        result = self.result(db=empty)
        self.assertEqual(result['coverage']['valid'],0)
        self.assertIsNone(result['coverage']['top1_rate'])
        self.assertIsNone(result['coverage']['top3_rate'])
        self.assertEqual(result['groups'],[])
        missing=Path(self.temp.name)/'missing.sqlite3'
        self.assertIn('does not exist',self.run_cli('summary',db=missing,success=False))
        self.assertFalse(missing.exists())
        before=hashlib.sha256(self.db.read_bytes()).hexdigest()
        with contextlib.closing(self.quality.connect(self.db)) as connection:
            with self.assertRaises(sqlite3.OperationalError):
                connection.execute("DELETE FROM compositions")
        self.result(); self.result('inspect','a')
        self.assertEqual(before,hashlib.sha256(self.db.read_bytes()).hexdigest())
        for statement in ['PRAGMA user_version=1','DROP TABLE candidate_decisions',
                          'ALTER TABLE config_revisions ADD COLUMN foreign_value TEXT']:
            bad=Path(self.temp.name)/('bad'+str(len(statement))+'.sqlite3')
            db=empty_db(bad); db.execute(statement); db.close()
            self.assertIn('incompatible',self.run_cli('summary',db=bad,success=False))
        self.assertIn('not found',self.run_cli('inspect','missing',success=False))

    def test_pair_counters_cover_every_known_rank_decision(self):
        # No record of the base fixture has a hash.
        base = self.result()['coverage']
        self.assertEqual((base['pair_identity'], base['pair_unavailable']), (0, base['known_rank']))
        db = Path(self.temp.name) / 'replay.sqlite3'
        replay_fixture(db)
        summary = self.result(db=db)
        coverage = summary['coverage']
        # r5 has no evidence row and r12 chose the empty text: no span, no text, no hash. The text-free r7 and r11 do.
        self.assertEqual((coverage['known_rank'], coverage['pair_identity'], coverage['pair_unavailable']), (12, 10, 2))
        for group in summary['groups']:
            self.assertEqual(group['pair_identity'] + group['pair_unavailable'], group['known_rank'])
        windowed = self.result('summary', '--since', '2026-09-01', '--until', '2026-09-08', db=db)['coverage']
        self.assertEqual(windowed['pair_identity'] + windowed['pair_unavailable'], windowed['known_rank'])
        # Both hashes reach inspect through the decoded pages, text-free or not.
        for cid, raw, word in [('r1', 'kaihui', '开会'), ('r7', 'ke', '课')]:
            decision = self.result('inspect', cid, db=db)['decisions'][0]
            self.assertEqual(decision['snapshot']['codeHash'], fake_hash('code', raw))
            selected = decision['snapshot']['candidates'][decision['selected_display_index']]
            self.assertEqual(selected['textHash'], fake_hash('text', word))
        self.assertIn('$.decisions[0].snapshot.codeHash | "' + fake_hash('code', 'kaihui') + '"',
                      self.run_cli('inspect', 'r1', db=db))

    def run_learning(self, *args, rows=None, name='learning.sqlite3', **options):
        db = Path(self.temp.name) / name
        if not db.exists():
            learning_fixture(db, learning_rows() if rows is None else rows)
        with utc():
            return self.result('learning', *(args or LEARNING_ARGS), db=db, **options)

    def test_learning_reports_every_metric_with_wilson_bounds_and_statuses(self):
        result = self.run_learning()
        rate = lambda numerator, denominator: dict(
            numerator=numerator, denominator=denominator,
            rate=numerator / denominator if denominator else None,
            wilson_low=self.quality.wilson(numerator, denominator)[0],
            wilson_high=self.quality.wilson(numerator, denominator)[1],
            status='no_verdict_below_200_units')
        self.assertEqual(result['window'], dict(days=28, first_day='2026-09-03', last_day='2026-09-30',
                                                since='2026-09-03T00:00:00.000Z', until='2026-10-01T00:00:00.000Z',
                                                until_exclusive=True))
        # Two decisions follow another metric rule, one of them an unknown one; the window and the cohort leave the
        # rest out. The four without a pair identity stay in the cohort and are counted.
        self.assertEqual(result['metric_scope'], dict(
            rule_fingerprint='measurement-A', policy='latest_compatible_metric_rules', unit='known_rank_decision',
            known_rank_decisions=30, included_decisions=28, excluded_decisions=2, excluded_unknown_decisions=1))
        self.assertEqual(result['pair_coverage'], dict(pair_identity=24, pair_unavailable=4, text_without_hash=1))
        self.assertEqual(result['units'], dict(decisions=24, pairs=9, words=8))
        first_seen = rate(4, 9)
        self.assertEqual(result['l_ttl'], dict(
            pairs_first_miss=6, histogram={'1': 1, '2': 1, '3+': 1, 'never': 3}, median_selections_to_learn=2,
            learned_after_one_rate=rate(1, 6), first_seen_within_7_days_share=first_seen))
        self.assertEqual(result['l_futile'], dict(pairs_with_3_or_more_selections=5, futile_rate=rate(1, 5)))
        self.assertEqual(result['l_util'], dict(
            pairs_with_hit=6, pairs_regressed=2, pairs_censored_at_window_end=4, median_hits_until_regression=2,
            regression_rate=rate(2, 6)))
        self.assertEqual(result['l_avoid'], dict(
            misses=14, avoidable_miss_rate=rate(8, 14), learned_provenance_miss_rate=rate(3, 14),
            first_seen_within_7_days_share=first_seen))
        self.assertEqual(result['l_reuse'], dict(words_first_chosen_in_days_1_to_14=6, reuse_rate=rate(2, 6)))
        self.assertEqual(result['instrument_constants']['minimum_units'], 200)
        self.assertEqual(set(result['identity_coverage']),
                         {'cohort', 'unit', 'ranking', 'settings', 'measurement', 'build'})

    def test_learning_pair_identity_follows_the_consumed_span(self):
        # The leading segment of nihaoshijie joins the whole-input pair, so pair 你好 has 4 decisions, not 3 and 1.
        rows = [(0, 0, 'nihao', '你好', 3, dict()), (1, 0, 'nihaoshijie', '你好', 1, dict(end=5))]
        result = self.run_learning(rows=rows, name='segment.sqlite3')
        self.assertEqual(result['units'], dict(decisions=2, pairs=1, words=1))
        self.assertEqual(result['l_ttl']['histogram'], {'1': 1, '2': 0, '3+': 0, 'never': 0})
        # Without the span the same decision is not guessed to be the whole input.
        rows = [(0, 0, 'nihao', '你好', 3, dict()), (1, 0, 'nihaoshijie', '你好', 1, dict(evidence=False))]
        result = self.run_learning(rows=rows, name='unknown-span.sqlite3')
        self.assertEqual((result['units'], result['pair_coverage']['pair_unavailable']),
                         (dict(decisions=1, pairs=1, words=1), 1))

    def test_learning_needs_a_28_day_window_for_reuse_and_200_units_for_a_verdict(self):
        week = self.run_learning('--days', '7', *LEARNING_ARGS)
        self.assertEqual(week['window']['first_day'], '2026-09-24')
        self.assertEqual(week['l_reuse']['reuse_rate'], dict(
            numerator=None, denominator=None, rate=None, wilson_low=None, wilson_high=None,
            status='needs_28_day_window'))
        # A window with nothing in it has null rates, not zero.
        self.assertEqual(week['units'], dict(decisions=0, pairs=0, words=0))
        self.assertIsNone(week['l_ttl']['learned_after_one_rate']['rate'])
        self.assertIsNone(week['l_ttl']['median_selections_to_learn'])
        emoji = self.run_learning('--kind', 'emoji', *LEARNING_ARGS)
        self.assertEqual(emoji['units']['decisions'], 0)
        self.assertIsNone(emoji['l_avoid']['avoidable_miss_rate']['rate'])
        # 210 pairs, each missed once: enough for a verdict.
        rows = [(20, number % 60, f'code{number}', f'词{number}', 2, dict()) for number in range(210)]
        large = self.run_learning(rows=rows, name='large.sqlite3')
        self.assertEqual(large['l_ttl']['learned_after_one_rate']['status'], 'available')
        self.assertEqual(large['l_ttl']['learned_after_one_rate']['rate'], 0.0)
        self.assertEqual(large['l_avoid']['avoidable_miss_rate'], dict(
            numerator=0, denominator=210, rate=0.0, wilson_low=0.0, wilson_high=self.quality.wilson(0, 210)[1],
            status='available'))
        self.assertEqual(large['l_reuse']['reuse_rate']['status'], 'no_verdict_below_200_units')

    def test_learning_counts_pair_coverage_on_every_window(self):
        db = Path(self.temp.name) / 'learning.sqlite3'
        learning_fixture(db, learning_rows())
        coverage = self.result(db=db)['coverage']
        # The two other-rule decisions and the one before the window carry hashes; the four others do not.
        self.assertEqual((coverage['known_rank'], coverage['pair_identity'], coverage['pair_unavailable']), (31, 27, 4))

    def test_learning_never_pools_devices_and_reads_exports(self):
        exported = self.export_file()
        document = json.loads(exported.read_text())
        document['source_id'] = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        other = Path(self.temp.name) / 'B.json'
        other.write_text(json.dumps(document))
        window = ('--until', '2026-09-08')
        message = self.run_cli('learning', '--input', str(exported), '--input', str(other), *window, success=False)
        self.assertIn('never link across devices', message)
        # The local database counts as a source of its own beside two exports.
        self.run_cli('learning', '--input', str(other), *window, success=False)
        one = json.loads(self.run_cli('learning', '--exports-only', '--input', str(other), *window, '--format', 'json'))
        self.assertEqual(len(one['sources']), 1)
        self.assertNotIn('by_source', one)
        chosen = json.loads(self.run_cli('learning', '--input', str(exported), '--input', str(other), *window,
                                         '--source', document['source_id'], '--format', 'json'))
        self.assertEqual(chosen['filters']['source'], document['source_id'])
        self.assertNotIn('by_source', chosen)
        # The window is derived from --days.
        self.assertIn('derives --since', self.run_cli('learning', '--since', '2026-09-01', success=False))
        self.assertIn('local calendar date', self.run_cli('learning', '--until', '2026-09-08T12:00:00Z', success=False))

    def test_learning_prints_in_every_format(self):
        db = Path(self.temp.name) / 'learning.sqlite3'
        learning_fixture(db, learning_rows())
        with utc():
            table = self.run_cli('learning', *LEARNING_ARGS, db=db)
            exported = self.run_cli('learning', *LEARNING_ARGS, '--format', 'csv', db=db)
        lines = list(csv.DictReader(io.StringIO(exported)))
        self.assertIn('$.l_ttl.histogram.never | 3', table)
        self.assertIn('$.l_avoid.avoidable_miss_rate.wilson_low |', table)
        self.assertTrue(any(row['path'] == '$.l_reuse.reuse_rate.status' for row in lines))

    def test_text_free_records_keep_rank_metrics(self):
        before = self.result()['coverage']
        self.assertEqual(before['text_free'], 0)
        def overall():
            return self.result('trend', '--days', '7', '--until', '2026-09-08')['series']['overall'][-1]['rolling_28d']
        trend_before = overall()
        self.assertIn('a', [cid for issue in self.result('ranking-issues', '--min-count', '1')['issues'] for cid in issue['composition_ids']])
        db = sqlite3.connect(self.db)
        self.addCleanup(db.close)

        def strip(raw):
            page = json.loads(raw)
            page.update(rawInput='', selectedPrefix='', precedingContext='', textCaptured=False)
            for candidate in page['candidates']:
                candidate['text'] = ''
            return json.dumps(page)
        for cid in ('a', 'c', 'd'):
            snapshot, first = db.execute('SELECT snapshot_json,first_page_json FROM candidate_decisions WHERE composition_id=?', (cid,)).fetchone()
            db.execute('UPDATE candidate_decisions SET selected_text=NULL,snapshot_json=?,first_page_json=? WHERE composition_id=?',
                       (strip(snapshot), strip(first), cid))
            db.execute("UPDATE commits SET text='' WHERE composition_id=?", (cid,))
        db.commit()
        after = self.result()['coverage']
        for key in ('valid', 'known_rank', 'unknown_rank', 'comparable', 'top1_selected', 'top3_selected',
                    'top1_matches', 'top1_rate', 'top3_rate', 'top1_match_rate', 'mean_display_rank', 'mean_native_rank'):
            self.assertEqual(after[key], before[key], key)
        self.assertEqual(after['text_free'], 3)
        # The counts stay when the text goes, so no decision loses its length bucket.
        self.assertEqual((before['length_unavailable'], after['length_unavailable']), (0, 0))
        trend_after = overall()
        self.assertEqual(trend_after['by_selection_length'], trend_before['by_selection_length'])
        self.assertEqual((trend_before['text_free'], trend_after['text_free'], trend_after['length_unavailable']),
                         (0, 3, 0))
        issues = self.result('ranking-issues', '--min-count', '1')['issues']
        self.assertFalse({'a', 'c', 'd'} & {cid for issue in issues for cid in issue['composition_ids']},
                         'text-free decisions never form recurring-choice issues')
        inspected = json.dumps(self.result('inspect', 'a'), ensure_ascii=False)
        self.assertNotIn('shi', inspected)
        self.assertNotIn('使', inspected)
        self.assertIn('series', self.result('trend', '--days', '7'))

    def test_incomplete_evidence_bounded_ids_and_concurrent_reader(self):
        db = sqlite3.connect(self.db)
        self.addCleanup(db.close)
        # Corrupted or absent rank evidence never promotes a candidate to rank one.
        db.execute("UPDATE candidate_decisions SET selected_text='different' WHERE composition_id='a'")
        db.execute("UPDATE candidate_decisions SET first_page_json=json_set(first_page_json,'$.generation',99) WHERE composition_id='b'")
        db.commit()
        result = self.result('ranking-issues','--min-count','1')
        normal = next(x for x in result['issues'] if x['ranking_fingerprint']=='ranking-A'
                      and x['measurement_fingerprint']=='measurement-A'
                      and x['caret']==3 and x['preceding_context']=='' and x['text_kind']=='chinese'
                      and x['matches_custom_phrase']==0)
        self.assertEqual(normal['composition_ids'],['c'])
        # Duplicate one valid envelope into six separate compositions to exceed the sample bound.
        for index in range(6):
            cid=f'copy-{index}'
            source=dict(zip([x[1] for x in db.execute('PRAGMA table_info(compositions)')],
                            db.execute("SELECT * FROM compositions WHERE id='c'").fetchone()))
            source['id']=cid; insert(db,'compositions',**source)
            source=dict(zip([x[1] for x in db.execute('PRAGMA table_info(commits)')],
                            db.execute("SELECT * FROM commits WHERE composition_id='c'").fetchone()))
            source.update(id='commit-'+cid,composition_id=cid); insert(db,'commits',**source)
            source=dict(zip([x[1] for x in db.execute('PRAGMA table_info(candidate_decisions)')],
                            db.execute("SELECT * FROM candidate_decisions WHERE composition_id='c'").fetchone()))
            source.update(id='decision-'+cid,composition_id=cid,commit_id='commit-'+cid)
            insert(db,'candidate_decisions',**source)
        db.commit()
        issue=self.result('ranking-issues')['issues'][0]
        self.assertEqual(issue['occurrences'],7)
        self.assertEqual(len(issue['composition_ids']),5)
        # A reserved rollback-journal writer may coexist with this read-only query.
        db.execute('BEGIN IMMEDIATE')
        db.execute("UPDATE compositions SET app_bundle_id='uncommitted' WHERE id='c'")
        self.assertEqual(self.result('inspect','c')['composition']['app_bundle_id'],"app'quoted")
        db.rollback()

    def test_snapshot_consistency_during_intervening_write(self):
        ready, committed = threading.Event(), threading.Event()
        failures=[]

        def writer():
            try:
                with sqlite3.connect(self.db,timeout=3) as db:
                    db.execute("UPDATE candidate_decisions SET outcome='unknown' WHERE composition_id='a'")
                    ready.set()
                committed.set()
            except Exception as error:
                failures.append(error)
                ready.set()

        original=self.quality.rows
        started=False
        thread=threading.Thread(target=writer)

        def read_rows(db, sql, parameters=None):
            nonlocal started
            result=original(db,sql,parameters)
            if not started:
                started=True
                thread.start()
                self.assertTrue(ready.wait(2),'writer did not reach commit')
                self.assertFalse(committed.is_set(),'writer committed through the active read snapshot')
            return result

        with mock.patch.object(self.quality,'rows',side_effect=read_rows):
            result=self.result()
        thread.join(4)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures,[])
        self.assertTrue(committed.is_set())
        self.assertEqual(result['coverage']['valid'],12)
        self.assertEqual(sum(g['valid'] for g in result['groups']),12)
        self.assertEqual(self.result()['coverage']['valid'],11)

    def test_timing_legacy_unknown_and_one_snapshot_per_composition(self):
        legacy = self.result('timing')
        self.assertEqual(legacy['coverage']['unavailable'], 21)
        self.assertEqual(legacy['coverage']['timing_v1'], 0)
        self.assertIsNone(legacy['durations']['ended']['postEditWait']['p50'])
        samples = [dict(sequence=0, offset=0, kind='typing', isRepeat=False),
                   dict(sequence=1, offset=0.2, interval=0.2, kind='typing', isRepeat=False),
                   dict(sequence=256, offset=4, interval=0.4, kind='ai_tab', isRepeat=True)]
        value = dict(version=1, keySamples=samples, droppedKeyCount=254, endedOffset=4,
                     postEditWait=0.8, observedVisibleDuration=0.5, phaseWait=0.3,
                     phaseObservedVisibleDuration=0.2, visibilityObservationInterval=0.1)
        with contextlib.closing(sqlite3.connect(self.db)) as db, db:
            db.execute("UPDATE compositions SET operations_json=? WHERE id='a'", (json.dumps(dict(OPS, timing=value)),))
            # Decision snapshots deliberately contain the same data. Never sum these copies.
            db.execute('UPDATE candidate_decisions SET operations_json=?', (json.dumps(dict(OPS, timing=value)),))
            unfinished = dict(value)
            unfinished.pop('endedOffset')
            unfinished.pop('observedVisibleDuration')
            unfinished['keySamples'] = []
            unfinished['droppedKeyCount'] = 0
            db.execute("UPDATE compositions SET operations_json=? WHERE id='b'", (json.dumps(dict(OPS, timing=unfinished)),))
            db.execute("UPDATE compositions SET operations_json=? WHERE id='c'", (json.dumps(dict(OPS, timing=dict(version=2))),))
        result = self.result('timing')
        self.assertEqual(result['scope'], 'composition_operations_once')
        self.assertEqual(result['coverage'], dict(compositions=21, timing_v1=2, unavailable=18, unsupported_version=1,
                                                ended=1, unfinished=1, truncated_compositions=1, dropped_keys=254, retained_keys=3))
        intervals = result['key_intervals']['all']
        self.assertEqual(intervals['count'], 2)
        self.assertEqual(intervals['unknown'], 1)
        self.assertAlmostEqual(intervals['p50'], 0.3)
        self.assertAlmostEqual(intervals['p95'], 0.39)
        self.assertEqual(result['key_intervals']['by_category_repeat'][0]['kind'], 'ai_tab')
        self.assertEqual(result['key_intervals']['by_category_repeat'][0]['intervals']['p50'], 0.4)
        self.assertEqual(result['durations']['ended']['observedVisibleDuration']['p50'], 0.5)
        self.assertIsNone(result['durations']['unfinished_observations']['observedVisibleDuration']['p50'])
        self.assertEqual(self.result('timing', '--kind', 'emoji')['coverage']['compositions'], 1)
        self.assertEqual(self.result('timing', '--kind', 'emoji')['coverage']['timing_v1'], 0)
        self.assertNotIn('rawInput', json.dumps(result))

    def test_timing_actual_controller_writer(self):
        result = self.result('timing', db=ENGINE_DB)
        self.assertEqual(result['coverage']['compositions'], 67)
        self.assertGreater(result['coverage']['timing_v1'], 0)
        self.assertGreater(result['key_intervals']['all']['count'], 0)
        # This engine/controller fixture does not observe native panel visibility.
        self.assertIsNone(result['visibility_observation_interval']['p50'])
        self.assertEqual(result['visibility_observation_interval']['count'], 0)

    def test_actual_engine_candidates_carry_ranking_facts(self):
        with contextlib.closing(sqlite3.connect(ENGINE_DB.as_uri() + '?mode=ro', uri=True)) as db:
            facts = set(db.execute('''SELECT json_extract(c.value,'$.type'), json_extract(c.value,'$.corrected')
                FROM candidate_decisions d, json_each(d.snapshot_json,'$.candidates') c
                WHERE json_extract(d.snapshot_json,'$.page')=0'''))
            composition, decision = db.execute('''SELECT composition_id, id FROM candidate_decisions
                WHERE json_extract(snapshot_json,'$.page')=0 AND json_array_length(snapshot_json,'$.candidates')=9
                  AND json_extract(snapshot_json,'$.candidates[0].evidence') IS NOT NULL
                ORDER BY rowid DESC LIMIT 1''').fetchone()
        self.assertTrue({('phrase', 0), ('phrase', 1), ('user_phrase', 0)} <= facts, facts)
        inspected = self.result('inspect', composition, db=ENGINE_DB)
        candidates = next(d for d in inspected['decisions'] if d['id'] == decision)['snapshot']['candidates']
        self.assertEqual(len(candidates), 9)
        for candidate in candidates:
            fields = candidate['evidence'].split(',')
            self.assertEqual(len(fields), 8)
            self.assertEqual((candidate['type'], candidate['corrected']), (fields[6], fields[7] == '1'))

    def test_actual_engine_counts_match_the_stored_text(self):
        with contextlib.closing(sqlite3.connect(ENGINE_DB.as_uri() + '?mode=ro', uri=True)) as db:
            self.assertEqual(db.execute('PRAGMA user_version').fetchone()[0], 4)
            self.assertGreater(db.execute(
                'SELECT count(*) FROM candidate_decisions WHERE selected_text IS NOT NULL').fetchone()[0], 0)
            self.assertGreater(db.execute("SELECT count(*) FROM commits WHERE text != ''").fetchone()[0], 0)
            self.assertEqual(db.execute('''SELECT count(*) FROM candidate_decisions WHERE selected_text IS NOT NULL
                AND selected_character_count IS NOT length(selected_text)''').fetchone()[0], 0)
            self.assertEqual(db.execute('''SELECT count(*) FROM commits WHERE text != ''
                AND character_count IS NOT length(text)''').fetchone()[0], 0)
        # Every row is written by v4 in text mode, so the buckets cover every known-rank decision.
        week = self.result('trend', '--days', '7', db=ENGINE_DB)['series']['overall'][-1]['rolling_7d']
        self.assertGreater(week['known_rank'], 0)
        self.assertEqual(week['length_unavailable'], 0)
        self.assertEqual(sum(b['known_rank'] for b in week['by_selection_length'].values()), week['known_rank'])

    def test_actual_engine_schema_and_controller_cohort(self):
        db=sqlite3.connect(ENGINE_DB.as_uri()+'?mode=ro',uri=True)
        self.addCleanup(db.close)
        result=self.result(db=ENGINE_DB)
        # The deferred-toggle then panel-selection fixture adds one valid composition,
        # decision and issued candidate commit; the toggle itself adds no decision.
        # The five custom-phrase matrix cases each add one valid decision/commit.
        # The five candidate-fact cases (phrase, user_phrase, fuzzy, lv, English) add one each as well.
        # The post-commit window cases add 17 compositions and commits and 16 decisions (one is a direct comma),
        # one decision of which was committed without a client.
        self.assertEqual([result['coverage'][x] for x in ['compositions','decisions','commits']],[67,62,64])
        self.assertEqual(result['coverage']['valid'],53)
        # Every known-rank decision of the real capture is hashed or counted as without a pair identity.
        coverage = result['coverage']
        self.assertEqual(coverage['pair_identity'] + coverage['pair_unavailable'], coverage['known_rank'])
        self.assertGreater(coverage['pair_identity'], 0)
        self.assertEqual(result['coverage']['regular_issued'],54)
        self.assertEqual(result['coverage']['regular_not_issued'],2)
        # Three fixtures explicitly select emoji; positional selections may also be emoji as the corpus changes.
        self.assertGreaterEqual(sum(g['valid'] for g in result['groups'] if g['text_kind']=='emoji'),3)
        cohort=self.result('summary','--app','inkflow.recording-client',db=ENGINE_DB)
        self.assertGreater(cohort['coverage']['valid'],0)
        issues=self.result('ranking-issues','--min-count','1',db=ENGINE_DB)
        self.assertGreater(len(issues['issues']),0)
        selected=issues['issues'][0]['composition_ids'][0]
        inspected=self.result('inspect',selected,db=ENGINE_DB)
        self.assertTrue(inspected['commits'][0]['insertion_issued'])
        self.assertEqual(db.execute('PRAGMA foreign_key_check').fetchall(),[])
        # Case (a): two Backspaces covered 你好, the next code ended the window and it rides the second composition.
        carried = db.execute('''SELECT json_extract(w.value,'$.commitID') FROM compositions c,
            json_each(c.operations_json,'$.postCommitWindows') w WHERE json_extract(w.value,'$.end')='next_code'
            AND json_extract(w.value,'$.deletions')=2 AND json_extract(w.value,'$.leadingDeletions')=2''').fetchall()
        self.assertEqual(len(carried), 1)
        owner = db.execute('SELECT composition_id FROM commits WHERE id=?', carried[0]).fetchone()[0]
        windows = self.result('inspect', owner, db=ENGINE_DB)['windows']
        self.assertEqual(windows, [dict(commit_id=carried[0][0], end='next_code', elapsed_ms=windows[0]['elapsed_ms'],
                                        deletions=2, forward_deletions=0, undo=0, direct_text=0, paste=0,
                                        leading_deletions=2, leading_forward_deletions=0, leading_undo=0)])
        self.assertTrue(0 <= windows[0]['elapsed_ms'] <= 10000)
        ends = result['coverage']['windows_by_end']
        self.assertTrue(ends['next_code'] > 0 and ends['client_changed'] > 0 and ends['deactivated'] > 0, ends)
        self.assertEqual(result['coverage']['commit_windows'], sum(ends.values()))
        exported = Path(self.temp.name) / 'engine.json'
        self.run_cli('export', '--output', str(exported), db=ENGINE_DB)
        exchanged = self.result('summary', '--exports-only', '--input', str(exported))
        self.assertEqual(exchanged['coverage'], result['coverage'])
        self.assertEqual(exchanged['groups'], result['groups'])
        for command, options in [('timing', []), ('trend', ['--days', '28', '--until', '2026-10-01'])]:
            local = self.result(command, *options, db=ENGINE_DB)
            imported = self.result(command, *options, '--exports-only', '--input', str(exported))
            for key, value in local.items():
                if key not in ('filters', 'command'):
                    self.assertEqual(imported[key], value, f'{command}.{key}')


if __name__ == '__main__':
    unittest.main(verbosity=2)
