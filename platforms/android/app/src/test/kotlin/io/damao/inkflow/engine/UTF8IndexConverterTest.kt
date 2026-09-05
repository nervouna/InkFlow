package io.damao.inkflow.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class UTF8IndexConverterTest {
    @Test
    fun convertsUtf8ScalarBoundariesToUtf16Offsets() {
        val text = "你😀好"

        assertEquals(0, UTF8IndexConverter.utf16Offset(text, 0))
        assertEquals(1, UTF8IndexConverter.utf16Offset(text, 3))
        assertEquals(3, UTF8IndexConverter.utf16Offset(text, 7))
        assertEquals(4, UTF8IndexConverter.utf16Offset(text, 10))
    }

    @Test
    fun rejectsOffsetsInsideUtf8ScalarsAndUnpairedSurrogates() {
        assertThrows(IllegalArgumentException::class.java) {
            UTF8IndexConverter.utf16Offset("你😀好", 4)
        }
        assertThrows(IllegalArgumentException::class.java) {
            UTF8IndexConverter.utf16Offset(String(charArrayOf('\uD800')), 0)
        }
    }

    @Test
    fun nativeUpdateConvertsAllPreeditRanges() {
        val update = NativeEngineUpdate(
            handled = true,
            commitText = null,
            preedit = "你😀好",
            cursorByteOffset = 7,
            selectionStartByteOffset = 3,
            selectionEndByteOffset = 7,
            candidates = emptyList(),
            highlightedCandidateIndex = -1,
            hasPreviousPage = false,
            hasNextPage = false,
        ).toEngineUpdate()

        assertEquals(3, update.cursorUtf16Offset)
        assertEquals(1, update.selectionStartUtf16Offset)
        assertEquals(3, update.selectionEndUtf16Offset)
    }
}
