package io.damao.inkflow.ime

/**
 * A fail-closed capability for replacing the host's composing span with an
 * empty string. Only a successful InkFlow setComposingText call in the current
 * non-sensitive editor grants the capability.
 */
internal class EditorCompositionOwnership {
    internal data class SetAttempt(
        val editorGeneration: Long,
        val revision: Long,
    )

    private var activeEditorGeneration: Long? = null
    private var allowsComposition = false
    private var ownsComposition = false
    private var revision = 0L

    fun startEditor(editorGeneration: Long, sensitive: Boolean) {
        revision += 1
        activeEditorGeneration = editorGeneration
        allowsComposition = !sensitive
        ownsComposition = false
    }

    fun finishEditor() {
        revision += 1
        activeEditorGeneration = null
        allowsComposition = false
        ownsComposition = false
    }

    fun ownsComposition(editorGeneration: Long): Boolean =
        allowsComposition && activeEditorGeneration == editorGeneration && ownsComposition

    fun beginSetComposingText(editorGeneration: Long): SetAttempt? {
        if (!allowsComposition || activeEditorGeneration != editorGeneration) return null
        return SetAttempt(editorGeneration, revision)
    }

    fun completeSetComposingText(attempt: SetAttempt?, succeeded: Boolean) {
        attempt ?: return
        if (activeEditorGeneration != attempt.editorGeneration || revision != attempt.revision) {
            return
        }
        revision += 1
        ownsComposition = succeeded && allowsComposition
    }

    /** A commit replaces any composing span, so revoke before calling the editor. */
    fun consumeForCommit(editorGeneration: Long) {
        if (activeEditorGeneration != editorGeneration) return
        revision += 1
        ownsComposition = false
    }

    /** Atomically consumes the one permission to issue commitText(""). */
    fun consumeForClear(editorGeneration: Long): Boolean {
        if (!ownsComposition(editorGeneration)) return false
        revision += 1
        ownsComposition = false
        return true
    }

    /** Invalidates in-flight grants as well as an already-owned composition. */
    fun invalidate(editorGeneration: Long?) {
        if (editorGeneration != null && activeEditorGeneration != editorGeneration) return
        revision += 1
        ownsComposition = false
    }
}
