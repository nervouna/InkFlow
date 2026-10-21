#!/usr/bin/env python3
"""Read-only queries for InkFlow quality schema v4 (stdlib only)."""
import argparse
from contextlib import closing
import csv
from copy import copy
from datetime import date, datetime, time, timedelta, timezone
from html import escape
from math import sqrt
import json
import os
from pathlib import Path
import sqlite3
from statistics import NormalDist, median
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[4] / 'macOS/Tools'))
import quality_exchange

DEFAULT_DB = Path.home() / 'Library/Application Support/InkFlow/quality.sqlite3'
REPOSITORY = Path(__file__).resolve().parents[4]
KINDS = ('chinese', 'english', 'emoji', 'mixed', 'symbol', 'number', 'other', 'unknown')
TABLE_COLUMNS = {
    'recording_runs': 'id started_at ended_at status engine_version build_metadata_json metric_rule_version stats_json error_code',
    'config_revisions': ('id fingerprint created_at applied_config_json build_metadata_json engine_version '
                         'metric_rule_version ranking_fingerprint settings_fingerprint '
                         'measurement_fingerprint build_identity'),
    'compositions': 'id run_id started_at ended_at app_bundle_id client_id outcome page_history_truncated dropped_page_count outcome_reason operations_json',
    'commits': 'id composition_id issued_at text kind insertion_issued client_id character_count',
    'candidate_decisions': ('id composition_id config_revision_id commit_id occurred_at sequence trigger outcome '
                            'selected_display_index selected_text text_kind snapshot_json first_page_json '
                            'visited_pages_json page_history_truncated dropped_page_count operations_json '
                            'regular_ranked_selection matches_custom_phrase unknown_rank_reason path_reason '
                            'selected_character_count'),
    'effectiveness_events': 'id run_id occurred_at source event reason count milliseconds',
}
# A first page belongs to a snapshot when these agree.
SAME_GENERATION_FIELDS = ('generation', 'rawInput', 'caret', 'selectedPrefix', 'selectedPrefixValid',
                          'precedingContext', 'configurationRevisionID', 'pageSize')
GROUP = ('ranking_fingerprint', 'measurement_fingerprint', 'text_kind', 'presentation')
ISSUE_GROUP = ('ranking_fingerprint', 'measurement_fingerprint', 'raw_input', 'caret', 'selected_prefix', 'selected_prefix_valid',
               'preceding_context', 'first_page_top1', 'selected_text', 'text_kind', 'matches_custom_phrase')
# Post-commit windows ride the composition that follows their commit: one `windows` row per commit.
WINDOW_KEYS = {'commit_id': 'commitID', 'end': 'end', 'elapsed_ms': 'elapsedMilliseconds', 'deletions': 'deletions',
               'forward_deletions': 'forwardDeletions', 'undo': 'undo', 'direct_text': 'directText',
               'paste': 'paste', 'leading_deletions': 'leadingDeletions',
               'leading_forward_deletions': 'leadingForwardDeletions', 'leading_undo': 'leadingUndo'}
WINDOW_ENDS = ('next_code', 'client_changed', 'deactivated', 'timeout')
WINDOW_COLUMNS = ', '.join(f'w."{column}" AS window_{column}' for column in WINDOW_KEYS if column != 'commit_id')
OPERATIONS = {'keypresses': 'keypresses', 'page_requests': 'pageRequests', 'page_turns': 'pageTurns',
              'candidate_moves': 'candidateMoves', 'preedit_edits': 'preeditEdits'}
# Candidate `type` sets of the L metrics (docs/input-quality-metrics.md section 6): instrument constants of the rule.
LEARNED_TYPES = ('user_phrase', 'english_personal_1', 'english_personal_2', 'english_personal_3',
                 'mixed_personal_0', 'mixed_personal_1', 'mixed_personal_2', 'mixed_personal_3')
DICTIONARY_TYPES = ('phrase', 'user_table')
COMPARABLE = 'valid AND display_rank IS NOT NULL AND first_page_top1 IS NOT NULL'


def type_set(column, types):
    return f"{column} IN ({','.join(repr(name) for name in types)})"


COUNTERS = {
    'committed': "outcome='committed'", 'unknown': "outcome='unknown'", 'reverted': "outcome='reverted'",
    'edited': "outcome='edited'", 'cancelled': "outcome='cancelled'", 'interrupted': "outcome='interrupted'",
    'tentative': "outcome='tentative'", 'regular_issued': 'regular_committed AND insertion_issued=1',
    'regular_not_issued': 'regular_committed AND insertion_issued=0',
    'regular_insertion_unknown': 'regular_committed AND insertion_issued IS NULL',
    'valid': 'valid', 'known_rank': 'valid AND display_rank IS NOT NULL',
    'unknown_rank': 'valid AND display_rank IS NULL',
    'comparable': COMPARABLE,
    'first_page_unavailable': 'valid AND display_rank IS NOT NULL AND first_page_top1 IS NULL',
    'top1_selected': 'valid AND display_rank=1',
    'top3_selected': 'valid AND display_rank BETWEEN 1 AND 3',
    'top1_matches': 'valid AND display_rank IS NOT NULL AND top1_match',
    'truncated': 'page_history_truncated=1',
    'text_free': 'text_captured=0',
    'length_unavailable': 'valid AND display_rank IS NOT NULL AND selected_length IS NULL',
    'pair_identity': 'valid AND display_rank IS NOT NULL AND pair_id IS NOT NULL',
    'pair_unavailable': 'valid AND display_rank IS NOT NULL AND pair_id IS NULL',
    'onekey_selected': ("valid AND trigger='space' AND page=0 AND json_extract(operations_json,'$.pageTurns')=0 "
                        "AND json_extract(operations_json,'$.candidateMoves')=0"),
    'misses': 'valid AND display_rank>1',
    'learned_misses': f"valid AND display_rank>1 AND {type_set('selected_type', LEARNED_TYPES)}",
    'misses_with_provenance': "valid AND display_rank>1 AND selected_type IS NOT NULL AND selected_type!=''",
    'learned_leader': f"{COMPARABLE} AND {type_set('first_page_type', LEARNED_TYPES)}",
    'learned_leader_missed': f"{COMPARABLE} AND {type_set('first_page_type', LEARNED_TYPES)} AND NOT top1_match",
    'dictionary_leader': f"{COMPARABLE} AND {type_set('first_page_type', DICTIONARY_TYPES)}",
    'dictionary_leader_missed': f"{COMPARABLE} AND {type_set('first_page_type', DICTIONARY_TYPES)} AND NOT top1_match",
}
SCORECARD_COUNTERS = ('onekey_selected', 'misses', 'learned_misses', 'misses_with_provenance', 'learned_leader',
                      'learned_leader_missed', 'dictionary_leader', 'dictionary_leader_missed')
# rate: (numerator counters, denominator counters, prefix of its Wilson interval or None); counters are summed.
DECISION_RATES = {
    'onekey_rate': (('onekey_selected',), ('valid',), 'onekey'),
    'learned_miss_share': (('learned_misses',), ('misses',), 'learned_miss'),
    'learned_leader_miss_rate': (('learned_leader_missed',), ('learned_leader',), 'learned_leader_miss'),
    'dictionary_leader_miss_rate': (('dictionary_leader_missed',), ('dictionary_leader',), 'dictionary_leader_miss'),
}
# One row per selected composition (`scored_compositions` in `ctes`); a mean or a ratio has no interval.
CODE_COMPOSITION = "(decisions>0 OR outcome IN ('cancelled','interrupted') OR code_commits>0)"
REGULAR_COMPOSITION = "(outcome='committed' AND valid_decisions>0)"
KSPC_COMPOSITION = f'({REGULAR_COMPOSITION} AND text_captured=1)'
COMPOSITION_COUNTERS = {
    'code_compositions': CODE_COMPOSITION,
    'cancelled_compositions': f"{CODE_COMPOSITION} AND outcome='cancelled'",
    'edited_compositions': f'{CODE_COMPOSITION} AND preedit_edits>0',
    'regular_committed_compositions': REGULAR_COMPOSITION,
    'regular_decisions': f'CASE WHEN {REGULAR_COMPOSITION} THEN valid_decisions END',
    'kspc_compositions': KSPC_COMPOSITION,
    'kspc_keypresses': f'CASE WHEN {KSPC_COMPOSITION} THEN keypresses END',
    'kspc_characters': f'CASE WHEN {KSPC_COMPOSITION} THEN committed_characters END',
    'kspc_text_free_compositions': f'{REGULAR_COMPOSITION} AND text_captured=0',
    'candidate_commits': 'candidate_commits',
    'raw_return_commits': 'raw_return_commits',
    'commits_with_window': 'commits_with_window',
    'reverted_commits': 'reverted_commits',
}
COMPOSITION_RATES = {
    'cancel_rate': (('cancelled_compositions',), ('code_compositions',), 'cancel'),
    'preedit_edit_rate': (('edited_compositions',), ('code_compositions',), 'preedit_edit'),
    'decisions_per_composition': (('regular_decisions',), ('regular_committed_compositions',), None),
    'kspc': (('kspc_keypresses',), ('kspc_characters',), None),
    'raw_commit_rate': (('raw_return_commits',), ('candidate_commits', 'raw_return_commits'), 'raw_commit'),
    'revert_rate': (('reverted_commits',), ('commits_with_window',), 'revert'),
}
# Most cancels and raw Returns have no decision, so no kind: a kind series would read near 0 for these.
OVERALL_ONLY_RATES = ('cancel_rate', 'preedit_edit_rate', 'raw_commit_rate')
# A `candidate` commit's composition always has a decision, so this rate also reads true under `--kind`.
KIND_FILTER_RATES = ('revert_rate',)


class QueryError(Exception):
    pass


