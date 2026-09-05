package io.damao.inkflow.ime

import java.util.ArrayDeque
import kotlin.math.min

internal data class EditorSelection(
    val oldSelectionStart: Int,
    val oldSelectionEnd: Int,
    val selectionStart: Int,
    val selectionEnd: Int,
    val candidatesStart: Int,
    val candidatesEnd: Int,
) {
    fun afterState() = EditorSelectionState(
        selectionStart = selectionStart,
        selectionEnd = selectionEnd,
        candidatesStart = candidatesStart,
        candidatesEnd = candidatesEnd,
    )
}

internal data class EditorSelectionState(
    val selectionStart: Int,
    val selectionEnd: Int,
    val candidatesStart: Int,
    val candidatesEnd: Int,
) {
    fun replacementStart(): Int? = when {
        candidatesStart >= 0 && candidatesEnd >= candidatesStart -> candidatesStart
        selectionStart >= 0 && selectionEnd >= 0 -> min(selectionStart, selectionEnd)
        else -> null
    }
}

internal sealed interface EditorSelectionExpectation {
    fun predictAfter(before: EditorSelectionState?): EditorSelectionState?

    fun matchesAfter(
        selection: EditorSelection,
        predictedAfter: EditorSelectionState?,
    ): Boolean

    data class Composing(
        val compositionLengthUtf16: Int,
        val relativeSelectionStartUtf16: Int,
        val relativeSelectionEndUtf16: Int,
    ) : EditorSelectionExpectation {
        init {
            require(compositionLengthUtf16 >= 0)
            require(relativeSelectionStartUtf16 in 0..compositionLengthUtf16)
            require(relativeSelectionEndUtf16 in 0..compositionLengthUtf16)
        }

        override fun predictAfter(before: EditorSelectionState?): EditorSelectionState? {
            val compositionStart = before?.replacementStart() ?: return null
            return EditorSelectionState(
                selectionStart = compositionStart + relativeSelectionStartUtf16,
                selectionEnd = compositionStart + relativeSelectionEndUtf16,
                candidatesStart = compositionStart,
                candidatesEnd = compositionStart + compositionLengthUtf16,
            )
        }

        override fun matchesAfter(
            selection: EditorSelection,
            predictedAfter: EditorSelectionState?,
        ): Boolean {
            if (predictedAfter != null) return selection.afterState() == predictedAfter

            val compositionStart = selection.candidatesStart
            return compositionStart >= 0 &&
                selection.candidatesEnd == compositionStart + compositionLengthUtf16 &&
                selection.selectionStart == compositionStart + relativeSelectionStartUtf16 &&
                selection.selectionEnd == compositionStart + relativeSelectionEndUtf16
        }
    }

    data class NonComposing(
        val replacementLengthUtf16: Int,
    ) : EditorSelectionExpectation {
        init {
            require(replacementLengthUtf16 >= 0)
        }

        override fun predictAfter(before: EditorSelectionState?): EditorSelectionState? {
            val replacementStart = before?.replacementStart() ?: return null
            val cursor = replacementStart + replacementLengthUtf16
            return EditorSelectionState(cursor, cursor, -1, -1)
        }

        override fun matchesAfter(
            selection: EditorSelection,
            predictedAfter: EditorSelectionState?,
        ): Boolean = predictedAfter != null && selection.afterState() == predictedAfter
    }

    data object FinishComposing : EditorSelectionExpectation {
        override fun predictAfter(before: EditorSelectionState?): EditorSelectionState? =
            before?.copy(candidatesStart = -1, candidatesEnd = -1)

        override fun matchesAfter(
            selection: EditorSelection,
            predictedAfter: EditorSelectionState?,
        ): Boolean = predictedAfter != null && selection.afterState() == predictedAfter
    }

