package io.damao.inkflow.engine

internal data class EngineCandidate(
    val text: String,
    val comment: String?,
)

internal data class CandidateToken(
    val generation: Long,
    val revision: Long,
)

internal data class EngineUpdate(
    val handled: Boolean,
    val commitText: String?,
    val preedit: String,
    val cursorUtf16Offset: Int,
    val selectionStartUtf16Offset: Int,
    val selectionEndUtf16Offset: Int,
    val candidates: List<EngineCandidate>,
    val highlightedCandidateIndex: Int?,
    val hasPreviousPage: Boolean,
    val hasNextPage: Boolean,
) {
    companion object {
        fun empty(handled: Boolean = false) = EngineUpdate(
            handled = handled,
            commitText = null,
            preedit = "",
            cursorUtf16Offset = 0,
            selectionStartUtf16Offset = 0,
            selectionEndUtf16Offset = 0,
            candidates = emptyList(),
            highlightedCandidateIndex = null,
            hasPreviousPage = false,
            hasNextPage = false,
        )
    }
}

/** Immutable JNI transfer object. Byte offsets are converted before UI use. */
internal data class NativeEngineUpdate(
    val handled: Boolean,
    val commitText: String?,
    val preedit: String,
    val cursorByteOffset: Long,
    val selectionStartByteOffset: Long,
    val selectionEndByteOffset: Long,
    val candidates: List<EngineCandidate>,
    val highlightedCandidateIndex: Long,
    val hasPreviousPage: Boolean,
    val hasNextPage: Boolean,
) {
    fun toEngineUpdate(): EngineUpdate {
        val cursor = UTF8IndexConverter.utf16Offset(preedit, cursorByteOffset)
        val selectionStart = UTF8IndexConverter.utf16Offset(preedit, selectionStartByteOffset)
        val selectionEnd = UTF8IndexConverter.utf16Offset(preedit, selectionEndByteOffset)
        require(selectionStart <= selectionEnd) { "Invalid preedit selection range" }

        val stableCandidates = candidates.toList()
        val highlighted = when (highlightedCandidateIndex) {
            -1L -> null
            else -> {
                require(highlightedCandidateIndex in 0..Int.MAX_VALUE.toLong()) {
                    "Candidate index is outside Kotlin range"
                }
                highlightedCandidateIndex.toInt().also { index ->
                    require(index in stableCandidates.indices) {
                        "Highlighted candidate is outside the current page"
                    }
                }
            }
        }

        return EngineUpdate(
            handled = handled,
            commitText = commitText,
            preedit = preedit,
            cursorUtf16Offset = cursor,
            selectionStartUtf16Offset = selectionStart,
            selectionEndUtf16Offset = selectionEnd,
            candidates = stableCandidates,
            highlightedCandidateIndex = highlighted,
            hasPreviousPage = hasPreviousPage,
            hasNextPage = hasNextPage,
        )
    }
}

internal data class EngineKeyEvent(
    val keyCode: Int,
    val modifiers: Int = EngineModifiers.NONE,
)

internal object EngineKeys {
    const val BACKSPACE = 0x00110000
    const val RETURN = 0x00110002
}

internal object EngineModifiers {
    const val NONE = 0
}

internal sealed interface DirectInput {
    data class Text(val value: String) : DirectInput

    data object DeleteBackward : DirectInput

    data object Enter : DirectInput
}