def timestamp(value):
    """Calendar dates use local midnight; datetimes must carry their UTC offset."""
    try:
        if len(value) == 10:
            parsed = datetime.combine(date.fromisoformat(value), time()).astimezone()
        else:
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
            if parsed.tzinfo is None:
                raise ValueError('timestamp needs Z or an explicit UTC offset')
        utc = parsed.astimezone(timezone.utc)
        # The writer stores milliseconds. Preserve finer filter precision when supplied.
        precision = 'milliseconds' if utc.microsecond % 1000 == 0 else 'microseconds'
        return utc.isoformat(timespec=precision).replace('+00:00', 'Z')
    except ValueError as error:
        raise argparse.ArgumentTypeError(f'Invalid time {value!r}: {error}') from error


def positive(value):
    try:
        result = int(value)
        if result > 0:
            return result
    except ValueError:
        pass
    raise argparse.ArgumentTypeError('must be a positive integer')


def connect(path):
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise QueryError(f'Database does not exist: {path}. Record input first, or pass --db PATH.')
    db = sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=0.25)
    try:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        if (db.execute('PRAGMA user_version').fetchone()[0] != 4
                or db.execute('PRAGMA application_id').fetchone()[0] != 0x49465131):
            raise QueryError('Database is incompatible: expected InkFlow quality schema v4 (IFQ1).')
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,7)!='sqlite_'")}
        if tables != set(TABLE_COLUMNS):
            raise QueryError('Database is incompatible: expected the six InkFlow quality tables.')
        for table, columns in TABLE_COLUMNS.items():
            actual = {r['name'] for r in db.execute(f'PRAGMA table_info({table})')}
            if set(columns.split()) != actual:
                raise QueryError(f'Database is incompatible: unexpected v4 columns in {table}.')
        db.execute("SELECT json_extract('{\"v\":1}', '$.v')").fetchone()
        return db
    except Exception:
        db.close()
        raise


def filters(args):
    composition, decision, parameters = [], [], {}
    for option, condition in [('since', 'c.started_at >= :since'), ('until', 'c.started_at < :until'),
                              ('app', 'c.app_bundle_id = :app')]:
        if (value := getattr(args, option)) is not None:
            composition.append(condition)
            if option in ('since', 'until'):
                moment = datetime.fromisoformat(value.replace('Z', '+00:00'))
                if remainder := moment.microsecond % 1000:
                    moment += timedelta(microseconds=1000 - remainder)
                value = moment.isoformat(timespec='milliseconds').replace('+00:00', 'Z')
            parameters[option] = value
    for option, condition in [('config', 'r.fingerprint = :config'),
                              ('ranking_config', 'r.ranking_fingerprint = :ranking_config'),
                              ('kind', 'd.text_kind = :kind')]:
        if (value := getattr(args, option)) is not None:
            decision.append(condition)
            parameters[option] = value
    if getattr(args, 'source', None) is not None:
        composition.append('c.source_id = :source')
        parameters['source'] = args.source
    if decision:
        composition.append('EXISTS (SELECT 1 FROM candidate_decisions d JOIN config_revisions r '
                           'ON r.id=d.config_revision_id WHERE d.composition_id=c.id AND '
                           + ' AND '.join(decision) + ')')
    return ' AND '.join(composition) or '1', ' AND '.join(decision) or '1', parameters


def windows_cte(args):
    """One row per commit, with the commit named as the database names it: exports prefix every id with its source."""
    combined = getattr(args, 'input', None) or getattr(args, 'exports_only', False) or getattr(args, 'source', None)
    select = ', '.join(("c.source_id || ':' || " if combined and column == 'commit_id' else '')
                       + f"json_extract(w.value,'$.{key}') AS \"{column}\"" for column, key in WINDOW_KEYS.items())
    return f"windows AS (SELECT {select} FROM compositions c, json_each(c.operations_json,'$.postCommitWindows') w)"


def ctes(args):
    composition_filter, decision_filter, parameters = filters(args)
    same_generation = ' AND '.join(
        f"json_extract(first_page_json,'$.{field}') = json_extract(snapshot_json,'$.{field}')"
        for field in SAME_GENERATION_FIELDS)
    sql = f"""
    WITH selected_compositions AS (
        SELECT c.* FROM compositions c WHERE {composition_filter}
    ), {windows_cte(args)}, base AS (
        SELECT d.*, c.started_at AS composition_started_at, r.fingerprint,
          COALESCE(r.ranking_fingerprint,'unknown') AS ranking_fingerprint,
          r.settings_fingerprint,
          COALESCE(r.measurement_fingerprint,'unknown') AS measurement_fingerprint,
          r.build_identity, m.insertion_issued, m.text AS commit_text, {WINDOW_COLUMNS},
          json_extract(r.build_metadata_json,'$.appVersion') AS app_version,
          json_extract(r.build_metadata_json,'$.appBuild') AS app_build,
          json_extract(r.build_metadata_json,'$.sourceRevision') AS source_revision,
          json_extract(d.snapshot_json,'$.presentation') AS presentation,
          COALESCE(json_extract(d.snapshot_json,'$.textCaptured'),1) AS text_captured,
          json_extract(d.snapshot_json,'$.rawInput') AS raw_input,
          json_extract(d.snapshot_json,'$.codeHash') AS code_hash,
          json_extract(d.snapshot_json,'$.caret') AS caret,
          json_extract(d.snapshot_json,'$.selectedPrefix') AS selected_prefix,
          json_extract(d.snapshot_json,'$.selectedPrefixValid') AS selected_prefix_valid,
          json_extract(d.snapshot_json,'$.precedingContext') AS preceding_context,
          json_extract(d.snapshot_json,'$.page') AS page,
          json_extract(d.snapshot_json,'$.pageSize') AS page_size,
          CASE WHEN d.selected_display_index >= 0 THEN json_extract(d.snapshot_json,
            '$.candidates[' || d.selected_display_index || ']') END AS selected_candidate,
          (d.regular_ranked_selection=1 AND d.trigger IN ('space','digit','panel')
            AND d.outcome='committed') AS regular_committed
        FROM candidate_decisions d JOIN selected_compositions c ON c.id=d.composition_id
        JOIN config_revisions r ON r.id=d.config_revision_id
        LEFT JOIN commits m ON m.id=d.commit_id AND m.composition_id=d.composition_id
        LEFT JOIN windows w ON w.commit_id=d.commit_id
        WHERE {decision_filter}
    ), ranked AS (
        SELECT *, CASE WHEN ((text_captured=0 AND selected_text IS NULL) OR json_extract(selected_candidate,'$.text')=selected_text)
          AND json_extract(selected_candidate,'$.displayIndex')=selected_display_index
          AND page>=0 AND page_size>0 AND selected_display_index<page_size
          AND json_extract(selected_candidate,'$.displayRank')=page*page_size+selected_display_index+1
          THEN json_extract(selected_candidate,'$.displayRank') END AS display_rank,
          CASE WHEN ((text_captured=0 AND selected_text IS NULL) OR json_extract(selected_candidate,'$.text')=selected_text)
          AND json_extract(selected_candidate,'$.nativeIndex')>=0
          AND json_extract(selected_candidate,'$.nativeIndex')<page_size
          AND json_extract(selected_candidate,'$.nativeRank')=page*page_size+json_extract(selected_candidate,'$.nativeIndex')+1
          THEN json_extract(selected_candidate,'$.nativeRank') END AS native_rank,
          json_extract(selected_candidate,'$.textHash') AS selected_text_hash,
          json_extract(selected_candidate,'$.type') AS selected_type,
          json_extract(first_page_json,'$.candidates[0].type') AS first_page_type,
          CASE WHEN selected_prefix_valid=1 AND {same_generation}
          AND json_extract(first_page_json,'$.page')=0
          AND json_extract(first_page_json,'$.candidates[0].displayIndex')=0
          AND json_extract(first_page_json,'$.candidates[0].displayRank')=1
          THEN json_extract(first_page_json,'$.candidates[0].text') END AS first_page_top1
        FROM base
    ), observations AS (
        SELECT *, COALESCE(regular_committed AND insertion_issued=1
          AND presentation IN ('candidates_requested','panel_show_issued'),0) AS valid,
          code_hash || '|' || selected_text_hash AS pair_id,
          NULLIF(COALESCE(selected_character_count,
                          CASE WHEN text_captured=0 THEN NULL ELSE length(selected_text) END), 0) AS selected_length,
          CASE WHEN text_captured=0 THEN display_rank=1 ELSE selected_text=first_page_top1 END AS top1_match
        FROM ranked
    ), run_measurements AS (
        SELECT c.run_id, CASE WHEN COUNT(DISTINCT COALESCE(r.measurement_fingerprint,'unknown'))=1
          THEN MIN(COALESCE(r.measurement_fingerprint,'unknown')) ELSE 'unknown' END AS measurement_fingerprint
        FROM candidate_decisions d JOIN compositions c ON c.id=d.composition_id
        JOIN config_revisions r ON r.id=d.config_revision_id
        WHERE c.run_id IN (SELECT run_id FROM selected_compositions) GROUP BY c.run_id
    ), composition_decisions AS (
        SELECT composition_id, COUNT(*) AS decisions, SUM(valid) AS valid_decisions,
          MIN(text_captured) AS text_captured,
          CASE WHEN COUNT(DISTINCT text_kind)=1 THEN MIN(text_kind) ELSE 'mixed' END AS kind,
          CASE WHEN COUNT(DISTINCT measurement_fingerprint)=1 THEN MIN(measurement_fingerprint)
          ELSE 'unknown' END AS measurement_fingerprint
        FROM observations GROUP BY composition_id
    ), composition_commits AS (
        SELECT composition_id, SUM(kind='candidate') AS candidate_commits, SUM(kind='raw_return') AS raw_return_commits,
          SUM(kind IN ('candidate','raw_return','ascii','forced_flush')) AS code_commits,
          SUM(CASE WHEN kind='candidate' THEN length(text) END) AS committed_characters,
          SUM(kind='candidate' AND w.commit_id IS NOT NULL) AS commits_with_window,
          SUM(kind='candidate' AND w.commit_id IS NOT NULL AND (w.leading_undo>=1
            OR (character_count>0 AND w.leading_deletions>=character_count))) AS reverted_commits
        FROM commits LEFT JOIN windows w ON w.commit_id=commits.id
        WHERE composition_id IN (SELECT id FROM selected_compositions) GROUP BY composition_id
    ), scored_compositions AS (
        SELECT c.id, c.started_at AS composition_started_at, c.outcome,
          json_extract(c.operations_json,'$.keypresses') AS keypresses,
          json_extract(c.operations_json,'$.preeditEdits') AS preedit_edits,
          COALESCE(d.decisions,0) AS decisions, COALESCE(d.valid_decisions,0) AS valid_decisions, d.text_captured,
          COALESCE(d.kind,'unknown') AS kind,
          COALESCE(d.measurement_fingerprint, r.measurement_fingerprint, 'unknown') AS measurement_fingerprint,
          COALESCE(m.candidate_commits,0) AS candidate_commits, COALESCE(m.raw_return_commits,0) AS raw_return_commits,
          COALESCE(m.code_commits,0) AS code_commits, COALESCE(m.committed_characters,0) AS committed_characters,
          COALESCE(m.commits_with_window,0) AS commits_with_window, COALESCE(m.reverted_commits,0) AS reverted_commits
        FROM selected_compositions c LEFT JOIN composition_decisions d ON d.composition_id=c.id
        LEFT JOIN composition_commits m ON m.composition_id=c.id LEFT JOIN run_measurements r ON r.run_id=c.run_id
    )
    """
    return sql, parameters


