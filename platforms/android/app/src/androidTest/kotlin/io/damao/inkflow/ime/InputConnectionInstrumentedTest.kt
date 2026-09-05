package io.damao.inkflow.ime

import android.text.Editable
import android.text.Selection
import android.text.SpannableStringBuilder
import android.view.View
import android.view.inputmethod.BaseInputConnection
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class InputConnectionInstrumentedTest {
    @Test
    fun commitTextReplacesActiveCompositionExactlyOnce() {
        val connection = editableConnection()
        connection.setComposingText("nihao", 1)

        connection.commitText("你好", 1)

        assertEquals("你好", connection.buffer.toString())
        assertEquals(-1, BaseInputConnection.getComposingSpanStart(connection.buffer))
        assertEquals(-1, BaseInputConnection.getComposingSpanEnd(connection.buffer))
    }

    @Test
    fun emptyComposingTextDeletesTheLastPreeditCharacter() {
        val connection = editableConnection()
        connection.setComposingText("n", 1)

        connection.commitText("", 1)

        assertEquals("", connection.buffer.toString())
        assertEquals(-1, BaseInputConnection.getComposingSpanStart(connection.buffer))
        assertEquals(-1, BaseInputConnection.getComposingSpanEnd(connection.buffer))
    }

    private fun editableConnection(): EditableConnection {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        return EditableConnection(View(context)).also { connection ->
            Selection.setSelection(connection.buffer, 0)
        }
    }

    private class EditableConnection(target: View) : BaseInputConnection(target, true) {
        val buffer = SpannableStringBuilder()

        override fun getEditable(): Editable = buffer
    }
}
