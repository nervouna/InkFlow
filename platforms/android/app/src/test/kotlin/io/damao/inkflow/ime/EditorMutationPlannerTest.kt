package io.damao.inkflow.ime

import io.damao.inkflow.engine.DirectInput
import io.damao.inkflow.engine.EngineUpdate
import org.junit.Assert.assertEquals
import org.junit.Test

class EditorMutationPlannerTest {
    @Test
    fun candidateCommitReplacesTheActiveCompositionWithoutFinishingItFirst() {
        val plan = EditorMutationPlanner.forUpdate(
            update = EngineUpdate.empty(handled = true).copy(commitText = "你好"),
            fallback = null,
            ownsComposingText = true,
        )
        val editor = FakeEditor(text = "nihao", compositionStart = 0, compositionEnd = 5)

        plan.forEach(editor::apply)

        assertEquals(listOf(EditorCommand.CommitText("你好")), plan)
        assertEquals("你好", editor.text)
    }

    @Test
    fun lastBackspaceDeletesTheActiveCompositionInsteadOfFinalizingIt() {
        val plan = EditorMutationPlanner.forUpdate(
            update = EngineUpdate.empty(handled = true),
            fallback = null,
            ownsComposingText = true,
        )
        val editor = FakeEditor(text = "n", compositionStart = 0, compositionEnd = 1)

        plan.forEach(editor::apply)

        assertEquals(listOf(EditorCommand.ClearComposingText), plan)
        assertEquals("", editor.text)
    }

    @Test
    fun directBackspaceUsesDeleteKeyEventsSoTheEditorCanDeleteASelection() {
        assertEquals(
            listOf(EditorCommand.SendDeleteKeyEvents),
            EditorMutationPlanner.forDirectInput(DirectInput.DeleteBackward),
        )
    }

    @Test
    fun sensitiveEnterPlansTheEditorsDefaultActionInsteadOfCommittingANewline() {
        assertEquals(
            listOf(EditorCommand.PerformEditorEnter),
            EditorMutationPlanner.forDirectInput(DirectInput.Enter),
        )
    }

    @Test
    fun handledRimeReturnDoesNotAlsoRunTheEditorsDefaultAction() {
        assertEquals(
            listOf(EditorCommand.CommitText("\u4f60\u597d")),
            EditorMutationPlanner.forUpdate(
                update = EngineUpdate.empty(handled = true).copy(commitText = "\u4f60\u597d"),
                fallback = DirectInput.Enter,
                ownsComposingText = true,
            ),
        )
    }

    @Test
    fun unhandledRimeReturnRunsTheEditorsDefaultAction() {
        assertEquals(
            listOf(EditorCommand.PerformEditorEnter),
            EditorMutationPlanner.forUpdate(
                update = EngineUpdate.empty(handled = false),
                fallback = DirectInput.Enter,
                ownsComposingText = false,
            ),
        )
    }

    @Test
    fun failedRimeReturnRunsTheEditorsDefaultActionAfterClearingOwnedComposition() {
        assertEquals(
            listOf(
                EditorCommand.ClearComposingText,
                EditorCommand.PerformEditorEnter,
            ),
            EditorMutationPlanner.forFailure(
                fallback = DirectInput.Enter,
                ownsComposingText = true,
            ),
        )
    }

    @Test
    fun emptySessionUnhandledBackspaceDoesNotClearAHostSelectionFirst() {
        val plan = EditorMutationPlanner.forUpdate(
            update = EngineUpdate.empty(handled = false),
            fallback = DirectInput.DeleteBackward,
            ownsComposingText = false,
        )
        val editor = SelectionEditor(text = "abc", selectionStart = 1, selectionEnd = 2)

        plan.forEach(editor::apply)

        assertEquals(listOf(EditorCommand.SendDeleteKeyEvents), plan)
        assertEquals("ac", editor.text)
    }

    @Test
    fun engineOpenFailureWithoutAnOwnedCompositionDoesNotMutateTheEditor() {
        val plan = EditorMutationPlanner.forFailure(
            fallback = null,
            ownsComposingText = false,
        )
        val editor = SelectionEditor(text = "abc", selectionStart = 1, selectionEnd = 2)

        plan.forEach(editor::apply)

        assertEquals(emptyList<EditorCommand>(), plan)
        assertEquals("abc", editor.text)
    }

    @Test
    fun emptyEngineCommitCannotBypassCompositionOwnership() {
        val plan = EditorMutationPlanner.forUpdate(
            update = EngineUpdate.empty(handled = true).copy(commitText = ""),
            fallback = null,
            ownsComposingText = false,
        )
        val editor = SelectionEditor(text = "abc", selectionStart = 1, selectionEnd = 2)

        plan.forEach(editor::apply)

        assertEquals(emptyList<EditorCommand>(), plan)
        assertEquals("abc", editor.text)
    }

    @Test
    fun emptyEngineCommitClearsOnlyAnOwnedComposition() {
        assertEquals(
            listOf(EditorCommand.ClearComposingText),
            EditorMutationPlanner.forUpdate(
                update = EngineUpdate.empty(handled = true).copy(commitText = ""),
                fallback = null,
                ownsComposingText = true,
            ),
        )
    }

    @Test
    fun engineFailureClearsHostCompositionBeforeApplyingFallback() {
        assertEquals(
            listOf(
                EditorCommand.ClearComposingText,
                EditorCommand.CommitText("x"),
            ),
            EditorMutationPlanner.forFailure(
                fallback = DirectInput.Text("x"),
                ownsComposingText = true,
            ),
        )
    }

    private class FakeEditor(
        text: String,
        private var compositionStart: Int,
        private var compositionEnd: Int,
    ) {
        var text: String = text
            private set

        fun apply(command: EditorCommand) {
            when (command) {
                is EditorCommand.CommitText -> replaceComposition(command.value)
                is EditorCommand.SetComposingText -> replaceComposition(command.value)
                EditorCommand.ClearComposingText -> replaceComposition("")
                EditorCommand.SendDeleteKeyEvents -> Unit
                EditorCommand.PerformEditorEnter -> Unit
            }
        }

        private fun replaceComposition(replacement: String) {
            text = text.replaceRange(compositionStart, compositionEnd, replacement)
            compositionEnd = compositionStart + replacement.length
        }
    }

    private class SelectionEditor(
        text: String,
        private var selectionStart: Int,
        private var selectionEnd: Int,
    ) {
        var text: String = text
            private set

        fun apply(command: EditorCommand) {
            when (command) {
                is EditorCommand.CommitText -> replaceSelection(command.value)
                is EditorCommand.SetComposingText -> replaceSelection(command.value)
                EditorCommand.ClearComposingText -> replaceSelection("")
                EditorCommand.SendDeleteKeyEvents -> {
                    if (selectionStart != selectionEnd) {
                        replaceSelection("")
                    } else if (selectionStart > 0) {
                        val cursor = selectionStart
                        text = text.removeRange(cursor - 1, cursor)
                        selectionStart -= 1
                        selectionEnd = selectionStart
                    }
                }
                EditorCommand.PerformEditorEnter -> Unit
            }
        }

        private fun replaceSelection(replacement: String) {
            val start = minOf(selectionStart, selectionEnd)
            val end = maxOf(selectionStart, selectionEnd)
            text = text.replaceRange(start, end, replacement)
            selectionStart = start + replacement.length
            selectionEnd = selectionStart
        }
    }
}
