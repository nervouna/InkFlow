package io.damao.inkflow.ime

import io.damao.inkflow.engine.DirectInput
import io.damao.inkflow.engine.EngineUpdate

internal sealed interface EditorCommand {
    data class CommitText(val value: String) : EditorCommand

    data class SetComposingText(
        val value: String,
        val cursorUtf16Offset: Int,
        val selectionStartUtf16Offset: Int,
        val selectionEndUtf16Offset: Int,
    ) : EditorCommand

    data object ClearComposingText : EditorCommand

    /** Lets the host editor apply its standard selection-aware DEL behavior. */
    data object SendDeleteKeyEvents : EditorCommand

    /** Applies the Enter route captured for the current editor generation. */
    data object PerformEditorEnter : EditorCommand
}

/** Pure planning layer for all host-editor mutations. */
internal object EditorMutationPlanner {
    fun forUpdate(
        update: EngineUpdate,
        fallback: DirectInput?,
        ownsComposingText: Boolean,
    ): List<EditorCommand> = buildList {
        val nonEmptyCommit = update.commitText?.takeIf(String::isNotEmpty)
        nonEmptyCommit?.let { add(EditorCommand.CommitText(it)) }

        if (update.preedit.isNotEmpty()) {
            add(
                EditorCommand.SetComposingText(
                    value = update.preedit,
                    cursorUtf16Offset = update.cursorUtf16Offset,
                    selectionStartUtf16Offset = update.selectionStartUtf16Offset,
                    selectionEndUtf16Offset = update.selectionEndUtf16Offset,
                ),
            )
        } else if (nonEmptyCommit == null && ownsComposingText) {
            add(EditorCommand.ClearComposingText)
        }

        if (!update.handled && fallback != null) {
            addAll(forDirectInput(fallback))
        }
    }

    fun forDirectInput(input: DirectInput): List<EditorCommand> = when (input) {
        is DirectInput.Text -> listOf(EditorCommand.CommitText(input.value))
        DirectInput.DeleteBackward -> listOf(EditorCommand.SendDeleteKeyEvents)
        DirectInput.Enter -> listOf(EditorCommand.PerformEditorEnter)
    }

    fun forFailure(
        fallback: DirectInput?,
        ownsComposingText: Boolean,
    ): List<EditorCommand> = buildList {
        if (ownsComposingText) add(EditorCommand.ClearComposingText)
        if (fallback != null) addAll(forDirectInput(fallback))
    }
}
