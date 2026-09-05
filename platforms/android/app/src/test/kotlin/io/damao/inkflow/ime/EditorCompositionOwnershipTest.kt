package io.damao.inkflow.ime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorCompositionOwnershipTest {
    @Test
    fun successfulSetGrantsExactlyOneClearToTheCurrentEditor() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = false)

        val attempt = ownership.beginSetComposingText(editorGeneration = 1)
        ownership.completeSetComposingText(attempt, succeeded = true)

        assertTrue(ownership.ownsComposition(editorGeneration = 1))
        assertTrue(ownership.consumeForClear(editorGeneration = 1))
        assertFalse(ownership.consumeForClear(editorGeneration = 1))
    }

    @Test
    fun failedSetNeverGrantsPermissionToClearHostText() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = false)

        val attempt = ownership.beginSetComposingText(editorGeneration = 1)
        ownership.completeSetComposingText(attempt, succeeded = false)

        assertFalse(ownership.ownsComposition(editorGeneration = 1))
        assertFalse(ownership.consumeForClear(editorGeneration = 1))
    }

    @Test
    fun failedComposingReplacementRevokesThePreviousClearPermission() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = false)
        ownership.completeSetComposingText(
            ownership.beginSetComposingText(editorGeneration = 1),
            succeeded = true,
        )

        ownership.completeSetComposingText(
            ownership.beginSetComposingText(editorGeneration = 1),
            succeeded = false,
        )

        assertFalse(ownership.consumeForClear(editorGeneration = 1))
    }

    @Test
    fun reentrantExternalRecoveryRevokesAnInFlightSetGrant() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = false)
        val attempt = ownership.beginSetComposingText(editorGeneration = 1)

        ownership.invalidate(editorGeneration = 1)
        ownership.completeSetComposingText(attempt, succeeded = true)

        assertFalse(ownership.consumeForClear(editorGeneration = 1))
    }

    @Test
    fun externalSelectionRecoveryRevokesAnOwnedComposition() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = false)
        ownership.completeSetComposingText(
            ownership.beginSetComposingText(editorGeneration = 1),
            succeeded = true,
        )

        ownership.invalidate(editorGeneration = 1)

        assertFalse(ownership.consumeForClear(editorGeneration = 1))
    }

    @Test
    fun editorSwitchRejectsALateSuccessfulSetFromThePreviousEditor() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = false)
        val staleAttempt = ownership.beginSetComposingText(editorGeneration = 1)

        ownership.startEditor(editorGeneration = 2, sensitive = false)
        ownership.completeSetComposingText(staleAttempt, succeeded = true)

        assertFalse(ownership.consumeForClear(editorGeneration = 1))
        assertFalse(ownership.consumeForClear(editorGeneration = 2))
    }

    @Test
    fun commitConsumesTheOldCompositionAndANewSuccessfulSetOwnsOnlyTheNewOne() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = false)
        ownership.completeSetComposingText(
            ownership.beginSetComposingText(editorGeneration = 1),
            succeeded = true,
        )

        ownership.consumeForCommit(editorGeneration = 1)
        assertFalse(ownership.ownsComposition(editorGeneration = 1))

        ownership.completeSetComposingText(
            ownership.beginSetComposingText(editorGeneration = 1),
            succeeded = true,
        )
        assertTrue(ownership.ownsComposition(editorGeneration = 1))
    }

    @Test
    fun finishRevokesOwnershipAndAnyInFlightGrant() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = false)
        val attempt = ownership.beginSetComposingText(editorGeneration = 1)

        ownership.finishEditor()
        ownership.completeSetComposingText(attempt, succeeded = true)

        assertFalse(ownership.consumeForClear(editorGeneration = 1))
    }

    @Test
    fun sensitiveEditorCanNeverAcquireCompositionOwnership() {
        val ownership = EditorCompositionOwnership()
        ownership.startEditor(editorGeneration = 1, sensitive = true)

        assertNull(ownership.beginSetComposingText(editorGeneration = 1))
        assertFalse(ownership.consumeForClear(editorGeneration = 1))

        ownership.startEditor(editorGeneration = 2, sensitive = false)
        assertNotNull(ownership.beginSetComposingText(editorGeneration = 2))
    }
}