def rows(db, sql, parameters=None):
    return [dict(row) for row in db.execute(sql, parameters or {})]


def composition_sql():
    return ', '.join(f'COALESCE(SUM({condition}),0) AS {key}' for key, condition in COMPOSITION_COUNTERS.items())


def aggregate_sql():
    fields = ['COUNT(*) AS decisions']
    fields += [f'COALESCE(SUM(CASE WHEN {condition} THEN 1 ELSE 0 END),0) AS {key}'
               for key, condition in COUNTERS.items()]
    fields += ['COALESCE(SUM(dropped_page_count),0) AS dropped_page_count',
               'AVG(CASE WHEN valid THEN display_rank END) AS mean_display_rank',
               'AVG(CASE WHEN valid AND display_rank IS NOT NULL THEN native_rank END) AS mean_native_rank']
    fields += [f"COALESCE(SUM(CASE WHEN valid THEN json_extract(operations_json,'$.{field}') END),0) AS {key}"
               for key, field in OPERATIONS.items()]
    return ', '.join(fields)


def ratio(row, numerators, denominators):
    """A ratio of summed counters; a zero denominator is null, never 0."""
    denominator = sum(row[key] for key in denominators)
    return sum(row[key] for key in numerators) / denominator if denominator else None


def rates(row, status=None):
    row['top1_rate'] = row['top1_selected'] / row['known_rank'] if row['known_rank'] else None
    row['top3_rate'] = row['top3_selected'] / row['known_rank'] if row['known_rank'] else None
    row['top1_match_rate'] = row['top1_matches'] / row['comparable'] if row['comparable'] else None
    for name, (numerators, denominators, _) in DECISION_RATES.items():
        row[name] = ratio(row, numerators, denominators)
    if status is None:
        status = ('unavailable_unknown_measurement_fingerprint'
                  if row.get('measurement_fingerprint') == 'unknown'
                  else 'available_within_measurement_fingerprint')
    if status != 'available_within_measurement_fingerprint':
        row['top1_rate'] = None
        row['top3_rate'] = None
        row['top1_match_rate'] = None
        for name in DECISION_RATES:
            row[name] = None
    row['quality_rate_status'] = status
    return row


def measurement_status(row):
    if row['total'] == 0:
        return 'unavailable_without_measurement_evidence'
    if row['known_distinct'] == 1 and row['unknown'] == 0:
        return 'available_within_measurement_fingerprint'
    if row['known_distinct'] == 0:
        return 'unavailable_unknown_measurement_fingerprint'
    return 'unavailable_across_measurement_fingerprints'


def coverage(db, sql, parameters):
    selected_commits = '(SELECT m.id FROM commits m WHERE m.composition_id IN (SELECT id FROM selected_compositions))'
    measurement = rows(db, sql + """SELECT COUNT(*) AS total,
        COUNT(DISTINCT CASE WHEN measurement_fingerprint!='unknown' THEN measurement_fingerprint END) AS known_distinct,
        COALESCE(SUM(measurement_fingerprint='unknown'),0) AS unknown FROM observations""", parameters)[0]
    result = rates(rows(db, sql + 'SELECT ' + aggregate_sql() + ' FROM observations', parameters)[0],
                   measurement_status(measurement))
    result.update(rows(db, sql + f"""SELECT COUNT(*) AS compositions,
        COALESCE(SUM(page_history_truncated),0) AS truncated_compositions,
        (SELECT COUNT(*) FROM commits WHERE composition_id IN (SELECT id FROM selected_compositions)) AS commits,
        (SELECT COUNT(*) FROM commits WHERE insertion_issued=0 AND composition_id IN
          (SELECT id FROM selected_compositions)) AS commits_not_issued,
        (SELECT COUNT(*) FROM windows WHERE commit_id IN {selected_commits}) AS commit_windows
        FROM selected_compositions""", parameters)[0])
    ends = {row[0]: row[1] for row in db.execute(
        sql + f'SELECT "end", COUNT(*) FROM windows WHERE commit_id IN {selected_commits} GROUP BY "end"', parameters)}
    result['windows_by_end'] = {end: ends.pop(end, 0) for end in WINDOW_ENDS} | ends
    # Compositions attributed to a fingerprint join the decisions in the status of the composition and commit rates.
    result.update(rows(db, sql + f"""SELECT {composition_sql()},
        COALESCE(SUM(measurement_fingerprint='unknown'),0) AS unknown_fingerprint_compositions
        FROM scored_compositions""", parameters)[0])
    pooled = rows(db, sql + """SELECT COUNT(*) AS total,
        COUNT(DISTINCT CASE WHEN fingerprint!='unknown' THEN fingerprint END) AS known_distinct,
        COALESCE(SUM(fingerprint='unknown'),0) AS unknown FROM (SELECT measurement_fingerprint AS fingerprint
        FROM observations UNION ALL SELECT measurement_fingerprint FROM scored_compositions)""", parameters)[0]
    result['composition_rate_status'] = measurement_status(pooled)
    available = result['composition_rate_status'] == 'available_within_measurement_fingerprint'
    for name, (numerators, denominators, _) in COMPOSITION_RATES.items():
        result[name] = ratio(result, numerators, denominators) if available else None
    return result


IDENTITY_LAYERS = {
    'ranking': 'ranking_fingerprint',
    'settings': 'settings_fingerprint',
    'measurement': 'measurement_fingerprint',
    'build': 'build_identity',
}


def identity_coverage(db, sql, parameters, source, cohort):
    result = {'cohort': cohort, 'unit': 'decision'}
    for layer, column in IDENTITY_LAYERS.items():
        totals = rows(db, sql + f"""SELECT
            COALESCE(SUM({column} IS NOT NULL AND {column} != 'unknown'),0) AS known,
            COALESCE(SUM({column} IS NULL OR {column} = 'unknown'),0) AS unknown,
            COUNT(DISTINCT CASE WHEN {column} IS NOT NULL AND {column} != 'unknown' THEN {column} END) AS distinct_count
            FROM {source}""", parameters)[0]
        identities = rows(db, sql + f"""SELECT COALESCE({column},'unknown') AS identity,COUNT(*) AS count
            FROM {source} GROUP BY COALESCE({column},'unknown') ORDER BY identity""", parameters)
        totals['distinct'] = totals.pop('distinct_count')
        result[layer] = dict(**totals, identities=identities)
    return result


def revision_identity_coverage(revisions):
    result = {'cohort': 'returned_configuration_revisions', 'unit': 'configuration_revision'}
    for layer, column in IDENTITY_LAYERS.items():
        counts = {}
        for revision in revisions:
            identity = revision[column] if revision[column] not in (None, 'unknown') else 'unknown'
            counts[identity] = counts.get(identity, 0) + 1
        identities = [dict(identity=identity, count=count) for identity, count in sorted(counts.items())]
        result[layer] = dict(known=sum(x['count'] for x in identities if x['identity'] != 'unknown'),
                             unknown=counts.get('unknown', 0),
                             distinct=sum(x['identity'] != 'unknown' for x in identities), identities=identities)
    return result


