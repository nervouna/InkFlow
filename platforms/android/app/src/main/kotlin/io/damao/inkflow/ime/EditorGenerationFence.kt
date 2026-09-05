package io.damao.inkflow.ime

/** Applies state derived from an editor call only while that editor is still current. */
internal inline fun mutateIfEditorGenerationCurrent(
    expectedGeneration: Long,
    currentGeneration: () -> Long?,
    mutation: () -> Unit,
): Boolean {
    if (currentGeneration() != expectedGeneration) return false
    mutation()
    return true
}