    data object DeleteBackward : EditorSelectionExpectation {
        override fun predictAfter(before: EditorSelectionState?): EditorSelectionState? {
            before ?: return null
            if (before.selectionStart < 0 || before.selectionEnd < 0) return null
            if (before.selectionStart != before.selectionEnd) {
                val cursor = min(before.selectionStart, before.selectionEnd)
                return EditorSelectionState(cursor, cursor, -1, -1)
            }
            if (before.selectionStart == 0) return EditorSelectionState(0, 0, -1, -1)
            return null
        }

        override fun matchesAfter(
            selection: EditorSelection,
            predictedAfter: EditorSelectionState?,
        ): Boolean = predictedAfter != null && selection.afterState() == predictedAfter
    }
}

/**
 * Tracks the predicted old/new selection state of each InputConnection
 * mutation. Android may deliver every callback or collapse several callbacks
 * into the latest one; matching a later transition consumes only the skipped
 * prefix. No editor text needs to be read.
 */
internal class EditorSelectionGuard(
    private val maximumPending: Int = 16,
) {
    init {
        require(maximumPending > 0)
    }

    private data class PendingExpectation(
        val before: EditorSelectionState?,
        val expectation: EditorSelectionExpectation,
        val predictedAfter: EditorSelectionState?,
    )

    private val expected = ArrayDeque<PendingExpectation>()
    private var predictedState: EditorSelectionState? = null
    private var reportedState: EditorSelectionState? = null
    private var lastAccepted: EditorSelection? = null

    fun expect(expectation: EditorSelectionExpectation): Boolean {
        val before = predictedState
        val after = expectation.predictAfter(before)
        if (after == null) {
            val mayEstablishAnchor = before == null && expected.isEmpty() &&
                expectation is EditorSelectionExpectation.Composing
            if (!mayEstablishAnchor) return invalidateExpectationQueue()
        }
        val isNoOp = after != null && after == before
        if (after != null && !isNoOp &&
            (after == reportedState || expected.any { pending -> pending.predictedAfter == after })
        ) {
            return invalidateExpectationQueue()
        }
        if (expected.size >= maximumPending) return invalidateExpectationQueue()
        expected.addLast(PendingExpectation(before, expectation, after))
        predictedState = after
        return true
    }

    fun predictedCompositionStart(): Int? {
        val state = predictedState ?: return null
        return state.candidatesStart.takeIf { start ->
            start >= 0 && state.candidatesEnd >= start
        }
    }

    fun accepts(selection: EditorSelection): Boolean {
        if (expected.isEmpty() && selection.isSelectionNoOp() &&
            selection.afterState() == reportedState
        ) {
            lastAccepted = selection
            return true
        }

        var matchingIndex = -1
        if (selection.oldSelectionMatches(reportedState)) {
            expected.forEachIndexed { index, pending ->
                if (pending.expectation.matchesAfter(selection, pending.predictedAfter)) {
                    matchingIndex = index
                }
            }
        }
        if (matchingIndex < 0) return selection == lastAccepted

        repeat(matchingIndex + 1) { expected.removeFirst() }
        val actualAfter = selection.afterState()
        lastAccepted = selection
        reportedState = actualAfter
        if (expected.isEmpty()) predictedState = actualAfter
        return true
    }

    fun reset(state: EditorSelectionState? = null) {
        expected.clear()
        predictedState = state
        reportedState = state
        lastAccepted = null
    }

    fun invalidate() {
        expected.clear()
        predictedState = null
        reportedState = null
        lastAccepted = null
    }

    private fun EditorSelection.oldSelectionMatches(state: EditorSelectionState?): Boolean {
        val startUnknown = oldSelectionStart < 0
        val endUnknown = oldSelectionEnd < 0
        if (startUnknown != endUnknown) return false
        return startUnknown || state == null ||
            (oldSelectionStart == state.selectionStart && oldSelectionEnd == state.selectionEnd)
    }

    private fun EditorSelection.isSelectionNoOp(): Boolean =
        oldSelectionStart >= 0 && oldSelectionEnd >= 0 &&
            oldSelectionStart == selectionStart && oldSelectionEnd == selectionEnd

    private fun invalidateExpectationQueue(): Boolean {
        invalidate()
        return false
    }
}
