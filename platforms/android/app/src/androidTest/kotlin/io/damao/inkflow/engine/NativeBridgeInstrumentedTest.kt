package io.damao.inkflow.engine

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeBridgeInstrumentedTest {
    @Test
    fun realArm64EngineCommitsNihaoCandidate() {
        assertEquals(1, NativeBridge.apiVersion())
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val staleOwner = NativeRimeEngine(context)
        val currentOwner = NativeRimeEngine(context)
        staleOwner.openSession()
        currentOwner.openSession()
        try {
            // A stale service teardown must not close the session most recently
            // opened by a replacement service instance.
            staleOwner.closeSession()
            var update = EngineUpdate.empty()
            "nihao".forEach { letter ->
                update = currentOwner.processKey(EngineKeyEvent(letter.code))
            }
            assertTrue(update.candidates.any { it.text == "你好" })

            val index = update.candidates.indexOfFirst { it.text == "你好" }
            val committed = currentOwner.selectCandidate(index)
            assertEquals("你好", committed.commitText)
            assertTrue(committed.preedit.isEmpty())
        } finally {
            staleOwner.closeSession()
            currentOwner.closeSession()
        }
    }
}
