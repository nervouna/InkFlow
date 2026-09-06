#!/usr/bin/env python3
"""Read-only queries for InkFlow quality schema / metric rule v1 (stdlib only)."""
import argparse
from contextlib import closing
import csv
from datetime import date, datetime, time, timedelta, timezone
import json
from pathlib import Path
import sqlite3
import sys

DEFAULT_DB = Path.home() / 'Library/Application Support/InkFlow/quality.sqlite3'
KINDS = ('chinese', 'english', 'emoji', 'mixed', 'symbol', 'number', 'other', 'unknown')
TABLE_COLUMNS = {
    'recording_runs': 'id started_at ended_at status engine_version build_metadata_json metric_rule_version stats_json error_code',
    'config_revisions': 'id fingerprint created_at applied_config_json build_metadata_json engine_version metric_rule_version',
    'compositions': 'id run_id started_at ended_at app_bundle_id client_id outcome page_history_truncated dropped_page_count outcome_reason operations_json',
    'commits': 'id composition_id issued_at text kind insertion_issued client_id',
    'candidate_decisions': 'id composition_id config_revision_id commit_id occurred_at sequence trigger outcome selected_display_index selected_text text_kind snapshot_json first_page_json visited_pages_json page_history_truncated dropped_page_count operations_json regular_ranked_selection matches_custom_phrase unknown_rank_reason path_reason',
}
GROUP = ('fingerprint', 'text_kind', 'presentation')
ISSUE_GROUP = ('fingerprint', 'raw_input', 'caret', 'selected_prefix', 'selected_prefix_valid',
               'preceding_context', 'first_page_top1', 'selected_text', 'text_kind', 'matches_custom_phrase')
OPERATIONS = {'keypresses': 'keypresses', 'page_requests': 'pageRequests', 'page_turns': 'pageTurns',
              'candidate_moves': 'candidateMoves', 'preedit_edits': 'preeditEdits'}
COUNTERS = {
    'committed': "outcome='committed'", 'unknown': "outcome='unknown'", 'reverted': "outcome='reverted'",
    'edited': "outcome='edited'", 'cancelled': "outcome='cancelled'", 'interrupted': "outcome='interrupted'",
    'tentative': "outcome='tentative'", 'regular_issued': 'regular_committed AND insertion_issued=1',
    'regular_not_issued': 'regular_committed AND insertion_issued=0',
    'regular_insertion_unknown': 'regular_committed AND insertion_issued IS NULL',
    'valid': 'valid', 'known_rank': 'valid AND display_rank IS NOT NULL',
    'unknown_rank': 'valid AND display_rank IS NULL',
    'comparable': 'valid AND display_rank IS NOT NULL AND first_page_top1 IS NOT NULL',
    'first_page_unavailable': 'valid AND display_rank IS NOT NULL AND first_page_top1 IS NULL',
    'top1_selected': 'valid AND display_rank=1',
    'top1_matches': 'valid AND display_rank IS NOT NULL AND selected_text=first_page_top1',
    'truncated': 'page_history_truncated=1',
}


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
        if (db.execute('PRAGMA user_version').fetchone()[0] != 1
                or db.execute('PRAGMA application_id').fetchone()[0] != 0x49465131):
            raise QueryError('Database is incompatible: expected InkFlow quality schema v1 (IFQ1).')
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,7)!='sqlite_'")}
        if tables != set(TABLE_COLUMNS):
            raise QueryError('Database is incompatible: expected the five InkFlow quality tables.')
        for table, columns in TABLE_COLUMNS.items():
            actual = {r['name'] for r in db.execute(f'PRAGMA table_info({table})')}
            if not set(columns.split()) <= actual:
                raise QueryError(f'Database is incompatible: missing columns in {table}.')
        for table in ('recording_runs', 'config_revisions'):
            if db.execute(f'SELECT 1 FROM {table} WHERE metric_rule_version != 1 LIMIT 1').fetchone():
                raise QueryError('Database is incompatible: this query supports metric rule v1 only.')
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
    for option, condition in [('config', 'r.fingerprint = :config'), ('kind', 'd.text_kind = :kind')]:
        if (value := getattr(args, option)) is not None:
            decision.append(condition)
            parameters[option] = value
    if decision:
        composition.append('EXISTS (SELECT 1 FROM candidate_decisions d JOIN config_revisions r '
                           'ON r.id=d.config_revision_id WHERE d.composition_id=c.id AND '
                           + ' AND '.join(decision) + ')')
    return ' AND '.join(composition) or '1', ' AND '.join(decision) or '1', parameters