def summary(db, args):
    sql, parameters = ctes(args)
    group = ','.join(GROUP)
    groups = rows(db, sql + f'SELECT {group}, {aggregate_sql()} FROM observations GROUP BY {group} ORDER BY {group}', parameters)
    ranks = rows(db, sql + f'''SELECT {group},display_rank,COUNT(*) AS count FROM observations
        WHERE valid AND display_rank IS NOT NULL GROUP BY {group},display_rank ORDER BY {group},display_rank''', parameters)
    run_counters = ('submitted', 'written', 'droppedQueue', 'droppedOversized', 'droppedDisabled',
                    'droppedBusy', 'droppedInvalid', 'errors', 'truncatedEnvelopes')
    run_filter = ' WHERE source_id=:source' if getattr(args, 'source', None) else ''
    run_parameters = {'source': args.source} if run_filter else {}
    run_sql = ','.join(f"COALESCE(SUM(json_extract(stats_json,'$.{key}')),0) AS {key}" for key in run_counters)
    return dict(coverage=coverage(db, sql, parameters),
                learning_effectiveness=effectiveness(db, args),
                identity_coverage=identity_coverage(db, sql, parameters, 'observations', 'filtered_decisions'),
                groups=[rates(g) for g in groups], rank_counts=ranks,
                recording_runs=dict(scope='whole_db_lifetime_unfiltered',
                    totals=rows(db, 'SELECT COUNT(*) AS runs,' + run_sql + ' FROM recording_runs' + run_filter, run_parameters)[0],
                    statuses=rows(db, 'SELECT status,error_code,COUNT(*) AS runs FROM recording_runs' + run_filter + ' GROUP BY status,error_code', run_parameters)))


def effectiveness(db, args):
    """Keep voice-learning denominators independent from ordinary candidate accuracy."""
    unsupported = any(getattr(args, key) is not None for key in ('app', 'config', 'ranking_config', 'kind'))
    conditions, parameters = [], {}
    if getattr(args, 'source', None):
        conditions.append('source_id=:source')
        parameters['source'] = args.source
    for option, operator in (('since', '>='), ('until', '<')):
        if (value := getattr(args, option)) is not None:
            conditions.append(f'occurred_at {operator} :{option}')
            parameters[option] = value
    where = ' AND '.join(conditions) or '1'
    counts = {(row['source'], row['event']): row['count'] for row in rows(db, f'''SELECT source,event,
        COALESCE(SUM(count),0) AS count FROM effectiveness_events WHERE {where}
        GROUP BY source,event''', parameters)}
    rejection_reasons = rows(db, f'''SELECT reason,COALESCE(SUM(count),0) AS count
        FROM effectiveness_events WHERE {where} AND event = 'rejected'
        GROUP BY reason ORDER BY reason''', parameters)
    value = lambda source, event: counts.get((source, event), 0)
    voice = dict(finalized=value('voice_session', 'finalized'),
                 corrections_detected=value('voice_correction', 'detected'),
                 corrections_learned=value('voice_correction', 'learned'),
                 corrections_rejected=value('voice_correction', 'rejected'),
                 rejection_reasons=rejection_reasons,
                 alias_hits=value('voice_alias', 'hit'),
                 alias_later_reuse=value('voice_alias', 'later_reuse'))
    canonical = dict(exact_hits=value('canonical_lexicon', 'hit'),
                     later_reuse=value('canonical_lexicon', 'later_reuse'))
    learning_acts = dict(forgotten=value('candidate_learning', 'forgotten'),
                         deleted=value('candidate_learning', 'deleted'),
                         restored=value('candidate_learning', 'restored'))
    if unsupported:
        status = 'unavailable_for_candidate_filters'
        voice.update(correction_detection_rate=None, correction_learning_rate=None, alias_reuse_rate=None)
        canonical.update(reuse_rate=None)
    else:
        status = 'available' if voice['finalized'] else 'unavailable_without_finalized_voice_sessions'
        voice['correction_detection_rate'] = (voice['corrections_detected'] / voice['finalized']
                                               if voice['finalized'] else None)
        voice['correction_learning_rate'] = (voice['corrections_learned'] / voice['corrections_detected']
                                              if voice['corrections_detected'] else None)
        voice['alias_reuse_rate'] = (voice['alias_later_reuse'] / voice['alias_hits']
                                     if voice['alias_hits'] else None)
        canonical['reuse_rate'] = (canonical['later_reuse'] / canonical['exact_hits']
                                   if canonical['exact_hits'] else None)
    return dict(scope='content_free_events_separate_from_candidate_accuracy', status=status,
                voice=voice, canonical_lexicon=canonical, candidate_learning=learning_acts)


TREND_COUNTERS = ('decisions', 'valid', 'known_rank', 'unknown_rank', 'comparable',
                  'first_page_unavailable', 'top1_selected', 'top3_selected', 'top1_matches',
                  'paged_selected', 'text_free', 'length_unavailable') + SCORECARD_COUNTERS
SELECTION_LENGTHS = ('1', '2', '3+')
Z95 = NormalDist().inv_cdf(0.975)


def wilson(successes, total):
    """95% Wilson score interval of a proportion, or (None, None) without observations."""
    if not total:
        return None, None
    rate = successes / total
    squared = Z95 * Z95
    center = rate + squared / (2 * total)
    margin = Z95 * sqrt(rate * (1 - rate) / total + squared / (4 * total * total))
    scale = 1 + squared / total
    low = 0.0 if not successes else max(0.0, (center - margin) / scale)
    high = 1.0 if successes == total else min(1.0, (center + margin) / scale)
    return low, high


def set_rate(result, name, interval, numerators, denominators, available):
    """A rate of summed counters, with its Wilson interval when it is a proportion; null unless available."""
    result[name] = ratio(result, numerators, denominators) if available else None
    if interval:
        low, high = wilson(sum(result[key] for key in numerators), sum(result[key] for key in denominators))
        result[f'{interval}_wilson_low'], result[f'{interval}_wilson_high'] = (
            (low, high) if result[name] is not None else (None, None))


def tally(items, key):
    result = {}
    for item in items:
        for identity, count in item.get(key, {}).items():
            result[identity] = result.get(identity, 0) + count
    return result


def trend_metric(items, lengths=True, composition_rates=()):
    """A point or a selection-length bucket. Composition and commit counters are on points only, and
    `composition_rates` names the rates of them this series reports."""
    result = {key: sum(item.get(key, 0) for item in items) for key in TREND_COUNTERS}
    measurements = tally(items, '_measurements')
    attributed = tally(items, '_attributed')
    pooled = {identity: measurements.get(identity, 0) + attributed.get(identity, 0)
              for identity in measurements.keys() | attributed.keys()}
    known = {identity for identity, count in pooled.items() if identity != 'unknown' and count}
    unknown = pooled.get('unknown', 0)
    if not sum(pooled.values()):
        status = 'unavailable_without_measurement_evidence'
    elif len(known) == 1 and not unknown:
        status = 'available_within_measurement_fingerprint'
    elif not known:
        status = 'unavailable_unknown_measurement_fingerprint'
    else:
        status = 'unavailable_across_measurement_fingerprints'
    result['top1_rate'] = (result['top1_selected'] / result['known_rank']
                           if result['known_rank'] and status == 'available_within_measurement_fingerprint' else None)
    result['top3_rate'] = (result['top3_selected'] / result['known_rank']
                           if result['known_rank'] and status == 'available_within_measurement_fingerprint' else None)
    result['top1_match_rate'] = (result['top1_matches'] / result['comparable']
                                 if result['comparable'] and status == 'available_within_measurement_fingerprint' else None)
    result['paged_rate'] = (result['paged_selected'] / result['known_rank']
                            if result['known_rank'] and status == 'available_within_measurement_fingerprint' else None)
    for name in ('top1', 'top3', 'paged'):
        if result[f'{name}_rate'] is None:
            result[f'{name}_wilson_low'] = None
            result[f'{name}_wilson_high'] = None
        else:
            result[f'{name}_wilson_low'], result[f'{name}_wilson_high'] = wilson(
                result[f'{name}_selected'], result['known_rank'])
    available = status == 'available_within_measurement_fingerprint'
    for name, (numerators, denominators, interval) in DECISION_RATES.items():
        set_rate(result, name, interval, numerators, denominators, available)
    result['quality_rate_status'] = status
    result['measurement_fingerprints'] = sorted(known)
    result['unknown_measurement_decisions'] = measurements.get('unknown', 0)
    if lengths:
        for key in COMPOSITION_COUNTERS:
            result[key] = sum(item.get(key, 0) for item in items)
        for name, (numerators, denominators, interval) in COMPOSITION_RATES.items():
            set_rate(result, name, interval, numerators, denominators, available and name in composition_rates)
        # Known-rank decisions without a length (`length_unavailable`) sit beside the buckets.
        result['by_selection_length'] = {}
        for length in SELECTION_LENGTHS:
            bucket = trend_metric([item.get('_lengths', {}).get(length, {}) for item in items], lengths=False)
            del bucket['text_free']
            del bucket['length_unavailable']
            result['by_selection_length'][length] = bucket
    return result


def trend_bounds(args):
    if args.since is not None:
        raise QueryError(f'{args.command} derives --since from --days; omit --since.')
    if args.until is None:
        exclusive_day = datetime.now().astimezone().date() + timedelta(days=1)
    else:
        local = datetime.fromisoformat(args.until.replace('Z', '+00:00')).astimezone()
        if local.timetz().replace(tzinfo=None) != time():
            raise QueryError(f'{args.command} --until must be a local calendar date boundary.')
        exclusive_day = local.date()
    first_day = exclusive_day - timedelta(days=args.days)
    args.since = timestamp(first_day.isoformat())
    args.until = timestamp(exclusive_day.isoformat())
    return first_day, exclusive_day


