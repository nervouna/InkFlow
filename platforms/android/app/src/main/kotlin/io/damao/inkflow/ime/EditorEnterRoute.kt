package io.damao.inkflow.ime

import android.view.inputmethod.EditorInfo

/** Resolves Enter behavior from immutable metadata captured for one editor. */
internal sealed interface EditorEnterRoute {
    data class PerformAction(val actionId: Int) : EditorEnterRoute

    data object SendEnterKeyEvents : EditorEnterRoute

    companion object {
        fun resolve(
            hasCustomAction: Boolean,
            customActionId: Int,
            imeOptions: Int,
        ): EditorEnterRoute {
            if (imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0) {
                return SendEnterKeyEvents
            }
            if (hasCustomAction) return PerformAction(customActionId)

            return when (val action = imeOptions and EditorInfo.IME_MASK_ACTION) {
                EditorInfo.IME_ACTION_NONE -> SendEnterKeyEvents

                else -> PerformAction(action)
            }
        }
    }
}

internal object EditorEnterDispatcher {
    fun dispatch(
        route: EditorEnterRoute,
        performEditorAction: (Int) -> Boolean,
        sendEnterKeyEvents: () -> Boolean,
    ): Boolean = when (route) {
        is EditorEnterRoute.PerformAction -> performEditorAction(route.actionId)
        EditorEnterRoute.SendEnterKeyEvents -> sendEnterKeyEvents()
    }
}