def ctes(args):
    composition_filter, decision_filter, parameters = filters(args)
    same_generation = ' AND '.join(
        f"json_extract(first_page_json,'$.{field}') = json_extract(snapshot_json,'$.{field}')"
        for field in ('generation', 'rawInput', 'caret', 'selectedPrefix', 'selectedPrefixValid',
                      'precedingContext', 'configurationRevisionID', 'pageSize'))
    sql = f"""
    WITH selected_compositions AS (
        SELECT c.* FROM compositions c WHERE {composition_filter}
    ), base AS (
        SELECT d.*, r.fingerprint, m.insertion_issued,
          json_extract(d.snapshot_json,'$.presentation') AS presentation,
          json_extract(d.snapshot_json,'$.rawInput') AS raw_input,
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
        WHERE {decision_filter}
    ), ranked AS (
        SELECT *, CASE WHEN json_extract(selected_candidate,'$.text')=selected_text
          AND json_extract(selected_candidate,'$.displayIndex')=selected_display_index
          AND page>=0 AND page_size>0 AND selected_display_index<page_size
          AND json_extract(selected_candidate,'$.displayRank')=page*page_size+selected_display_index+1
          THEN json_extract(selected_candidate,'$.displayRank') END AS display_rank,
          CASE WHEN json_extract(selected_candidate,'$.text')=selected_text
          AND json_extract(selected_candidate,'$.nativeIndex')>=0
          AND json_extract(selected_candidate,'$.nativeIndex')<page_size
          AND json_extract(selected_candidate,'$.nativeRank')=page*page_size+json_extract(selected_candidate,'$.nativeIndex')+1
          THEN json_extract(selected_candidate,'$.nativeRank') END AS native_rank,
          CASE WHEN selected_prefix_valid=1 AND {same_generation}
          AND json_extract(first_page_json,'$.page')=0
          AND json_extract(first_page_json,'$.candidates[0].displayIndex')=0
          AND json_extract(first_page_json,'$.candidates[0].displayRank')=1
          THEN json_extract(first_page_json,'$.candidates[0].text') END AS first_page_top1
        FROM base
    ), observations AS (
        SELECT *, COALESCE(regular_committed AND insertion_issued=1
          AND presentation IN ('candidates_requested','panel_show_issued'),0) AS valid
        FROM ranked
    )
    """
    return sql, parameters


def rows(db, sql, parameters=None):
    return [dict(row) for row in db.execute(sql, parameters or {})]


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


def rates(row):
    row['top1_rate'] = row['top1_selected'] / row['known_rank'] if row['known_rank'] else None
    row['top1_match_rate'] = row['top1_matches'] / row['comparable'] if row['comparable'] else None
    return row


def coverage(db, sql, parameters):
    result = rates(rows(db, sql + 'SELECT ' + aggregate_sql() + ' FROM observations', parameters)[0])
    result.update(rows(db, sql + """SELECT COUNT(*) AS compositions,
        COALESCE(SUM(page_history_truncated),0) AS truncated_compositions,
        (SELECT COUNT(*) FROM commits WHERE composition_id IN (SELECT id FROM selected_compositions)) AS commits,
        (SELECT COUNT(*) FROM commits WHERE insertion_issued=0 AND composition_id IN
          (SELECT id FROM selected_compositions)) AS commits_not_issued
        FROM selected_compositions""", parameters)[0])
    return result


def summary(db, args):
    sql, parameters = ctes(args)
    group = ','.join(GROUP)
    groups = rows(db, sql + f'SELECT {group}, {aggregate_sql()} FROM observations GROUP BY {group} ORDER BY {group}', parameters)
    ranks = rows(db, sql + f'''SELECT {group},display_rank,COUNT(*) AS count FROM observations
        WHERE valid AND display_rank IS NOT NULL GROUP BY {group},display_rank ORDER BY {group},display_rank''', parameters)
    run_counters = ('submitted', 'written', 'droppedQueue', 'droppedOversized', 'droppedDisabled',
                    'droppedBusy', 'droppedInvalid', 'errors', 'truncatedEnvelopes')
    run_sql = ','.join(f"COALESCE(SUM(json_extract(stats_json,'$.{key}')),0) AS {key}" for key in run_counters)
    return dict(coverage=coverage(db, sql, parameters), groups=[rates(g) for g in groups], rank_counts=ranks,
                recording_runs=dict(scope='whole_db_lifetime_unfiltered',
                    totals=rows(db, 'SELECT COUNT(*) AS runs,' + run_sql + ' FROM recording_runs')[0],
                    statuses=rows(db, 'SELECT status,error_code,COUNT(*) AS runs FROM recording_runs GROUP BY status,error_code')))