def trend(db, args):
    first_day, exclusive_day = trend_bounds(args)
    sql, parameters = ctes(args)
    fields = ','.join([
        'COUNT(*) AS decisions',
        "COALESCE(SUM(valid),0) AS valid",
        "COALESCE(SUM(valid AND display_rank IS NOT NULL),0) AS known_rank",
        "COALESCE(SUM(valid AND display_rank IS NULL),0) AS unknown_rank",
        "COALESCE(SUM(valid AND display_rank IS NOT NULL AND first_page_top1 IS NOT NULL),0) AS comparable",
        "COALESCE(SUM(valid AND display_rank IS NOT NULL AND first_page_top1 IS NULL),0) AS first_page_unavailable",
        "COALESCE(SUM(valid AND display_rank=1),0) AS top1_selected",
        "COALESCE(SUM(valid AND display_rank BETWEEN 1 AND 3),0) AS top3_selected",
        "COALESCE(SUM(valid AND display_rank IS NOT NULL AND top1_match),0) AS top1_matches",
        "COALESCE(SUM(valid AND display_rank IS NOT NULL AND page>0),0) AS paged_selected",
        "COALESCE(SUM(valid AND display_rank IS NOT NULL AND text_captured=0),0) AS text_free",
        "COALESCE(SUM(valid AND display_rank IS NOT NULL AND selected_length IS NULL),0) AS length_unavailable",
        *(f'COALESCE(SUM({COUNTERS[key]}),0) AS {key}' for key in SCORECARD_COUNTERS),
    ])
    length = """CASE WHEN selected_length=1 THEN '1' WHEN selected_length=2 THEN '2'
        WHEN selected_length>=3 THEN '3+' END"""
    grouped = rows(db, sql + f"""SELECT date(composition_started_at,'localtime') AS local_day,
        text_kind,measurement_fingerprint,{length} AS selection_length,{fields} FROM observations
        GROUP BY local_day,text_kind,measurement_fingerprint,selection_length
        ORDER BY local_day,text_kind,measurement_fingerprint,selection_length""", parameters)
    latest_measurement = db.execute(sql + """SELECT measurement_fingerprint FROM observations
        WHERE measurement_fingerprint!='unknown'
        ORDER BY composition_started_at DESC,occurred_at DESC,id DESC LIMIT 1""", parameters).fetchone()
    measurement_identity = latest_measurement['measurement_fingerprint'] if latest_measurement else None
    # A composition without a decision takes the fingerprint of its run's decisions (see `scored_compositions`).
    scored = rows(db, sql + f"""SELECT date(composition_started_at,'localtime') AS local_day,kind,
        measurement_fingerprint,COUNT(*) AS compositions,{composition_sql()} FROM scored_compositions
        GROUP BY local_day,kind,measurement_fingerprint""", parameters)
    total_decisions = sum(row['decisions'] for row in grouped)
    included_decisions = sum(row['decisions'] for row in grouped
                             if row['measurement_fingerprint'] == measurement_identity)
    raw = {'overall': {}, **{kind: {} for kind in KINDS}}
    for row in grouped:
        if row['measurement_fingerprint'] != measurement_identity:
            continue
        for series in ('overall', row['text_kind']):
            day = raw[series].setdefault(row['local_day'], {key: 0 for key in TREND_COUNTERS})
            targets = [day]
            if row['selection_length'] is not None:
                lengths = day.setdefault('_lengths', {})
                targets.append(lengths.setdefault(row['selection_length'], {key: 0 for key in TREND_COUNTERS}))
            for target in targets:
                for key in TREND_COUNTERS:
                    target[key] += row[key]
                measurements = target.setdefault('_measurements', {})
                measurements[row['measurement_fingerprint']] = (
                    measurements.get(row['measurement_fingerprint'], 0) + row['decisions'])
    for row in scored:
        if row['measurement_fingerprint'] != measurement_identity:
            continue
        for series in ('overall', row['kind']):
            day = raw[series].setdefault(row['local_day'], {key: 0 for key in TREND_COUNTERS})
            for key in COMPOSITION_COUNTERS:
                day[key] = day.get(key, 0) + row[key]
            attributed = day.setdefault('_attributed', {})
            attributed[row['measurement_fingerprint']] = (
                attributed.get(row['measurement_fingerprint'], 0) + row['compositions'])
    days = [(first_day + timedelta(days=offset)).isoformat() for offset in range(args.days)]
    series = {}
    for name, values in raw.items():
        raw_points = [values.get(day, {**{key: 0 for key in TREND_COUNTERS}, '_measurements': {}}) for day in days]
        # Composition and commit rates need compositions without a kind, so only `overall` reports all of them.
        # Under `--kind` the compositions kept are those with a matching decision: only KIND_FILTER_RATES read true.
        reported = tuple(
            rate for rate in COMPOSITION_RATES if rate in KIND_FILTER_RATES or (
                args.kind is None and (name == 'overall' or rate not in OVERALL_ONLY_RATES)))
        points = []
        for index, day in enumerate(days):
            points.append(dict(date=day, daily=trend_metric([raw_points[index]], composition_rates=reported),
                rolling_7d=trend_metric(raw_points[max(0, index-6):index+1], composition_rates=reported),
                rolling_28d=trend_metric(raw_points[max(0, index-27):index+1], composition_rates=reported)))
        series[name] = points
    markers = rows(db, sql + """SELECT app_version,
        MIN(composition_started_at) AS first_seen,MAX(composition_started_at) AS last_seen,
        COUNT(*) AS decisions,COUNT(DISTINCT app_build) AS build_count,
        COUNT(DISTINCT source_revision) AS source_revision_count
        FROM observations WHERE app_version IS NOT NULL
        GROUP BY app_version ORDER BY first_seen,app_version""", parameters)
    for marker in markers:
        marker['local_day'] = datetime.fromisoformat(
            marker['first_seen'].replace('Z', '+00:00')).astimezone().date().isoformat()
    return dict(window=dict(days=args.days, first_day=days[0], last_day=days[-1],
                            since=args.since, until=args.until, until_exclusive=True),
                attribution='version_markers_only_not_statistical_partitions',
                metric_scope=dict(rule_fingerprint=measurement_identity,
                    policy='latest_compatible_metric_rules', included_decisions=included_decisions,
                    excluded_decisions=total_decisions-included_decisions,
                    excluded_unknown_decisions=sum(row['decisions'] for row in grouped
                                                   if row['measurement_fingerprint'] == 'unknown'),
                    included_compositions=sum(row['compositions'] for row in scored
                                              if row['measurement_fingerprint'] == measurement_identity),
                    excluded_compositions=sum(row['compositions'] for row in scored
                                              if row['measurement_fingerprint'] != measurement_identity),
                    excluded_unknown_compositions=sum(row['compositions'] for row in scored
                                                      if row['measurement_fingerprint'] == 'unknown')),
                series=series, version_markers=markers,
                identity_coverage=identity_coverage(db, sql, parameters, 'observations', 'filtered_decisions'))


# Instrument constants of the L family (docs/input-quality-metrics.md section 6), versioned with the metric rule.
LEARNING_CENSOR_DAYS = 7
LEARNING_FUTILE_SELECTIONS = 3
LEARNING_REUSE_WINDOW_DAYS = 28
LEARNING_REUSE_SPLIT_DAYS = 14
LEARNING_MIN_UNITS = 200
# Learned provenance of the selected candidate: the design's provenance dimension, read from the candidate `type`.
LEARNED_PROVENANCE = ("selected_type = 'user_phrase' OR selected_type LIKE 'english_personal_%' "
                      "OR selected_type LIKE 'mixed_personal_%'")
LEARNING_HISTOGRAM = ('1', '2', '3+', 'never')


def learning_rate(numerator, denominator):
    """A rate with its Wilson interval: null for an empty denominator, no verdict below the 200-unit minimum."""
    low, high = wilson(numerator, denominator)
    return dict(numerator=numerator, denominator=denominator,
                rate=numerator / denominator if denominator else None, wilson_low=low, wilson_high=high,
                status='no_verdict_below_200_units' if denominator < LEARNING_MIN_UNITS else 'available')


