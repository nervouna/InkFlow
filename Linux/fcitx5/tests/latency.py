"""Measure client-observed Fcitx D-Bus performance in the private installed-addon harness."""
import asyncio
import json
import math
import platform
from time import perf_counter_ns


def percentiles(samples):
    ordered = sorted(samples)
    return {
        f"p{n}_ms": round(ordered[math.ceil(len(ordered) * n / 100) - 1] / 1_000_000, 3)
        for n in (50, 95, 99)
    }


async def measure_latency(context, controller, capabilities, include_samples):
    signals = 0
    first_candidate = asyncio.get_running_loop().create_future()

    def panel(preedit, cursor, upper, lower, candidates, index, layout, previous, following):
        nonlocal signals
        signals += 1
        if candidates and not first_candidate.done():
            first_candidate.set_result(perf_counter_ns())

    context.on_update_client_side_ui(panel)
    assert await controller.call_current_input_method() == "keyboard-us"
    start = perf_counter_ns()
    await controller.call_set_current_im("inkflow-pinyin")
    await controller.call_activate()
    assert await context.call_process_key_event(ord("n"), 0, 0, False, 0)
    received = await asyncio.wait_for(first_candidate, 5)
    await context.call_process_key_event(ord("n"), 0, 0, True, 0)
    assert await controller.call_current_input_method() == "inkflow-pinyin"
    result = {
        "architecture": platform.machine(),
        "first_activation_to_first_candidate_signal_ms": round((received - start) / 1_000_000, 3),
        "words": {},
    }

    async def measure_spelling(word, preceding_text=""):
        durations = [[], []]
        panel_counts = [0, 0]
        for trial in range(13):
            await context.call_reset()
            if preceding_text:
                cursor = len(preceding_text)
                await context.call_set_surrounding_text(preceding_text, cursor, cursor)
            for letter in word:
                for release in (False, True):
                    before = signals
                    start = perf_counter_ns()
                    handled = await context.call_process_key_event(ord(letter), 0, 0, release, 0)
                    elapsed = perf_counter_ns() - start
                    assert release or handled
                    # A same-daemon round trip lets earlier panel messages arrive outside the timed interval.
                    await controller.call_current_input_method()
                    if trial:
                        durations[release].append(elapsed)
                        panel_counts[release] += signals - before
        measurements = {
            label: {"events": len(samples), "panel_signals": count, **percentiles(samples)}
            for label, samples, count in zip(("press", "release"), durations, panel_counts)
        }
        if include_samples:
            for label, samples in zip(("press", "release"), durations):
                measurements[label]["samples_ns"] = samples
        return measurements

    long_word = "niyebuxiangnidepengyoushangxin"
    for word in ("nihao", "jintiantianqihenhao", long_word):
        result["words"][word] = await measure_spelling(word)

    preceding_text = "今天"
    await context.call_set_capability(capabilities | (1 << 6))  # Fcitx5 SurroundingText
    contextual = await measure_spelling(long_word, preceding_text)
    result["long_with_context"] = {"word": long_word, "preceding_text": preceding_text, **contextual}
    await context.call_reset()
    await context.call_set_surrounding_text("", 0, 0)
    await context.call_set_capability(capabilities)

    commits = []
    context.on_commit_string(commits.append)
    commit_times = []
    for trial in range(121):
        for letter in "nihao":
            assert await context.call_process_key_event(ord(letter), 0, 0, False, 0)
            await context.call_process_key_event(ord(letter), 0, 0, True, 0)
        start = perf_counter_ns()
        assert await context.call_process_key_event(32, 0, 0, False, 0)
        elapsed = perf_counter_ns() - start
        if trial:
            commit_times.append(elapsed)
        await context.call_process_key_event(32, 0, 0, True, 0)
    await controller.call_current_input_method()
    assert commits == ["你好"] * 121
    result["space_commit"] = {"events": len(commit_times), **percentiles(commit_times)}
    if include_samples:
        result["space_commit"]["samples_ns"] = commit_times
    print(json.dumps(result, indent=2))
