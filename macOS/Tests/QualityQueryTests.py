"""Query fixtures use the schema of the database created by the Swift capture test."""
import contextlib
import csv
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


def insert(db, table, **values):
    db.execute(f'INSERT INTO {table} ({",".join(values)}) VALUES ({",".join("?" for _ in values)})', list(values.values()))


def empty_db(path):
    db = sqlite3.connect(path)
    db.execute('PRAGMA foreign_keys=ON')
    db.execute('PRAGMA application_id=1229345073')
    db.execute('PRAGMA user_version=3')
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
                   kind='candidate' if regular else 'punctuation', insertion_issued=issued)
        page = dict(generation=7, rawInput='shi', caret=caret, selectedPrefix='', selectedPrefixValid=prefix_valid,
                    precedingContext=context, configurationRevisionID=revision, configuration={},
                    page=0 if rank == 1 else 1, pageSize=3, highlightedDisplayIndex=0,
                    presentation=presentation, capturedAt=STAMP,
                    candidates=[dict(text=chosen, displayIndex=0, displayRank=rank,
                                     nativeIndex=0 if rank == 1 else 1, nativeRank=1 if rank == 1 else 5)])
        first_page = dict(page, page=0, candidates=[dict(text='是', displayIndex=0, displayRank=1, nativeIndex=0, nativeRank=1)])
        insert(db, 'candidate_decisions', id=f'decision-{cid}', composition_id=cid, config_revision_id=revision,
               commit_id=commit_id, occurred_at=STAMP, sequence=0, trigger='space' if regular else 'punctuation',
               outcome=outcome, selected_display_index=index, selected_text=chosen, text_kind=kind,
               snapshot_json=json.dumps(page, ensure_ascii=False), first_page_json=json.dumps(first_page) if first else None,
               visited_pages_json='[]', page_history_truncated=truncated, dropped_page_count=2*truncated,
               operations_json=json.dumps(OPS), regular_ranked_selection=regular, matches_custom_phrase=custom,
               unknown_rank_reason='ambiguous_candidate_text' if index is None else None)

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
           app_bundle_id='other.app', outcome='committed', operations_json=json.dumps(OPS),
           page_history_truncated=0, dropped_page_count=0)
    insert(db, 'commits', id='raw-commit', composition_id='raw-only', issued_at=STAMP, text='raw',
           kind='raw_return', insertion_issued=1)
    db.commit()
    db.close()


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
        for mutation in ('version', 'missing-parent', 'bad-json', 'duplicate', 'shape', 'type', 'range', 'huge-integer', 'offset-time'):
            doc = json.loads(a.read_text())
            if mutation == 'version': doc['format_version'] = 99
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
            self.run_cli('summary', '--exports-only', '--input', str(bad), success=False)
        bad.write_text('{')
        self.run_cli('summary', '--input', str(bad), success=False)
        doc = json.loads(a.read_text()); doc['tables']['commits'][0]['text'] = 'conflict'
        bad.write_text(json.dumps(doc))
        self.assertIn('conflicting', self.run_cli('summary', '--input', str(a), '--input', str(bad), success=False))
        self.run_cli('export', '--output', str(self.db), success=False)
        self.run_cli('export', '--output', str(a), success=False)

    def test_native_settings_export_is_readable_and_preserves_database(self):
        executable = os.environ.get('INKFLOW_QUALITY_EXPORT_FIXTURE')
        if not executable:
            self.skipTest('Native export fixture not built; use test-quality-query.sh')
        import subprocess
        with sqlite3.connect(self.db) as db:
            db.execute("UPDATE commits SET text=? WHERE id='raw-commit'", ('raw\0tail',))
        before = self.db.read_bytes()
        out = Path(self.temp.name) / 'native.json'
        subprocess.run([executable, str(self.db), str(out)], check=True, capture_output=True)
        result = self.result('summary', '--exports-only', '--input', str(out))
        self.assertEqual(result['coverage'], self.result()['coverage'])
        self.assertEqual(self.db.read_bytes(), before)
        document = json.loads(out.read_text())
        self.assertEqual(len(document['tables']), 6)
        self.assertEqual(next(r['text'] for r in document['tables']['commits'] if r['id'] == 'raw-commit'), 'raw\0tail')
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

    def test_text_free_records_keep_rank_metrics(self):
        before = self.result()['coverage']
        self.assertEqual(before['text_free'], 0)
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
        self.assertEqual(result['coverage']['compositions'], 45)
        self.assertGreater(result['coverage']['timing_v1'], 0)
        self.assertGreater(result['key_intervals']['all']['count'], 0)
        # This engine/controller fixture does not observe native panel visibility.
        self.assertIsNone(result['visibility_observation_interval']['p50'])
        self.assertEqual(result['visibility_observation_interval']['count'], 0)

    def test_actual_engine_schema_and_controller_cohort(self):
        db=sqlite3.connect(ENGINE_DB.as_uri()+'?mode=ro',uri=True)
        self.addCleanup(db.close)
        result=self.result(db=ENGINE_DB)
        # The deferred-toggle then panel-selection fixture adds one valid composition,
        # decision and issued candidate commit; the toggle itself adds no decision.
        # The five custom-phrase matrix cases each add one valid decision/commit.
        self.assertEqual([result['coverage'][x] for x in ['compositions','decisions','commits']],[45,41,42])
        self.assertEqual(result['coverage']['valid'],33)
        self.assertEqual(result['coverage']['regular_issued'],34)
        self.assertEqual(result['coverage']['regular_not_issued'],1)
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