def learning(db, args):
    """L-ttl, L-futile, L-util, L-avoid and L-reuse over pair identities (`pair_id`); hashes never link devices."""
    first_day, exclusive_day = trend_bounds(args)
    sql, parameters = ctes(args)
    latest = db.execute(sql + """SELECT measurement_fingerprint FROM observations
        WHERE measurement_fingerprint!='unknown'
        ORDER BY composition_started_at DESC,occurred_at DESC,id DESC LIMIT 1""", parameters).fetchone()
    measurement_identity = latest['measurement_fingerprint'] if latest else None
    known = rows(db, sql + f"""SELECT pair_id,selected_text_hash,display_rank,measurement_fingerprint,text_captured,
        COALESCE(raw_input!='' AND selected_text IS NOT NULL AND selected_text!='',0) AS literal_pair,
        COALESCE({LEARNED_PROVENANCE},0) AS learned,date(composition_started_at,'localtime') AS local_day
        FROM observations WHERE valid AND display_rank IS NOT NULL
        ORDER BY composition_started_at,occurred_at,sequence,id""", parameters)
    included = [row for row in known if row['measurement_fingerprint'] == measurement_identity]
    decisions = [row for row in included if row['pair_id'] is not None]
    unavailable = [row for row in included if row['pair_id'] is None]
    pairs = {}
    words = {}
    for row in decisions:
        row['day'] = (date.fromisoformat(row['local_day']) - first_day).days
        pairs.setdefault(row['pair_id'], []).append(row)
        words.setdefault(row['selected_text_hash'], []).append(row)
    ranks = [[row['display_rank'] for row in sequence] for sequence in pairs.values()]
    early = sum(sequence[0]['day'] < LEARNING_CENSOR_DAYS for sequence in pairs.values())
    first_seen = learning_rate(early, len(pairs))

    first_miss = [sequence for sequence in ranks if sequence[0] > 1]
    histogram = dict.fromkeys(LEARNING_HISTOGRAM, 0)
    learned_after = []
    for sequence in first_miss:
        if 1 in sequence:
            learned_after.append(sequence.index(1))
            histogram[str(learned_after[-1]) if learned_after[-1] < 3 else '3+'] += 1
        else:
            histogram['never'] += 1
    ttl = dict(pairs_first_miss=len(first_miss), histogram=histogram,
               median_selections_to_learn=median(learned_after) if learned_after else None,
               learned_after_one_rate=learning_rate(histogram['1'], len(first_miss)),
               first_seen_within_7_days_share=first_seen)

    frequent = [sequence for sequence in ranks if len(sequence) >= LEARNING_FUTILE_SELECTIONS]
    all_misses = sum(all(rank > 1 for rank in sequence) for sequence in frequent)
    futile = dict(pairs_with_3_or_more_selections=len(frequent), futile_rate=learning_rate(all_misses, len(frequent)))

    with_hit = [sequence for sequence in ranks if 1 in sequence]
    hits_until_regression = []
    for sequence in with_hit:
        tail = sequence[sequence.index(1):]
        if any(rank > 1 for rank in tail):
            hits_until_regression.append(next(index for index, rank in enumerate(tail) if rank > 1))
    util = dict(pairs_with_hit=len(with_hit), pairs_regressed=len(hits_until_regression),
                pairs_censored_at_window_end=len(with_hit) - len(hits_until_regression),
                median_hits_until_regression=median(hits_until_regression) if hits_until_regression else None,
                regression_rate=learning_rate(len(hits_until_regression), len(with_hit)))

    seen = set()
    misses = 0
    avoidable = 0
    learned = 0
    for row in decisions:
        if row['display_rank'] > 1:
            misses += 1
            avoidable += row['pair_id'] in seen
            learned += row['learned']
        seen.add(row['pair_id'])
    avoid = dict(misses=misses, avoidable_miss_rate=learning_rate(avoidable, misses),
                 learned_provenance_miss_rate=learning_rate(learned, misses),
                 first_seen_within_7_days_share=first_seen)

    first_half = [sequence for sequence in words.values() if sequence[0]['day'] < LEARNING_REUSE_SPLIT_DAYS]
    if args.days == LEARNING_REUSE_WINDOW_DAYS:
        again = sum(any(row['day'] >= LEARNING_REUSE_SPLIT_DAYS for row in sequence) for sequence in first_half)
        reuse_rate = learning_rate(again, len(first_half))
    else:
        reuse_rate = dict(numerator=None, denominator=None, rate=None, wilson_low=None, wilson_high=None,
                          status='needs_28_day_window')
    reuse = dict(words_first_chosen_in_days_1_to_14=len(first_half), reuse_rate=reuse_rate)

    text_without_hash = sum(row['text_captured'] and row['literal_pair'] for row in unavailable)
    excluded_unknown = sum(row['measurement_fingerprint'] == 'unknown' for row in known)
    return dict(window=dict(days=args.days, first_day=first_day.isoformat(),
                            last_day=(exclusive_day - timedelta(days=1)).isoformat(),
                            since=args.since, until=args.until, until_exclusive=True),
                metric_scope=dict(rule_fingerprint=measurement_identity, policy='latest_compatible_metric_rules',
                                  unit='known_rank_decision', known_rank_decisions=len(known),
                                  included_decisions=len(included), excluded_decisions=len(known) - len(included),
                                  excluded_unknown_decisions=excluded_unknown),
                pair_coverage=dict(pair_identity=len(decisions), pair_unavailable=len(unavailable),
                                   text_without_hash=text_without_hash),
                units=dict(decisions=len(decisions), pairs=len(pairs), words=len(words)),
                l_ttl=ttl, l_futile=futile, l_util=util, l_avoid=avoid, l_reuse=reuse,
                instrument_constants=dict(
                    window_days=LEARNING_REUSE_WINDOW_DAYS, censoring_margin_days=LEARNING_CENSOR_DAYS,
                    futile_selections=LEARNING_FUTILE_SELECTIONS, reuse_split_days=LEARNING_REUSE_SPLIT_DAYS,
                    minimum_units=LEARNING_MIN_UNITS, learned_provenance=LEARNED_PROVENANCE,
                    code_normalization='consumed_span_lowercase_without_apostrophes',
                    hash='hmac_sha256_128_bits_domains_code:_and_text:',
                    pair_id="code_hash || '|' || selected_text_hash"),
                identity_coverage=identity_coverage(db, sql, parameters, 'observations', 'filtered_decisions'))

