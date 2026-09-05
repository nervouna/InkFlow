package io.damao.inkflow.ime

import android.view.inputmethod.EditorInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EditorEnterRouteTest {
    @Test
    fun customActionUsesItsExplicitId() {
        assertEquals(
            EditorEnterRoute.PerformAction(42),
            EditorEnterRoute.resolve(
                hasCustomAction = true,
                customActionId = 42,
                imeOptions = EditorInfo.IME_ACTION_SEARCH,
            ),
        )
    }

    @Test
    fun standardActionUsesTheMaskedImeOption() {
        assertEquals(
            EditorEnterRoute.PerformAction(EditorInfo.IME_ACTION_NEXT),
            EditorEnterRoute.resolve(
                hasCustomAction = false,
                customActionId = 0,
                imeOptions = EditorInfo.IME_ACTION_NEXT,
            ),
        )
    }

    @Test
    fun noEnterActionFlagAlwaysUsesRawEnter() {
        assertEquals(
            EditorEnterRoute.SendEnterKeyEvents,
            EditorEnterRoute.resolve(
                hasCustomAction = true,
                customActionId = 42,
                imeOptions = EditorInfo.IME_ACTION_DONE or
                    EditorInfo.IME_FLAG_NO_ENTER_ACTION,
            ),
        )
    }

    @Test
    fun noneActionUsesRawEnter() {
        assertEquals(
            EditorEnterRoute.SendEnterKeyEvents,
            EditorEnterRoute.resolve(
                hasCustomAction = false,
                customActionId = 0,
                imeOptions = EditorInfo.IME_ACTION_NONE,
            ),
        )
    }

    @Test
    fun unspecifiedActionIsDispatchedToTheEditor() {
        assertEquals(
            EditorEnterRoute.PerformAction(EditorInfo.IME_ACTION_UNSPECIFIED),
            EditorEnterRoute.resolve(
                hasCustomAction = false,
                customActionId = 0,
                imeOptions = EditorInfo.IME_ACTION_UNSPECIFIED,
            ),
        )
    }

    @Test
    fun rejectedActionDoesNotFallThroughToRawEnter() {
        var performedAction: Int? = null
        var sentEnter = false

        val succeeded = EditorEnterDispatcher.dispatch(
            route = EditorEnterRoute.PerformAction(42),
            performEditorAction = { actionId ->
                performedAction = actionId
                false
            },
            sendEnterKeyEvents = {
                sentEnter = true
                true
            },
        )

        assertFalse(succeeded)
        assertEquals(42, performedAction)
        assertFalse(sentEnter)
    }

    @Test
    fun rawEnterReportsTheCapturedConnectionsResult() {
        var sentEnter = false

        val succeeded = EditorEnterDispatcher.dispatch(
            route = EditorEnterRoute.SendEnterKeyEvents,
            performEditorAction = { error("unexpected action") },
            sendEnterKeyEvents = {
                sentEnter = true
                true
            },
        )

        assertTrue(succeeded)
        assertTrue(sentEnter)
    }
}
