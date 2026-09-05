package io.damao.inkflow.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class OwnedNativeSessionTest {
    @Test
    fun staleOwnerCloseCannotCloseTheNewOwnersSession() {
        val bridge = TokenCheckingBridge()
        val ownerA = OwnedNativeSession(bridge)
        val ownerB = OwnedNativeSession(bridge)

        ownerA.openSession()
        ownerB.openSession()
        ownerA.closeSession()
        val update = ownerB.processKey(EngineKeyEvent('b'.code))

        assertEquals("b", update.preedit)
        assertEquals(listOf("open:1", "open:2", "close:1", "process:2:b"), bridge.calls)
    }

    @Test
    fun staleOperationRecoveryCannotReopenOverTheCurrentOwner() {
        val bridge = TokenCheckingBridge()
        val ownerA = OwnedNativeSession(bridge)
        val ownerB = OwnedNativeSession(bridge)
        ownerA.openSession()
        ownerB.openSession()

        assertThrows(IllegalStateException::class.java) {
            ownerA.processKey(EngineKeyEvent('a'.code))
        }
        assertFalse(ownerA.closeSession())

        assertEquals("b", ownerB.processKey(EngineKeyEvent('b'.code)).preedit)
        assertEquals(
            listOf("open:1", "open:2", "close:1", "process:2:b"),
            bridge.calls,
        )
    }

    private class TokenCheckingBridge : NativeSessionBridge {
        val calls = mutableListOf<String>()
        private var nextOwner = 0L
        private var currentOwner = 0L

        override fun openSession(): Long {
            currentOwner = ++nextOwner
            calls += "open:$currentOwner"
            return currentOwner
        }

        override fun closeSession(ownerToken: Long): Boolean {
            val owned = ownerToken == currentOwner
            calls += "close:$ownerToken"
            if (owned) currentOwner = 0
            return owned
        }

        override fun processKey(
            ownerToken: Long,
            event: EngineKeyEvent,
        ): EngineUpdate {
            check(ownerToken == currentOwner) { "stale owner" }
            val text = event.keyCode.toChar().toString()
            calls += "process:$ownerToken:$text"
            return EngineUpdate.empty(handled = true).copy(
                preedit = text,
                cursorUtf16Offset = text.length,
                selectionStartUtf16Offset = text.length,
                selectionEndUtf16Offset = text.length,
            )
        }

        override fun commit(ownerToken: Long): EngineUpdate = requireOwner(ownerToken)

        override fun selectCandidate(ownerToken: Long, index: Int): EngineUpdate =
            requireOwner(ownerToken)

        override fun changePage(ownerToken: Long, backward: Boolean): EngineUpdate =
            requireOwner(ownerToken)

        override fun reset(ownerToken: Long): EngineUpdate = requireOwner(ownerToken)

        private fun requireOwner(ownerToken: Long): EngineUpdate {
            check(ownerToken == currentOwner) { "stale owner" }
            return EngineUpdate.empty(handled = true)
        }
    }
}
