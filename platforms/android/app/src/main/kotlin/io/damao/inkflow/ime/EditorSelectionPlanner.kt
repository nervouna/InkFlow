package io.damao.inkflow.ime

internal data class AbsoluteEditorSelection(
    val selectionStart: Int,
    val selectionEnd: Int,
)

internal data class ComposingSelectionPlan(
    val fallbackExpectation: EditorSelectionExpectation.Composing,
    val requestedExpectation: EditorSelectionExpectation.Composing,
    private val requestedStartUtf16: Int,
    private val requestedEndUtf16: Int,
) {
    val requiresAbsoluteSelection: Boolean
        get() = requestedExpectation != fallbackExpectation

    fun resolveAbsoluteSelection(compositionStartAbsolute: Int?): AbsoluteEditorSelection? {
        if (!requiresAbsoluteSelection || compositionStartAbsolute == null) return null
        val compositionStart = compositionStartAbsolute
        if (compositionStart < 0) return null
        return AbsoluteEditorSelection(
            selectionStart = compositionStart + requestedStartUtf16,
            selectionEnd = compositionStart + requestedEndUtf16,
        )
    }
}

internal object EditorSelectionPlanner {
    fun forComposing(command: EditorCommand.SetComposingText): ComposingSelectionPlan {
        val hasSelection = command.selectionStartUtf16Offset !=
            command.selectionEndUtf16Offset
        val requestedStart = if (hasSelection) {
            command.selectionStartUtf16Offset
        } else {
            command.cursorUtf16Offset
        }
        val requestedEnd = if (hasSelection) {
            command.selectionEndUtf16Offset
        } else {
            command.cursorUtf16Offset
        }
        require(requestedStart in 0..command.value.length)
        require(requestedEnd in 0..command.value.length)

        val fallback = EditorSelectionExpectation.Composing(
            compositionLengthUtf16 = command.value.length,
            relativeSelectionStartUtf16 = command.value.length,
            relativeSelectionEndUtf16 = command.value.length,
        )
        return ComposingSelectionPlan(
            fallbackExpectation = fallback,
            requestedExpectation = EditorSelectionExpectation.Composing(
                compositionLengthUtf16 = command.value.length,
                relativeSelectionStartUtf16 = requestedStart,
                relativeSelectionEndUtf16 = requestedEnd,
            ),
            requestedStartUtf16 = requestedStart,
            requestedEndUtf16 = requestedEnd,
        )
    }
}
