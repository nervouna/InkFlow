package io.damao.inkflow.engine

import java.util.ArrayDeque
import java.util.concurrent.Executor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineControllerTest {
    @Test
    fun inputFlowIsSerializedAndCommitsSelectedCandidate() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend()
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = false)
        "nihao".forEach { character ->
            controller.processKey(
                EngineKeyEvent(character.code),
                DirectInput.Text(character.toString()),
            )
        }
        worker.runAll()
        main.runAll()
        controller.selectCandidate(0, listener.tokens.last())
        worker.runAll()
        main.runAll()

        assertEquals(listOf("open", "n", "i", "h", "a", "o", "select:0"), backend.calls)
        assertEquals("你好", listener.updates.last().commitText)
        assertTrue(listener.directInputs.isEmpty())
    }

    @Test
    fun sensitiveEditorNeverTouchesNativeBackend() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend()
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = true)
        controller.processKey(EngineKeyEvent('x'.code), DirectInput.Text("x"))
        controller.finishEditor()
        worker.runAll()
        main.runAll()

        assertTrue(backend.calls.isEmpty())
        assertEquals(listOf(DirectInput.Text("x")), listener.directInputs)
    }

    @Test
    fun editorSwitchClosesOldSessionBeforeOpeningNewAndRejectsStaleKeys() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend()
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = false)
        worker.runAll()
        controller.processKey(EngineKeyEvent('a'.code), DirectInput.Text("a"))
        controller.startEditor(sensitive = false)
        worker.runAll()
        main.runAll()

        assertEquals(listOf("open", "close", "open"), backend.calls)
        assertTrue(listener.updates.isEmpty())
    }

    @Test
    fun switchToSensitiveClosesOldSessionButSensitiveKeysBypassBackend() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend()
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = false)
        worker.runAll()
        controller.startEditor(sensitive = true)
        controller.processKey(EngineKeyEvent('x'.code), DirectInput.Text("x"))
        worker.runAll()
        main.runAll()

        assertEquals(listOf("open", "close"), backend.calls)
        assertEquals(listOf(DirectInput.Text("x")), listener.directInputs)
    }

    @Test
    fun keyQueuedAfterOpenUsesFifoAndFallsBackWhenOpenFails() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend(failOpen = true)
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = false)
        controller.processKey(EngineKeyEvent('x'.code), DirectInput.Text("x"))
        worker.runAll()
        main.runAll()

        assertEquals(listOf("open"), backend.calls)
        assertEquals(listOf(null, DirectInput.Text("x")), listener.failures)
    }

    @Test
    fun candidateTokenIsRejectedAfterNewKeyWasQueued() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend()
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = false)
        worker.runAll()
        "nihao".forEach { letter ->
            controller.processKey(
                EngineKeyEvent(letter.code),
                DirectInput.Text(letter.toString()),
            )
        }
        worker.runAll()
        main.runAll()
        val staleCandidateToken = listener.tokens.last()

        controller.processKey(EngineKeyEvent('x'.code), DirectInput.Text("x"))
        controller.selectCandidate(0, staleCandidateToken)
        worker.runAll()
        main.runAll()

        assertEquals(listOf("open", "n", "i", "h", "a", "o", "x"), backend.calls)
        assertTrue(backend.calls.none { it.startsWith("select:") })
    }

    @Test
    fun finishIsABarrierForAlreadyComputedUiEffects() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend()
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = false)
        worker.runAll()
        controller.processKey(EngineKeyEvent('a'.code), DirectInput.Text("a"))
        worker.runAll()
        controller.finishEditor()
        main.runAll()
        worker.runAll()

        assertEquals(listOf("open", "a", "close"), backend.calls)
        assertTrue(listener.updates.isEmpty())
    }

    @Test
    fun operationFailureResetsAndReopensBeforeTheNextKey() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend(failProcessOnceFor = 'x')
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = false)
        worker.runAll()
        controller.processKey(EngineKeyEvent('x'.code), DirectInput.Text("x"))
        worker.runAll()
        main.runAll()
        controller.processKey(EngineKeyEvent('y'.code), DirectInput.Text("y"))
        worker.runAll()
        main.runAll()

        assertEquals(listOf("open", "x", "close", "open", "y"), backend.calls)
        assertEquals(listOf(DirectInput.Text("x")), listener.failures)
        assertEquals("y", listener.updates.single().preedit)
    }

    @Test
    fun staleOwnerFailureDoesNotReopenOverAReplacementSession() {
        val worker = ManualExecutor()
        val main = ManualExecutor()
        val backend = RecordingBackend(
            failProcessOnceFor = 'x',
            closeOwnsSession = false,
        )
        val listener = RecordingListener()
        val controller = EngineController(backend, worker, main, listener)

        controller.startEditor(sensitive = false)
        worker.runAll()
        controller.processKey(EngineKeyEvent('x'.code), DirectInput.Text("x"))
        worker.runAll()
        main.runAll()

        assertEquals(listOf("open", "x", "close"), backend.calls)
        assertEquals(listOf(DirectInput.Text("x")), listener.failures)
    }

    private class RecordingBackend(
        private val failOpen: Boolean = false,
        private val failProcessOnceFor: Char? = null,
        private val closeOwnsSession: Boolean = true,
    ) : EngineBackend {
        val calls = mutableListOf<String>()
        private val preedit = StringBuilder()
        private var processFailureDelivered = false

        override fun openSession() {
            calls += "open"
            if (failOpen) error("fixed open failure")
            preedit.clear()
        }

        override fun closeSession(): Boolean {
            calls += "close"
            preedit.clear()
            return closeOwnsSession
        }

        override fun processKey(event: EngineKeyEvent): EngineUpdate {
            val text = event.keyCode.toChar().toString()
            calls += text
            if (!processFailureDelivered && text.single() == failProcessOnceFor) {
                processFailureDelivered = true
                error("fixed process failure")
            }
            preedit.append(text)
            val candidates = if (preedit.toString() == "nihao") listOf(EngineCandidate("你好", null)) else emptyList()
            return EngineUpdate(
                handled = true,
                commitText = null,
                preedit = preedit.toString(),
                cursorUtf16Offset = preedit.length,
                selectionStartUtf16Offset = preedit.length,
                selectionEndUtf16Offset = preedit.length,
                candidates = candidates,
                highlightedCandidateIndex = candidates.indices.firstOrNull(),
                hasPreviousPage = false,
                hasNextPage = false,
            )
        }

        override fun commit(): EngineUpdate = EngineUpdate.empty(handled = true)

        override fun selectCandidate(index: Int): EngineUpdate {
            calls += "select:$index"
            preedit.clear()
            return EngineUpdate.empty(handled = true).copy(commitText = "你好")
        }

        override fun changePage(backward: Boolean): EngineUpdate = EngineUpdate.empty(handled = true)

        override fun reset(): EngineUpdate = EngineUpdate.empty(handled = true)
    }

    private class RecordingListener : EngineController.Listener {
        val updates = mutableListOf<EngineUpdate>()
        val directInputs = mutableListOf<DirectInput>()
        val failures = mutableListOf<DirectInput?>()
        val tokens = mutableListOf<CandidateToken>()

        override fun onEngineUpdate(
            token: CandidateToken,
            fallback: DirectInput?,
            update: EngineUpdate,
        ) {
            tokens += token
            updates += update
        }

        override fun onDirectInput(generation: Long, input: DirectInput) {
            directInputs += input
        }

        override fun onEngineFailure(generation: Long, fallback: DirectInput?) {
            failures += fallback
        }
    }

    private class ManualExecutor : Executor {
        private val tasks = ArrayDeque<Runnable>()

        override fun execute(command: Runnable) {
            tasks.addLast(command)
        }

        fun runAll() {
            while (tasks.isNotEmpty()) {
                tasks.removeFirst().run()
            }
        }
    }
}
