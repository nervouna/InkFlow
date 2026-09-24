#!/usr/bin/env python3
"""Read-only queries for InkFlow quality schema v2 (stdlib only)."""
import argparse
from contextlib import closing
import csv
from datetime import date, datetime, time, timedelta, timezone
from html import escape
import json
from pathlib import Path
import sqlite3
import sys

DEFAULT_DB = Path.home() / 'Library/Application Support/InkFlow/quality.sqlite3'
KINDS = ('chinese', 'english', 'emoji', 'mixed', 'symbol', 'number', 'other', 'unknown')
TABLE_COLUMNS = {
    'recording_runs': 'id started_at ended_at status engine_version build_metadata_json metric_rule_version stats_json error_code',
    'config_revisions': ('id fingerprint created_at applied_config_json build_metadata_json engine_version '
                         'metric_rule_version ranking_fingerprint settings_fingerprint '
                         'measurement_fingerprint build_identity'),
    'compositions': 'id run_id started_at ended_at app_bundle_id client_id outcome page_history_truncated dropped_page_count outcome_reason operations_json',
    'commits': 'id composition_id issued_at text kind insertion_issued client_id',
    'candidate_decisions': 'id composition_id config_revision_id commit_id occurred_at sequence trigger outcome selected_display_index selected_text text_kind snapshot_json first_page_json visited_pages_json page_history_truncated dropped_page_count operations_json regular_ranked_selection matches_custom_phrase unknown_rank_reason path_reason',
}
GROUP = ('ranking_fingerprint', 'measurement_fingerprint', 'text_kind', 'presentation')
ISSUE_GROUP = ('ranking_fingerprint', 'measurement_fingerprint', 'raw_input', 'caret', 'selected_prefix', 'selected_prefix_valid',
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
        if (db.execute('PRAGMA user_version').fetchone()[0] != 2
                or db.execute('PRAGMA application_id').fetchone()[0] != 0x49465131):
            raise QueryError('Database is incompatible: expected InkFlow quality schema v2 (IFQ1).')
        tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table' AND substr(name,1,7)!='sqlite_'")}
        if tables != set(TABLE_COLUMNS):
            raise QueryError('Database is incompatible: expected the five InkFlow quality tables.')
        for table, columns in TABLE_COLUMNS.items():
            actual = {r['name'] for r in db.execute(f'PRAGMA table_info({table})')}
            if set(columns.split()) != actual:
                raise QueryError(f'Database is incompatible: unexpected v2 columns in {table}.')
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
        SELECT d.*, c.started_at AS composition_started_at, r.fingerprint,
          COALESCE(r.ranking_fingerprint,'unknown') AS ranking_fingerprint,
          r.settings_fingerprint,
          COALESCE(r.measurement_fingerprint,'unknown') AS measurement_fingerprint,
          r.build_identity, m.insertion_issued,
          json_extract(r.build_metadata_json,'$.appVersion') AS app_version,
          json_extract(r.build_metadata_json,'$.appBuild') AS app_build,
          json_extract(r.build_metadata_json,'$.sourceRevision') AS source_revision,
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


def rates(row, status=None):
    row['top1_rate'] = row['top1_selected'] / row['known_rank'] if row['known_rank'] else None
    row['top1_match_rate'] = row['top1_matches'] / row['comparable'] if row['comparable'] else None
    if status is None:
        status = ('unavailable_unknown_measurement_fingerprint'
                  if row.get('measurement_fingerprint') == 'unknown'
                  else 'available_within_measurement_fingerprint')
    if status != 'available_within_measurement_fingerprint':
        row['top1_rate'] = None
        row['top1_match_rate'] = None
    row['quality_rate_status'] = status
    return row


def coverage(db, sql, parameters):
    measurement = rows(db, sql + """SELECT COUNT(*) AS total,
        COUNT(DISTINCT CASE WHEN measurement_fingerprint!='unknown' THEN measurement_fingerprint END) AS known_distinct,
        COALESCE(SUM(measurement_fingerprint='unknown'),0) AS unknown FROM observations""", parameters)[0]
    if measurement['total'] == 0:
        rate_status = 'unavailable_without_measurement_evidence'
    elif measurement['known_distinct'] == 1 and measurement['unknown'] == 0:
        rate_status = 'available_within_measurement_fingerprint'
    elif measurement['known_distinct'] == 0:
        rate_status = 'unavailable_unknown_measurement_fingerprint'
    else:
        rate_status = 'unavailable_across_measurement_fingerprints'
    result = rates(rows(db, sql + 'SELECT ' + aggregate_sql() + ' FROM observations', parameters)[0],
                   rate_status)
    result.update(rows(db, sql + """SELECT COUNT(*) AS compositions,
        COALESCE(SUM(page_history_truncated),0) AS truncated_compositions,
        (SELECT COUNT(*) FROM commits WHERE composition_id IN (SELECT id FROM selected_compositions)) AS commits,
        (SELECT COUNT(*) FROM commits WHERE insertion_issued=0 AND composition_id IN
          (SELECT id FROM selected_compositions)) AS commits_not_issued
        FROM selected_compositions""", parameters)[0])
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
    run_sql = ','.join(f"COALESCE(SUM(json_extract(stats_json,'$.{key}')),0) AS {key}" for key in run_counters)
    return dict(coverage=coverage(db, sql, parameters),
                identity_coverage=identity_coverage(db, sql, parameters, 'observations', 'filtered_decisions'),
                groups=[rates(g) for g in groups], rank_counts=ranks,
                recording_runs=dict(scope='whole_db_lifetime_unfiltered',
                    totals=rows(db, 'SELECT COUNT(*) AS runs,' + run_sql + ' FROM recording_runs')[0],
                    statuses=rows(db, 'SELECT status,error_code,COUNT(*) AS runs FROM recording_runs GROUP BY status,error_code')))


TREND_COUNTERS = ('decisions', 'valid', 'known_rank', 'unknown_rank', 'comparable',
                  'first_page_unavailable', 'top1_selected', 'top1_matches')


def trend_metric(items):
    result = {key: sum(item.get(key, 0) for item in items) for key in TREND_COUNTERS}
    measurements = {}
    for item in items:
        for identity, count in item.get('_measurements', {}).items():
            measurements[identity] = measurements.get(identity, 0) + count
    known = {identity for identity, count in measurements.items() if identity != 'unknown' and count}
    unknown = measurements.get('unknown', 0)
    if not result['decisions']:
        status = 'unavailable_without_measurement_evidence'
    elif len(known) == 1 and not unknown:
        status = 'available_within_measurement_fingerprint'
    elif not known:
        status = 'unavailable_unknown_measurement_fingerprint'
    else:
        status = 'unavailable_across_measurement_fingerprints'
    result['top1_rate'] = (result['top1_selected'] / result['known_rank']
                           if result['known_rank'] and status == 'available_within_measurement_fingerprint' else None)
    result['top1_match_rate'] = (result['top1_matches'] / result['comparable']
                                 if result['comparable'] and status == 'available_within_measurement_fingerprint' else None)
    result['quality_rate_status'] = status
    result['measurement_fingerprints'] = sorted(known)
    result['unknown_measurement_decisions'] = unknown
    return result


def trend_bounds(args):
    if args.since is not None:
        raise QueryError('trend derives --since from --days; omit --since.')
    if args.until is None:
        exclusive_day = datetime.now().astimezone().date() + timedelta(days=1)
    else:
        local = datetime.fromisoformat(args.until.replace('Z', '+00:00')).astimezone()
        if local.timetz().replace(tzinfo=None) != time():
            raise QueryError('trend --until must be a local calendar date boundary.')
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
        "COALESCE(SUM(valid AND display_rank IS NOT NULL AND selected_text=first_page_top1),0) AS top1_matches",
    ])
    grouped = rows(db, sql + f"""SELECT date(composition_started_at,'localtime') AS local_day,
        text_kind,measurement_fingerprint,{fields} FROM observations
        GROUP BY local_day,text_kind,measurement_fingerprint ORDER BY local_day,text_kind,measurement_fingerprint""", parameters)
    latest_measurement = db.execute(sql + """SELECT measurement_fingerprint FROM observations
        WHERE measurement_fingerprint!='unknown'
        ORDER BY composition_started_at DESC,occurred_at DESC,id DESC LIMIT 1""", parameters).fetchone()
    measurement_identity = latest_measurement['measurement_fingerprint'] if latest_measurement else None
    total_decisions = sum(row['decisions'] for row in grouped)
    included_decisions = sum(row['decisions'] for row in grouped
                             if row['measurement_fingerprint'] == measurement_identity)
    raw = {'overall': {}, **{kind: {} for kind in KINDS}}
    for row in grouped:
        if row['measurement_fingerprint'] != measurement_identity:
            continue
        for series in ('overall', row['text_kind']):
            day = raw[series].setdefault(row['local_day'], {key: 0 for key in TREND_COUNTERS})
            for key in TREND_COUNTERS:
                day[key] += row[key]
            measurements = day.setdefault('_measurements', {})
            measurements[row['measurement_fingerprint']] = measurements.get(row['measurement_fingerprint'], 0) + row['decisions']
    days = [(first_day + timedelta(days=offset)).isoformat() for offset in range(args.days)]
    series = {}
    for name, values in raw.items():
        raw_points = [values.get(day, {**{key: 0 for key in TREND_COUNTERS}, '_measurements': {}}) for day in days]
        points = []
        for index, day in enumerate(days):
            points.append(dict(date=day, daily=trend_metric([raw_points[index]]),
                rolling_7d=trend_metric(raw_points[max(0, index-6):index+1]),
                rolling_28d=trend_metric(raw_points[max(0, index-27):index+1])))
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
                                                   if row['measurement_fingerprint'] == 'unknown')),
                series=series, version_markers=markers,
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
    values = [100*point[key]['top1_rate'] for point in overall for key in ('daily','rolling_7d','rolling_28d')
              if point[key]['top1_rate'] is not None]
    y_min = max(0, min(values, default=80)-3)
    def y(value):
        return rate_top + rate_height * (100-value) / max(1, 100-y_min)
    def polyline(key, color, width_value):
        segments, current = [], []
        for index, point in enumerate(overall):
            value = point[key]['top1_rate']
            if value is None:
                if current: segments.append(current); current=[]
            else:
                current.append(f'{x(index):.1f},{y(100*value):.1f}')
        if current: segments.append(current)
        return ''.join(f'<polyline points="{" ".join(segment)}" fill="none" stroke="{color}" stroke-width="{width_value}" stroke-linejoin="round" stroke-linecap="round"/>' for segment in segments)
    svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}">',
           '<rect width="100%" height="100%" fill="#fbfbfd"/>',
           '<style>text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;fill:#202124}.muted{fill:#687078}.grid{stroke:#dfe3e8;stroke-width:1}.version{stroke:#9a67d8;stroke-width:1.5;stroke-dasharray:5 5}</style>',
           '<text x="82" y="38" font-size="24" font-weight="700">InkFlow input quality trend</text>',
           f'<text x="82" y="61" font-size="13" class="muted">{escape(result["window"]["first_day"])} to {escape(result["window"]["last_day"])} · daily continuity · versions are annotations</text>']
    for tick in range(int(y_min//5*5), 101, 5):
        yy = y(tick)
        if rate_top-1 <= yy <= rate_top+rate_height+1:
            svg += [f'<line class="grid" x1="{left}" y1="{yy:.1f}" x2="{width-right}" y2="{yy:.1f}"/>',
                    f'<text x="{left-12}" y="{yy+4:.1f}" text-anchor="end" font-size="11" class="muted">{tick}%</text>']
    for index, point in enumerate(overall):
        value = point['daily']['top1_rate']
        if value is not None:
            svg.append(f'<circle cx="{x(index):.1f}" cy="{y(100*value):.1f}" r="2.5" fill="#9aa0a6" opacity="0.72"/>')
    svg += [polyline('rolling_28d', '#7b61a8', 3.2), polyline('rolling_7d', '#1677d2', 3.2)]
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
            '<circle cx="780" cy="38" r="3" fill="#9aa0a6"/><text x="790" y="42" font-size="12">daily</text>',
            '<line x1="850" y1="38" x2="878" y2="38" stroke="#1677d2" stroke-width="3"/><text x="885" y="42" font-size="12">7-day rolling</text>',
            '<line x1="1000" y1="38" x2="1028" y2="38" stroke="#7b61a8" stroke-width="3"/><text x="1035" y="42" font-size="12">28-day rolling</text>',
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
    decoded_revisions = [decode_row(r) for r in revisions]
    return dict(composition=decode_row(dict(raw)), decisions=decoded_decisions,
                commits=commits, configurations=decoded_revisions,
                identity_coverage=revision_identity_coverage(revisions),
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
    for command in ('trend', 'summary', 'ranking-issues', 'inspect', 'timing'):
        sub = commands.add_parser(command)
        if command == 'inspect':
            sub.add_argument('composition_id', help='Composition ID returned by ranking-issues')
        if command == 'ranking-issues':
            sub.add_argument('--min-count', type=positive, default=3)
            sub.add_argument('--limit', type=positive, default=50)
        if command == 'trend':
            sub.add_argument('--days', type=positive, default=28,
                             help='Local calendar days ending before --until; default 28')
            sub.add_argument('--chart', type=Path, help='Write a self-contained SVG trend chart')
        sub.add_argument('--db', type=Path, default=DEFAULT_DB, help=f'Default: {DEFAULT_DB}')
        sub.add_argument('--since', type=timestamp, help='Inclusive composition start: local YYYY-MM-DD or ISO time with offset')
        sub.add_argument('--until', type=timestamp, help='Exclusive composition start boundary; same syntax as --since')
        sub.add_argument('--app', help='Exact app bundle ID')
        sub.add_argument('--config', help='Exact legacy full fingerprint (not revision UUID or prefix)')
        sub.add_argument('--ranking-config', help='Exact ranking fingerprint (not revision UUID or prefix)')
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
            result = {'trend': trend, 'summary': summary, 'ranking-issues': ranking_issues,
                      'inspect': inspect, 'timing': timing}[args.command](db, args)
        if args.command == 'trend' and args.chart is not None:
            result['chart_path'] = str(write_trend_svg(result, args.chart))
        result = dict(command=args.command, filters={k: str(v) if isinstance(v, Path) else v
                      for k, v in vars(args).items()
                      if k in ('db','since','until','app','config','ranking_config','kind','days')}, **result)
        render(result, args.format)
        return 0
    except SystemExit as error:
        return error.code
    except (QueryError, sqlite3.Error, ValueError, OSError) as error:
        print(f'quality: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
