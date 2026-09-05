package io.damao.inkflow.ime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorGenerationFenceTest {
    @Test
    fun staleConnectionFailureCannotInvalidateTheReplacementSelectionJournal() {
        val guard = replacementEditorGuard()
        var currentGeneration = 1L
        val connectionSucceeded = failingEditorCall {
            currentGeneration = 2
        }

        val applied = if (!connectionSucceeded) {
            mutateIfEditorGenerationCurrent(
                expectedGeneration = 1,
                currentGeneration = { currentGeneration },
            ) {
                guard.invalidate()
            }
        } else {
            false
        }

        assertFalse(applied)
        assertTrue(guard.accepts(replacementEditorNoOp()))
    }

    @Test
    fun staleFinishComposingFailureCannotInvalidateTheReplacementSelectionJournal() {
        val guard = replacementEditorGuard()
        val oldRecoveryGeneration = 7L
        var currentGeneration = oldRecoveryGeneration
        val finishSucceeded = failingEditorCall {
            currentGeneration = 8
        }

        val applied = if (!finishSucceeded) {
            mutateIfEditorGenerationCurrent(
                expectedGeneration = oldRecoveryGeneration,
                currentGeneration = { currentGeneration },
            ) {
                guard.invalidate()
            }
        } else {
            false
        }

        assertFalse(applied)
        assertTrue(guard.accepts(replacementEditorNoOp()))
    }

    @Test
    fun currentConnectionFailureStillInvalidatesItsOwnSelectionJournal() {
        val guard = replacementEditorGuard()

        val applied = mutateIfEditorGenerationCurrent(
            expectedGeneration = 2,
            currentGeneration = { 2 },
        ) {
            guard.invalidate()
        }

        assertTrue(applied)
        assertFalse(guard.accepts(replacementEditorNoOp()))
    }

    @Test
    fun rejectedStaleEditorActionCannotInvalidateTheReplacementJournal() {
        val guard = replacementEditorGuard()
        var currentGeneration = 1L
        val actionSucceeded = EditorEnterDispatcher.dispatch(
            route = EditorEnterRoute.PerformAction(42),
            performEditorAction = {
                currentGeneration = 2L
                false
            },
            sendEnterKeyEvents = { error("rejected actions must not fall through") },
        )

        val applied = if (!actionSucceeded) {
            mutateIfEditorGenerationCurrent(
                expectedGeneration = 1L,
                currentGeneration = { currentGeneration },
            ) {
                guard.invalidate()
            }
        } else {
            false
        }

        assertFalse(applied)
        assertTrue(guard.accepts(replacementEditorNoOp()))
    }

    private fun replacementEditorGuard() = EditorSelectionGuard().apply {
        reset(EditorSelectionState(4, 4, -1, -1))
    }

    private fun failingEditorCall(onReentrantCall: () -> Unit): Boolean {
        onReentrantCall()
        return false
    }

    private fun replacementEditorNoOp() = EditorSelection(
        oldSelectionStart = 4,
        oldSelectionEnd = 4,
        selectionStart = 4,
        selectionEnd = 4,
        candidatesStart = -1,
        candidatesEnd = -1,
    )
}
