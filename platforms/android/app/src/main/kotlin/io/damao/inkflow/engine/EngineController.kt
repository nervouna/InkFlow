package io.damao.inkflow.engine

import java.util.concurrent.Executor

/**
 * Owns the editor-generation barrier. Public methods are called from the IME
 * main thread; every backend operation is submitted to the same serial worker.
 */
internal class EngineController(
    private val backend: EngineBackend,
    private val worker: Executor,
    private val main: Executor,
    private val listener: Listener,
) {
    interface Listener {
        fun onEngineUpdate(
            token: CandidateToken,
            fallback: DirectInput?,
            update: EngineUpdate,
        )

        fun onDirectInput(generation: Long, input: DirectInput)

        fun onEngineFailure(generation: Long, fallback: DirectInput?)
    }

    private data class State(
        val generation: Long,
        val active: Boolean,
        val sensitive: Boolean,
        val engineReady: Boolean,
        val revision: Long,
    )

    private val stateLock = Any()
    private var state = State(
        generation = 0,
        active = false,
        sensitive = false,
        engineReady = false,
        revision = 0,
    )

    fun startEditor(sensitive: Boolean): Long {
        val (previous, generation) = synchronized(stateLock) {
            val previous = state
            val next = state.generation + 1
            state = State(
                generation = next,
                active = true,
                sensitive = sensitive,
                engineReady = false,
                revision = 0,
            )
            previous to next
        }

        worker.execute {
            if (previous.active && !previous.sensitive) {
                try {
                    backend.closeSession()
                } catch (_: Exception) {
                    if (!sensitive) {
                        deliverFailure(generation, fallback = null)
                        return@execute
                    }
                }
            }

            if (!sensitive && isCurrentEditor(generation)) {
                try {
                    backend.openSession()
                    markEngineReady(generation)
                } catch (_: Exception) {
                    deliverFailure(generation, fallback = null)
                }
            }
        }
        return generation
    }

    fun processKey(event: EngineKeyEvent, fallback: DirectInput) {
        val current = snapshotState()
        if (!current.active) return
        if (current.sensitive) {
            listener.onDirectInput(current.generation, fallback)
            return
        }
        val token = reserveOperation(current.generation) ?: return
        submit(token, fallback) { backend.processKey(event) }
    }

    fun commit() {
        val current = snapshotState()
        if (!current.active || current.sensitive) return
        val token = reserveOperation(current.generation) ?: return
        submit(token, fallback = null) { backend.commit() }
    }

    fun selectCandidate(index: Int, expectedToken: CandidateToken) {
        require(index >= 0) { "Candidate index must be nonnegative" }
        val token = reserveExpectedOperation(expectedToken) ?: return
        submit(token, fallback = null) { backend.selectCandidate(index) }
    }

    fun changePage(backward: Boolean, expectedToken: CandidateToken) {
        val token = reserveExpectedOperation(expectedToken) ?: return
        submit(token, fallback = null) { backend.changePage(backward) }
    }

    fun reset() {
        val current = snapshotState()
        if (!current.active || current.sensitive) return
        val token = reserveOperation(current.generation) ?: return
        submit(token, fallback = null) { backend.reset() }
    }

    fun finishEditor() {
        val previous = synchronized(stateLock) {
            val old = state
            state = State(
                generation = old.generation + 1,
                active = false,
                sensitive = false,
                engineReady = false,
                revision = 0,
            )
            old
        }
        if (previous.active && !previous.sensitive) {
            worker.execute {
                try {
                    backend.closeSession()
                } catch (_: Exception) {
                    // The editor is already invalidated. There is no safe UI
                    // target for a teardown failure and no input is logged.
                }
            }
        }
    }

    private fun submit(
        token: CandidateToken,
        fallback: DirectInput?,
        operation: () -> EngineUpdate,
    ) {
        worker.execute {
            if (!isCurrentEditor(token.generation)) return@execute
            if (!isEngineReady(token.generation)) {
                deliverFailure(token.generation, fallback)
                return@execute
            }
            val update = try {
                operation()
            } catch (_: Exception) {
                recoverAfterOperationFailure(token.generation, fallback)
                return@execute
            }
            main.execute {
                if (isEngineReady(token.generation)) {
                    listener.onEngineUpdate(token, fallback, update)
                }
            }
        }
    }

    /**
     * A failed native operation has an unknown mutation boundary. If this
     * backend still owns the session, close and reopen on the same queue so the
     * next accepted key starts from an empty, known engine state. A stale
     * owner is never allowed to reopen over its replacement. The UI failure
     * path clears the matching host composition before applying its fallback.
     */
    private fun recoverAfterOperationFailure(generation: Long, fallback: DirectInput?) {
        if (!markEngineNotReady(generation)) return
        val closedOwnedSession = try {
            backend.closeSession()
        } catch (_: Exception) {
            false
        }
        if (closedOwnedSession && isCurrentEditor(generation)) {
            try {
                backend.openSession()
                markEngineReady(generation)
            } catch (_: Exception) {
                // Leave this generation not ready. Its key still falls back.
            }
        }
        deliverFailure(generation, fallback)
    }

    private fun deliverFailure(generation: Long, fallback: DirectInput?) {
        main.execute {
            if (isCurrentEditor(generation)) {
                listener.onEngineFailure(generation, fallback)
            }
        }
    }

    private fun snapshotState(): State = synchronized(stateLock) { state }

    fun isCandidateTokenCurrent(token: CandidateToken): Boolean = synchronized(stateLock) {
        state.active && !state.sensitive && state.engineReady &&
            state.generation == token.generation && state.revision == token.revision
    }

    private fun reserveOperation(generation: Long): CandidateToken? = synchronized(stateLock) {
        if (!state.active || state.sensitive || state.generation != generation) {
            return@synchronized null
        }
        val revision = state.revision + 1
        state = state.copy(revision = revision)
        CandidateToken(generation, revision)
    }

    private fun reserveExpectedOperation(expected: CandidateToken): CandidateToken? =
        synchronized(stateLock) {
            if (!state.active || state.sensitive ||
                state.generation != expected.generation || state.revision != expected.revision
            ) {
                return@synchronized null
            }
            val revision = state.revision + 1
            state = state.copy(revision = revision)
            CandidateToken(state.generation, revision)
        }

    private fun markEngineReady(generation: Long) {
        synchronized(stateLock) {
            if (state.active && state.generation == generation && !state.sensitive) {
                state = state.copy(engineReady = true)
            }
        }
    }

    private fun markEngineNotReady(generation: Long): Boolean = synchronized(stateLock) {
        if (!state.active || state.sensitive || state.generation != generation) {
            return@synchronized false
        }
        state = state.copy(engineReady = false)
        true
    }

    private fun isCurrentEditor(generation: Long): Boolean = synchronized(stateLock) {
        state.active && state.generation == generation && !state.sensitive
    }

    private fun isEngineReady(generation: Long): Boolean = synchronized(stateLock) {
        state.active && state.generation == generation && !state.sensitive && state.engineReady
    }
}
