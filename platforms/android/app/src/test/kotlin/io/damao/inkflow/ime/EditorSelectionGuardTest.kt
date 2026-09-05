package io.damao.inkflow.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorSelectionGuardTest {
    @Test
    fun acceptsComposingCallbackByCandidateBoundsAndRelativeUtf16Offsets() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(100, 100, -1, -1))
        guard.expect(
            EditorSelectionExpectation.Composing(
                compositionLengthUtf16 = 5,
                relativeSelectionStartUtf16 = 4,
                relativeSelectionEndUtf16 = 4,
            ),
        )
        val self = callback(old = 100, new = 104, candidatesStart = 100, candidatesEnd = 105)

        assertTrue(guard.accepts(self))
        assertFalse(
            guard.accepts(
                callback(old = 104, new = 102, candidatesStart = 100, candidatesEnd = 105),
            ),
        )
    }

    @Test
    fun selfCompositionDoesNotRequireReadingAnEditorTextSnapshot() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(42, 42, -1, -1))
        val selectionPlan = EditorSelectionPlanner.forComposing(
            EditorCommand.SetComposingText(
                value = "nihao",
                cursorUtf16Offset = 2,
                selectionStartUtf16Offset = 2,
                selectionEndUtf16Offset = 2,
            ),
        )
        guard.expect(selectionPlan.fallbackExpectation)

        assertTrue(selectionPlan.requiresAbsoluteSelection)
        assertTrue(selectionPlan.resolveAbsoluteSelection(null) == null)
        assertEquals(
            AbsoluteEditorSelection(selectionStart = 44, selectionEnd = 44),
            selectionPlan.resolveAbsoluteSelection(42),
        )
        assertTrue(
            guard.accepts(
                callback(old = 42, new = 47, candidatesStart = 42, candidatesEnd = 47),
            ),
        )
    }

    @Test
    fun collapsedCallbacksMaySkipEarlierSelfMutation() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(10, 10, -1, -1))
        guard.expect(EditorSelectionExpectation.Composing(1, 1, 1))
        guard.expect(EditorSelectionExpectation.Composing(2, 2, 2))
        val latest = callback(old = 10, new = 12, candidatesStart = 10, candidatesEnd = 12)

        assertTrue(guard.accepts(latest))
        assertTrue(guard.accepts(latest))
        assertFalse(callback(old = 12, new = 0).let(guard::accepts))
    }

    @Test
    fun resetInvalidatesOutstandingExpectations() {
        val guard = EditorSelectionGuard()
        val self = callback(old = 3, new = 3)
        guard.reset(EditorSelectionState(3, 3, -1, -1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 0))
        guard.reset()

        assertFalse(guard.accepts(self))
    }

    @Test
    fun unknownAnchorFailsClosedInsteadOfEnqueuingAWildcard() {
        val guard = EditorSelectionGuard()
        assertFalse(
            guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 0)),
        )

        assertFalse(
            guard.accepts(
                EditorSelection(
                    oldSelectionStart = -1,
                    oldSelectionEnd = -1,
                    selectionStart = 12,
                    selectionEnd = 12,
                    candidatesStart = -1,
                    candidatesEnd = -1,
                ),
            ),
        )
    }

    @Test
    fun oneUnknownComposingAnchorMayBeEstablishedByStrictRelativeBounds() {
        val guard = EditorSelectionGuard()
        assertTrue(guard.expect(EditorSelectionExpectation.Composing(5, 2, 2)))

        assertTrue(
            guard.accepts(
                EditorSelection(
                    oldSelectionStart = -1,
                    oldSelectionEnd = -1,
                    selectionStart = 44,
                    selectionEnd = 44,
                    candidatesStart = 42,
                    candidatesEnd = 47,
                ),
            ),
        )
        assertEquals(42, guard.predictedCompositionStart())
    }

    @Test
    fun unknownComposingAnchorRejectsTheWrongRelativeSelection() {
        val guard = EditorSelectionGuard()
        assertTrue(guard.expect(EditorSelectionExpectation.Composing(5, 2, 2)))

        assertFalse(
            guard.accepts(
                EditorSelection(
                    oldSelectionStart = -1,
                    oldSelectionEnd = -1,
                    selectionStart = 45,
                    selectionEnd = 45,
                    candidatesStart = 42,
                    candidatesEnd = 47,
                ),
            ),
        )
    }

    @Test
    fun unknownComposingAnchorCannotAccumulateAnotherPendingMutation() {
        val guard = EditorSelectionGuard()
        assertTrue(guard.expect(EditorSelectionExpectation.Composing(5, 5, 5)))

        assertFalse(guard.expect(EditorSelectionExpectation.Composing(6, 6, 6)))
        assertFalse(
            guard.accepts(
                EditorSelection(
                    oldSelectionStart = -1,
                    oldSelectionEnd = -1,
                    selectionStart = 48,
                    selectionEnd = 48,
                    candidatesStart = 42,
                    candidatesEnd = 48,
                ),
            ),
        )
    }

    @Test
    fun twoMutationBatchesAcceptTwoDistinctAsyncCallbacksThenRejectExternalMove() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))

        assertTrue(guard.accepts(callback(old = 0, new = 1)))
        assertTrue(guard.accepts(callback(old = 1, new = 2)))
        assertFalse(guard.accepts(callback(old = 2, new = 7)))
    }

    @Test
    fun collapsedMutationCallbackConsumesSkippedBatchThenRejectsExternalMove() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))

        assertTrue(guard.accepts(callback(old = 0, new = 2)))
        assertFalse(guard.accepts(callback(old = 2, new = 7)))
    }

    @Test
    fun futureOldSelectionCannotMasqueradeAsCollapsedCallback() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))

        assertFalse(guard.accepts(callback(old = 1, new = 2)))
    }

    @Test
    fun halfUnknownOldSelectionCannotMatchAnExactTransition() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))

        assertFalse(
            guard.accepts(
                EditorSelection(
                    oldSelectionStart = -1,
                    oldSelectionEnd = 0,
                    selectionStart = 1,
                    selectionEnd = 1,
                    candidatesStart = -1,
                    candidatesEnd = -1,
                ),
            ),
        )
    }

    @Test
    fun pendingTransitionsDoNotAcceptAnExternalMoveBackToTheBaseline() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))
        guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1))

        assertFalse(guard.accepts(callback(old = 2, new = 0)))
    }

    @Test
    fun unpredictableCollapsedDeleteInvalidatesInsteadOfCreatingAWildcard() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(2, 2, -1, -1))

        assertFalse(guard.expect(EditorSelectionExpectation.DeleteBackward))
        assertFalse(guard.accepts(callback(old = 2, new = 1)))
    }

    @Test
    fun pendingOverflowInvalidatesInsteadOfDroppingTheOldestTransition() {
        val guard = EditorSelectionGuard(maximumPending = 2)
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        assertTrue(
            guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1)),
        )
        assertTrue(
            guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1)),
        )

        assertFalse(
            guard.expect(EditorSelectionExpectation.NonComposing(replacementLengthUtf16 = 1)),
        )
        assertFalse(guard.accepts(callback(old = 0, new = 3)))
    }

    @Test
    fun repeatedPredictedStateInvalidatesAnAmbiguousCollapsedJournal() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        assertTrue(guard.expect(EditorSelectionExpectation.Composing(1, 1, 1)))
        assertTrue(guard.expect(EditorSelectionExpectation.Composing(2, 2, 2)))

        assertFalse(guard.expect(EditorSelectionExpectation.Composing(1, 1, 1)))
        assertFalse(
            guard.accepts(callback(old = 0, new = 1, candidatesStart = 0, candidatesEnd = 1)),
        )
    }

    @Test
    fun returnToReportedBaselineInvalidatesAnAmbiguousCollapsedJournal() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        assertTrue(guard.expect(EditorSelectionExpectation.Composing(1, 1, 1)))

        assertFalse(guard.expect(EditorSelectionExpectation.NonComposing(0)))
        assertFalse(guard.accepts(callback(old = 0, new = 0)))
    }

    @Test
    fun noOpThenMutationAcceptsBothSplitCallbacks() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        assertTrue(guard.expect(EditorSelectionExpectation.FinishComposing))
        assertTrue(guard.expect(EditorSelectionExpectation.NonComposing(1)))

        assertTrue(guard.accepts(callback(old = 0, new = 0)))
        assertTrue(guard.accepts(callback(old = 0, new = 1)))
        assertFalse(guard.accepts(callback(old = 1, new = 4)))
    }

    @Test
    fun noOpThenMutationAcceptsCollapsedFinalCallback() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        assertTrue(guard.expect(EditorSelectionExpectation.FinishComposing))
        assertTrue(guard.expect(EditorSelectionExpectation.NonComposing(1)))

        assertTrue(guard.accepts(callback(old = 0, new = 1)))
        assertFalse(guard.accepts(callback(old = 1, new = 4)))
    }

    @Test
    fun clearCompositionThenRawEnterAcceptsSplitCallbacks() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(5, 5, 0, 5))
        assertTrue(guard.expect(EditorSelectionExpectation.NonComposing(0)))
        assertTrue(guard.expect(EditorSelectionExpectation.NonComposing(1)))

        assertTrue(guard.accepts(callback(old = 5, new = 0)))
        assertTrue(guard.accepts(callback(old = 0, new = 1)))
        assertFalse(guard.accepts(callback(old = 1, new = 4)))
    }

    @Test
    fun clearCompositionThenRawEnterAcceptsCollapsedCallback() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(5, 5, 0, 5))
        assertTrue(guard.expect(EditorSelectionExpectation.NonComposing(0)))
        assertTrue(guard.expect(EditorSelectionExpectation.NonComposing(1)))

        assertTrue(guard.accepts(callback(old = 5, new = 1)))
        assertFalse(guard.accepts(callback(old = 1, new = 4)))
    }

    @Test
    fun repeatedNoOpsAcceptSplitDuplicateCallbacksBeforeARealMutation() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        assertTrue(guard.expect(EditorSelectionExpectation.FinishComposing))
        assertTrue(guard.expect(EditorSelectionExpectation.FinishComposing))
        assertTrue(guard.expect(EditorSelectionExpectation.NonComposing(1)))

        assertTrue(guard.accepts(callback(old = 0, new = 0)))
        assertTrue(guard.accepts(callback(old = 0, new = 0)))
        assertTrue(guard.accepts(callback(old = 0, new = 1)))
        assertFalse(guard.accepts(callback(old = 1, new = 4)))
    }

    @Test
    fun repeatedNoOpsAcceptOneCollapsedNoOpBeforeARealMutation() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(0, 0, -1, -1))
        assertTrue(guard.expect(EditorSelectionExpectation.FinishComposing))
        assertTrue(guard.expect(EditorSelectionExpectation.FinishComposing))
        assertTrue(guard.expect(EditorSelectionExpectation.NonComposing(1)))

        assertTrue(guard.accepts(callback(old = 0, new = 0)))
        assertTrue(guard.accepts(callback(old = 0, new = 1)))
        assertFalse(guard.accepts(callback(old = 1, new = 4)))
    }

    @Test
    fun baselineNoOpCallbackIsAcceptedWithoutAPendingMutation() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(4, 4, -1, -1))

        assertTrue(guard.accepts(callback(old = 4, new = 4)))
    }

    @Test
    fun invalidationDoesNotAcceptANoOpAtTheNowUnknownOldBaseline() {
        val guard = EditorSelectionGuard()
        guard.reset(EditorSelectionState(4, 4, -1, -1))
        guard.invalidate()

        assertFalse(guard.accepts(callback(old = 4, new = 4)))
    }

    private fun callback(
        old: Int,
        new: Int,
        candidatesStart: Int = -1,
        candidatesEnd: Int = -1,
    ) = EditorSelection(
        oldSelectionStart = old,
        oldSelectionEnd = old,
        selectionStart = new,
        selectionEnd = new,
        candidatesStart = candidatesStart,
        candidatesEnd = candidatesEnd,
    )
}