def ranking_issues(db, args):
    sql, parameters = ctes(args)
    group = ','.join(ISSUE_GROUP)
    match = ' AND '.join(f's.{key} IS g.{key}' for key in ISSUE_GROUP)
    operation_sql = ','.join(f"SUM(json_extract(operations_json,'$.{field}')) AS {key}" for key, field in OPERATIONS.items())
    parameters.update(min_count=args.min_count, limit=args.limit)
    issues = rows(db, sql + f""", eligible AS (
        SELECT * FROM observations WHERE valid AND display_rank IS NOT NULL
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
    return dict(coverage=coverage(db, sql, parameters), min_count=args.min_count, limit=args.limit,
                evidence_ids_per_issue=5, issues=issues)


def decode_row(row):
    if row is None:
        return None
    return {
        key.removesuffix('_json') if key.endswith('_json') else key:
        (json.loads(value) if value is not None else None) if key.endswith('_json') else value
        for key, value in row.items()}



def inspect(db, args):
    composition_filter, decision_filter, parameters = filters(args)
    parameters['id'] = args.composition_id
    raw = db.execute('SELECT * FROM compositions WHERE id=:id', parameters).fetchone()
    if raw is None:
        raise QueryError(f'Composition not found: {args.composition_id}')
    found = db.execute(f'SELECT c.id FROM compositions c WHERE c.id=:id AND {composition_filter}', parameters).fetchone()
    if found is None:
        raise QueryError('Composition exists but does not match the supplied filters.')
    decisions = rows(db, f'''SELECT d.*,r.fingerprint FROM candidate_decisions d JOIN config_revisions r
        ON r.id=d.config_revision_id WHERE d.composition_id=:id AND {decision_filter} ORDER BY d.sequence''', parameters)
    revisions = rows(db, f'''SELECT DISTINCT r.* FROM config_revisions r JOIN candidate_decisions d
        ON d.config_revision_id=r.id WHERE d.composition_id=:id AND {decision_filter} ORDER BY r.id''', parameters)
    commits = rows(db, 'SELECT * FROM commits WHERE composition_id=:id ORDER BY issued_at,id', parameters)
    return dict(composition=decode_row(dict(raw)), decisions=[decode_row(d) for d in decisions],
                commits=commits, configurations=[decode_row(r) for r in revisions],
                commit_scope='all commits of the matching composition; decisions honor config/kind filters')


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
    for command in ('summary', 'ranking-issues', 'inspect'):
        sub = commands.add_parser(command)
        if command == 'inspect':
            sub.add_argument('composition_id', help='Composition ID returned by ranking-issues')
        if command == 'ranking-issues':
            sub.add_argument('--min-count', type=positive, default=3)
            sub.add_argument('--limit', type=positive, default=50)
        sub.add_argument('--db', type=Path, default=DEFAULT_DB, help=f'Default: {DEFAULT_DB}')
        sub.add_argument('--since', type=timestamp, help='Inclusive composition start: local YYYY-MM-DD or ISO time with offset')
        sub.add_argument('--until', type=timestamp, help='Exclusive composition start boundary; same syntax as --since')
        sub.add_argument('--app', help='Exact app bundle ID')
        sub.add_argument('--config', help='Exact full stable configuration fingerprint (not revision UUID or prefix)')
        sub.add_argument('--kind', choices=KINDS, help='Decision text kind, not translator source')
        sub.add_argument('--format', choices=('table', 'json', 'csv'), default='table')
    return result


def main(argv=None):
    try:
        args = parser().parse_args(argv)
        if (args.since and args.until and datetime.fromisoformat(args.since)
                >= datetime.fromisoformat(args.until)):
            raise QueryError('--since must be earlier than the exclusive --until boundary.')
        with closing(connect(args.db)) as db:
            db.execute('BEGIN')  # One consistent read snapshot; close before formatting/output.
            result = {'summary': summary, 'ranking-issues': ranking_issues, 'inspect': inspect}[args.command](db, args)
        result = dict(command=args.command, filters={k: str(v) if isinstance(v, Path) else v
                      for k, v in vars(args).items() if k in ('db','since','until','app','config','kind')}, **result)
        render(result, args.format)
        return 0
    except SystemExit as error:
        return error.code
    except (QueryError, sqlite3.Error, ValueError, OSError) as error:
        print(f'quality: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