def write_trend_svg(result, path):
    path = Path(path).expanduser().resolve()
    if not path.parent.is_dir():
        raise QueryError(f'Chart output directory does not exist: {path.parent}')
    overall = result['series']['overall']
    width, height = 1200, 760
    left, right, top = 82, 40, 78
    plot_width = width-left-right
    rate_top, rate_height = top, 390
    bars_top, bars_height = 545, 125
    def x(index):
        return left + (plot_width * index / max(1, len(overall)-1))
    values = [100*point[key][metric] for point in overall
              for key in ('daily','rolling_7d','rolling_28d')
              for metric in ('top1_rate','top3_rate') if point[key][metric] is not None]
    y_min = max(0, min(values, default=80)-3)
    def y(value):
        return rate_top + rate_height * (100-value) / max(1, 100-y_min)
    def polyline(key, metric, color, width_value, dash=None):
        segments, current = [], []
        for index, point in enumerate(overall):
            value = point[key][metric]
            if value is None:
                if current: segments.append(current); current=[]
            else:
                current.append(f'{x(index):.1f},{y(100*value):.1f}')
        if current: segments.append(current)
        dash_value = f' stroke-dasharray="{dash}"' if dash else ''
        return ''.join(f'<polyline points="{" ".join(segment)}" fill="none" stroke="{color}" stroke-width="{width_value}"{dash_value} stroke-linejoin="round" stroke-linecap="round"/>' for segment in segments)
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
           '<rect width="100%" height="100%" fill="#fbfbfd"/>',
           '<style>text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;fill:#202124}.muted{fill:#687078}.grid{stroke:#dfe3e8;stroke-width:1}.version{stroke:#9a67d8;stroke-width:1.5;stroke-dasharray:5 5}</style>',
           '<text x="82" y="38" font-size="24" font-weight="700">InkFlow Top1 and Top3 selection trend</text>',
           f'<text x="82" y="61" font-size="13" class="muted">{escape(result["window"]["first_day"])} to {escape(result["window"]["last_day"])} · daily continuity · versions are annotations</text>']
    for tick in range(int(y_min//5*5), 101, 5):
        yy = y(tick)
        if rate_top-1 <= yy <= rate_top+rate_height+1:
            svg += [f'<line class="grid" x1="{left}" y1="{yy:.1f}" x2="{width-right}" y2="{yy:.1f}"/>',
                    f'<text x="{left-12}" y="{yy+4:.1f}" text-anchor="end" font-size="11" class="muted">{tick}%</text>']
    for index, point in enumerate(overall):
        top1 = point['daily']['top1_rate']
        top3 = point['daily']['top3_rate']
        if top1 is not None:
            svg.append(f'<circle cx="{x(index):.1f}" cy="{y(100*top1):.1f}" r="2.5" fill="#9aa0a6" opacity="0.72"/>')
        if top3 is not None:
            svg.append(f'<circle cx="{x(index):.1f}" cy="{y(100*top3):.1f}" r="2.8" fill="none" stroke="#d97706" stroke-width="1.4" opacity="0.82"/>')
    svg += [polyline('rolling_28d', 'top1_rate', '#1677d2', 2.8, '8 5'),
            polyline('rolling_7d', 'top1_rate', '#1677d2', 3.2),
            polyline('rolling_28d', 'top3_rate', '#d97706', 2.8, '8 5'),
            polyline('rolling_7d', 'top3_rate', '#d97706', 3.2)]
    markers_by_day = {}
    for marker in result['version_markers']:
        markers_by_day.setdefault(marker['local_day'], []).append(marker)
    day_index = {point['date']: index for index, point in enumerate(overall)}
    for marker_index, (day, markers) in enumerate(markers_by_day.items()):
        if day not in day_index: continue
        xx = x(day_index[day])
        svg.append(f'<line class="version" x1="{xx:.1f}" y1="{rate_top}" x2="{xx:.1f}" y2="{bars_top+bars_height}"/>')
        label = '/'.join(sorted({str(item['app_version']) for item in markers}))
        svg.append(f'<text x="{xx+5:.1f}" y="{rate_top+16+(marker_index%3)*15}" font-size="11" fill="#7651a8">v{escape(label)}</text>')
    maximum = max((point['daily']['valid'] for point in overall), default=0) or 1
    bar_width = max(2, plot_width/max(1, len(overall))*0.65)
    for index, point in enumerate(overall):
        bar_height = bars_height*point['daily']['valid']/maximum
        svg.append(f'<rect x="{x(index)-bar_width/2:.1f}" y="{bars_top+bars_height-bar_height:.1f}" width="{bar_width:.1f}" height="{bar_height:.1f}" rx="2" fill="#87b9e8"/>')
        if index % max(1, len(overall)//7) == 0 or index == len(overall)-1:
            svg.append(f'<text x="{x(index):.1f}" y="{bars_top+bars_height+24}" text-anchor="middle" font-size="11" class="muted">{escape(point["date"][5:])}</text>')
    svg += [f'<text x="{left}" y="{bars_top-14}" font-size="13" font-weight="600">Daily valid selections</text>',
            '<line x1="620" y1="31" x2="648" y2="31" stroke="#1677d2" stroke-width="3"/><text x="655" y="35" font-size="11">Top1</text>',
            '<line x1="710" y1="31" x2="738" y2="31" stroke="#d97706" stroke-width="3"/><text x="745" y="35" font-size="11">Top3</text>',
            '<circle cx="816" cy="31" r="2.8" fill="#6b7280"/><text x="826" y="35" font-size="11">daily</text>',
            '<line x1="890" y1="31" x2="918" y2="31" stroke="#6b7280" stroke-width="3"/><text x="925" y="35" font-size="11">7-day</text>',
            '<line x1="1000" y1="31" x2="1028" y2="31" stroke="#6b7280" stroke-width="3" stroke-dasharray="8 5"/><text x="1035" y="35" font-size="11">28-day</text>',
            '</svg>']
    path.write_text(''.join(svg), encoding='utf-8')
    return path


def ranking_issues(db, args):
    sql, parameters = ctes(args)
    group = ','.join(ISSUE_GROUP)
    match = ' AND '.join(f's.{key} IS g.{key}' for key in ISSUE_GROUP)
    operation_sql = ','.join(f"SUM(json_extract(operations_json,'$.{field}')) AS {key}" for key, field in OPERATIONS.items())
    parameters.update(min_count=args.min_count, limit=args.limit)
    issues = rows(db, sql + f""", eligible AS (
        SELECT * FROM observations WHERE valid AND display_rank IS NOT NULL AND text_captured=1
          AND first_page_top1 IS NOT NULL AND selected_text != first_page_top1
    ), samples AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY {group} ORDER BY composition_id) AS position
        FROM (SELECT DISTINCT {group},composition_id FROM eligible)
    ), grouped AS (
        SELECT {group},COUNT(*) AS occurrences,AVG(display_rank) AS mean_display_rank,
          AVG(native_rank) AS mean_native_rank,{operation_sql},SUM(page_history_truncated) AS truncated
        FROM eligible GROUP BY {group} HAVING COUNT(*) >= :min_count
        ORDER BY page_turns DESC,occurrences DESC,{group} LIMIT :limit
    ) SELECT g.*,(SELECT json_group_array(composition_id) FROM
        (SELECT s.composition_id FROM samples s WHERE {match} AND s.position<=5 ORDER BY s.position)) AS composition_ids
      FROM grouped g ORDER BY page_turns DESC,occurrences DESC,{group}
    """, parameters)
    for issue in issues:
        issue['composition_ids'] = json.loads(issue['composition_ids'])
    return dict(coverage=coverage(db, sql, parameters),
                identity_coverage=identity_coverage(db, sql, parameters, 'observations', 'filtered_decisions'),
                min_count=args.min_count, limit=args.limit,
                evidence_ids_per_issue=5, issues=issues)


def decode_row(row):
    if row is None:
        return None
    return {
        key.removesuffix('_json') if key.endswith('_json') else key:
        (json.loads(value) if value is not None else None) if key.endswith('_json') else value
        for key, value in row.items()}


def sql_distribution(db, sql, parameters, expression, total, unit):
    # SQLite sorts scalar values; only the four interpolation endpoints reach Python.
    result = db.execute(sql + f""", values_to_rank AS (SELECT {expression} AS value FROM cohort),
        ranked AS (SELECT value,ROW_NUMBER() OVER (ORDER BY value)-1 AS position,COUNT(*) OVER () AS n
                   FROM values_to_rank WHERE typeof(value) IN ('integer','real') AND value>=0)
        SELECT MAX(n) AS n,
          MAX(CASE WHEN position=CAST((n-1)*0.50 AS INTEGER) THEN value END) AS low50,
          MAX(CASE WHEN position=CAST((n-1)*0.50 AS INTEGER)+1 THEN value END) AS high50,
          MAX(CASE WHEN position=CAST((n-1)*0.95 AS INTEGER) THEN value END) AS low95,
          MAX(CASE WHEN position=CAST((n-1)*0.95 AS INTEGER)+1 THEN value END) AS high95 FROM ranked
        """, parameters).fetchone()
    count = result['n'] or 0
    def percentile(suffix, p):
        if not count:
            return None
        low, high = result['low'+suffix], result['high'+suffix]
        position = (count-1)*p
        return low if high is None else low+(high-low)*(position-int(position))
    return dict(unit=unit, count=count, unknown=total-count, p50=percentile('50', 0.5), p95=percentile('95', 0.95),
                interpolation='linear_at_(n-1)*p')

def timing(db, args):
    composition_filter, _, parameters = filters(args)
    sql = f"""WITH selected AS (SELECT c.operations_json FROM compositions c WHERE {composition_filter}),
        timings AS (SELECT json_extract(operations_json,'$.timing') AS timing FROM selected
                    WHERE json_type(operations_json,'$.timing')='object' AND json_extract(operations_json,'$.timing.version')=1),
        keys AS (SELECT j.value AS sample FROM timings t,json_each(t.timing,'$.keySamples') j)
        """
    coverage = rows(db, sql + """SELECT
        (SELECT COUNT(*) FROM selected) AS compositions, COUNT(*) AS timing_v1,
        (SELECT COUNT(*) FROM selected WHERE json_type(operations_json,'$.timing') IS NULL
            OR json_type(operations_json,'$.timing')='null') AS unavailable,
        COALESCE(SUM(json_extract(timing,'$.endedOffset') IS NOT NULL),0) AS ended,
        COALESCE(SUM(json_extract(timing,'$.endedOffset') IS NULL),0) AS unfinished,
        COALESCE(SUM(COALESCE(json_extract(timing,'$.droppedKeyCount'),0)>0),0) AS truncated_compositions,
        COALESCE(SUM(json_extract(timing,'$.droppedKeyCount')),0) AS dropped_keys,
        (SELECT COUNT(*) FROM keys) AS retained_keys FROM timings""", parameters)[0]
    coverage['unsupported_version'] = coverage['compositions']-coverage['unavailable']-coverage['timing_v1']
    key_sql = sql + ',cohort AS (SELECT sample FROM keys)'
    intervals = sql_distribution(db, key_sql, parameters, "json_extract(sample,'$.interval')", coverage['retained_keys'], 'seconds')
    groups = rows(db, sql + """SELECT json_extract(sample,'$.kind') AS kind,json_extract(sample,'$.isRepeat') AS is_repeat,
        COUNT(*) AS count FROM keys GROUP BY kind,is_repeat ORDER BY kind,is_repeat""", parameters)
    # The bounded category/repeat groups return only counts and interpolation endpoints.
    for group in groups:
        group_parameters = dict(parameters, key_kind=group['kind'], key_repeat=group['is_repeat'])
        group_sql = sql + """,cohort AS (SELECT sample FROM keys WHERE json_extract(sample,'$.kind') IS :key_kind
            AND json_extract(sample,'$.isRepeat') IS :key_repeat)"""
        group['intervals'] = sql_distribution(db, group_sql, group_parameters, "json_extract(sample,'$.interval')", group.pop('count'), 'seconds')
        if group['is_repeat'] is not None:
            group['is_repeat'] = bool(group['is_repeat'])
    durations = {}
    for state, condition, count in [('ended', 'IS NOT NULL', coverage['ended']),
                                    ('unfinished_observations', 'IS NULL', coverage['unfinished'])]:
        duration_sql = sql + f",cohort AS (SELECT timing FROM timings WHERE json_extract(timing,'$.endedOffset') {condition})"
        durations[state] = {field: sql_distribution(db, duration_sql, parameters, f"json_extract(timing,'$.{field}')", count, 'seconds')
                            for field in ('postEditWait', 'observedVisibleDuration', 'phaseWait', 'phaseObservedVisibleDuration')}
    identity_sql = f"""WITH selected_compositions AS (
            SELECT c.* FROM compositions c WHERE {composition_filter}
        ), timing_identities AS (
            SELECT r.ranking_fingerprint,r.settings_fingerprint,r.measurement_fingerprint,r.build_identity
            FROM candidate_decisions d JOIN selected_compositions c ON c.id=d.composition_id
            JOIN config_revisions r ON r.id=d.config_revision_id
        ) """
    return dict(scope='composition_operations_once', coverage=coverage,
                identity_coverage=identity_coverage(db, identity_sql, parameters, 'timing_identities',
                                                    'decisions_in_selected_timing_compositions'),
                key_intervals=dict(scope='retained_samples_only; each stored interval uses the actual preceding key',
                                   all=intervals, by_category_repeat=groups), durations=durations,
                visibility_observation_interval=sql_distribution(db, sql+',cohort AS (SELECT timing FROM timings)', parameters,
                    "json_extract(timing,'$.visibilityObservationInterval')", coverage['timing_v1'], 'seconds'),
                observation='controller keyDown receipt with monotonic clock; visibility polled nominally every 0.1 seconds, not attention or exact render onset')


def inspect(db, args):
    composition_filter, decision_filter, parameters = filters(args)
    parameters['id'] = args.composition_id
    raw = db.execute('SELECT * FROM compositions WHERE id=:id', parameters).fetchone()
    if raw is None:
        raise QueryError(f'Composition not found: {args.composition_id}')
    found = db.execute(f'SELECT c.id FROM compositions c WHERE c.id=:id AND {composition_filter}', parameters).fetchone()
    if found is None:
        raise QueryError('Composition exists but does not match the supplied filters.')
    decisions = rows(db, f'''SELECT d.*,r.fingerprint,r.ranking_fingerprint,r.settings_fingerprint,
        r.measurement_fingerprint,r.build_identity FROM candidate_decisions d JOIN config_revisions r
        ON r.id=d.config_revision_id WHERE d.composition_id=:id AND {decision_filter} ORDER BY d.sequence''', parameters)
    decoded_decisions = [decode_row(d) for d in decisions]
    revision_ids = {d['config_revision_id'] for d in decisions}
    for decision in decoded_decisions:
        pages = [decision['snapshot'], decision['first_page']] + decision['visited_pages']
        revision_ids.update(page['configurationRevisionID'] for page in pages if page is not None)
    revisions = []
    for revision_id in sorted(revision_ids):
        revision = db.execute('SELECT * FROM config_revisions WHERE id=?', (revision_id,)).fetchone()
        if revision is None:
            raise QueryError('A recorded page references a missing configuration revision.')
        revisions.append(dict(revision))
    commits = rows(db, 'SELECT * FROM commits WHERE composition_id=:id ORDER BY issued_at,id', parameters)
    # A window is stored on the composition after its commit, so it is found through the commit.
    windows = rows(db, 'WITH ' + windows_cte(args) + ''' SELECT w.* FROM windows w JOIN commits m ON m.id=w.commit_id
        WHERE m.composition_id=:id ORDER BY m.issued_at,m.id''', parameters)
    decoded_revisions = [decode_row(r) for r in revisions]
    return dict(composition=decode_row(dict(raw)), decisions=decoded_decisions,
                commits=commits, windows=windows, configurations=decoded_revisions,
                identity_coverage=revision_identity_coverage(revisions),
                commit_scope='all commits of the matching composition; decisions honor config/kind filters')


def replay_output(path):
    path = path.expanduser().resolve()
    if path == REPOSITORY or REPOSITORY in path.parents:
        raise QueryError(f'Replay files hold typed text; choose a path outside the repository: {path}')
    return path


def replay_page(row):
    """The page a case replays and where it came from: the commit-time list on page 0, else the first page."""
    snapshot = json.loads(row['snapshot_json'])
    if snapshot['page'] == 0:
        return snapshot, 'snapshot'
    first = json.loads(row['first_page_json']) if row['first_page_json'] is not None else None
    if (first and first['candidates'] and first['page'] == 0
            and all(first.get(field) == snapshot.get(field) for field in SAME_GENERATION_FIELDS)):
        return first, 'first_page'
    return None, 'first_page'


def replay_candidate(candidate):
    return dict(text=candidate['text'], display_index=candidate['displayIndex'],
                native_index=candidate['nativeIndex'], native_rank=candidate['nativeRank'],
                type=candidate.get('type'), corrected=candidate.get('corrected'),
                evidence=candidate.get('evidence'), source=candidate.get('source'))


def replay_cases(db, args):
    sql, parameters = ctes(args)
    decisions = db.execute(sql + """SELECT composition_id, id AS decision_id, occurred_at, text_captured,
        raw_input, preceding_context, page, selected_display_index, selected_text, commit_text,
        snapshot_json, first_page_json FROM observations WHERE regular_committed
        ORDER BY composition_started_at, occurred_at, sequence, id""", parameters)
    counts = dict(cases=0, text_free_excluded=0, without_evidence=0, without_first_page=0)
    cases = []
    for row in decisions:
        if not row['text_captured']:
            counts['text_free_excluded'] += 1
            continue
        page, source = replay_page(row)
        if page is None:
            counts['without_first_page'] += 1
            continue
        candidates = [replay_candidate(candidate) for candidate in page['candidates']]
        if any(candidate['evidence'] is None for candidate in candidates):
            counts['without_evidence'] += 1
        counts['cases'] += 1
        cases.append(dict(composition_id=row['composition_id'], decision_id=row['decision_id'],
                          occurred_at=row['occurred_at'], raw_input=row['raw_input'],
                          preceding_context=row['preceding_context'], page=row['page'], candidates_from=source,
                          candidates=candidates, selected_display_index=row['selected_display_index'],
                          selected_text=row['selected_text'], committed_text=row['commit_text']))
    generated_at = datetime.now(timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    header = dict(generated_at=generated_at, window=dict(since=args.since, until=args.until), kind=args.kind,
                  **counts)
    # Typed text: owner-only, never over an existing file, and not left half written.
    descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
        try:
            for line in [header] + cases:
                stream.write(json.dumps(line, ensure_ascii=False, separators=(',', ':')) + '\n')
        except BaseException:
            args.output.unlink(missing_ok=True)
            raise
    return dict(output=str(args.output), header=header)


def leaves(value, path='$'):
    if isinstance(value, dict) and value:
        for key, child in value.items():
            yield from leaves(child, f'{path}.{key}')
    elif isinstance(value, list) and value:
        for index, child in enumerate(value):
            yield from leaves(child, f'{path}[{index}]')
    else:
        yield path, value


def render(result, output_format):
    if output_format == 'json':
        print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
    elif output_format == 'csv':
        writer = csv.writer(sys.stdout)
        writer.writerow(['path', 'value'])
        for path, value in leaves(result):
            writer.writerow([path, json.dumps(value, ensure_ascii=False, allow_nan=False)])
    else:
        # Vertical tables preserve complete fingerprints, Unicode and long context without clipping.
        print('FIELD | VALUE')
        for path, value in leaves(result):
            display = 'N/A' if value is None else json.dumps(value, ensure_ascii=False, allow_nan=False)
            print(f'{path} | {display}')


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest='command', required=True)
    for command in ('trend', 'summary', 'ranking-issues', 'inspect', 'timing', 'replay-cases', 'learning', 'export'):
        sub = commands.add_parser(command)
        if command == 'export':
            sub.add_argument('--output', type=Path, required=True, help='New JSON file; records saved with text recording on contain input text, candidates and preceding context. Never uploaded.')
        if command == 'replay-cases':
            sub.add_argument('--output', type=Path, required=True,
                             help='New JSON Lines file outside the repository: one case per regular committed '
                                  'decision, with typed text. Delete it after the run. Never uploaded.')
        if command != 'export':
            sub.add_argument('--input', type=Path, action='append', default=[], help='Quality export JSON; repeat for multiple files')
            sub.add_argument('--exports-only', action='store_true', help='Analyze files without the local database')
            sub.add_argument('--source', help='Exact source UUID from the export; isolates one device')
        if command == 'inspect':
            sub.add_argument('composition_id', help='Composition ID returned by ranking-issues')
        if command == 'ranking-issues':
            sub.add_argument('--min-count', type=positive, default=3)
            sub.add_argument('--limit', type=positive, default=50)
        if command in ('trend', 'learning'):
            sub.add_argument('--days', type=positive, default=28,
                             help='Local calendar days ending before --until; default 28')
        if command == 'trend':
            sub.add_argument('--chart', type=Path, help='Write a self-contained SVG trend chart')
        sub.add_argument('--db', type=Path, default=DEFAULT_DB, help=f'Default: {DEFAULT_DB}')
        sub.add_argument('--since', type=timestamp, help='Inclusive composition start: local YYYY-MM-DD or ISO time with offset')
        sub.add_argument('--until', type=timestamp, help='Exclusive composition start boundary; same syntax as --since')
        sub.add_argument('--app', help='Exact app bundle ID')
        sub.add_argument('--config', help='Exact legacy full fingerprint (not revision UUID or prefix)')
        sub.add_argument('--ranking-config', help='Exact ranking fingerprint (not revision UUID or prefix)')
        sub.add_argument('--kind', choices=KINDS, help='Decision text kind, not translator source')
        if command == 'replay-cases':
            sub.set_defaults(kind='chinese')
        sub.add_argument('--format', choices=('table', 'json', 'csv'), default='table')
    return result


def main(argv=None):
    try:
        args = parser().parse_args(argv)
        if (args.since and args.until and datetime.fromisoformat(args.since)
                >= datetime.fromisoformat(args.until)):
            raise QueryError('--since must be earlier than the exclusive --until boundary.')
        if args.command == 'export':
            if any(getattr(args, key) is not None for key in ('since', 'until', 'app', 'config', 'ranking_config', 'kind')):
                raise QueryError('Export includes all retained records; query filters apply only during analysis.')
            render(quality_exchange.export(args.db, args.output, connect, TABLE_COLUMNS), args.format)
            return 0
        handler = {'trend': trend, 'summary': summary, 'ranking-issues': ranking_issues, 'inspect': inspect,
                   'timing': timing, 'replay-cases': replay_cases, 'learning': learning}[args.command]
        if args.command == 'replay-cases':
            args.output = replay_output(args.output)
        if args.input or args.exports_only or args.source:
            if args.exports_only and not args.input:
                raise QueryError('--exports-only requires at least one --input file.')
            documents = [quality_exchange.load(path, TABLE_COLUMNS) for path in args.input]
            if not args.exports_only:
                local = quality_exchange.snapshot(args.db, connect, TABLE_COLUMNS)
                local['_input_path'] = str(args.db.expanduser().resolve())
                documents.append(local)
            db, sources = quality_exchange.combine(documents, TABLE_COLUMNS)
            with closing(db):
                if args.source and args.source not in sources:
                    raise QueryError('Requested source is not present in these inputs.')
                if args.command == 'learning' and len(sources) > 1 and not args.source:
                    raise QueryError('learning hashes are keyed per device and never link across devices; '
                                     'choose one with --source.')
                original_args = copy(args)
                result = handler(db, args)
                result['sources'] = list(sources.values())
                result['analysis_storage'] = 'memory_only; external records never written to local quality database'
                if args.command not in ('inspect', 'replay-cases', 'learning') and not args.source:
                    result['by_source'] = {}
                    for sid in sources:
                        device_args = copy(original_args); device_args.source = sid
                        result['by_source'][sid] = handler(db, device_args)
        else:
            with closing(connect(args.db)) as db:
                db.execute('BEGIN')  # One consistent read snapshot; close before formatting/output.
                result = handler(db, args)
        if args.command == 'trend' and args.chart is not None:
            result['chart_path'] = str(write_trend_svg(result, args.chart))
        result = dict(command=args.command, filters={k: str(v) if isinstance(v, Path) else v
                      for k, v in vars(args).items()
                      if k in ('db','since','until','app','config','ranking_config','kind','days','source','exports_only')}, **result)
        if args.exports_only:
            result['filters']['db'] = None
        if args.input:
            result['filters']['input'] = [str(p) for p in args.input]
        render(result, args.format)
        return 0
    except SystemExit as error:
        return error.code
    except (QueryError, sqlite3.Error, ValueError, OSError) as error:
        print(f'quality: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
