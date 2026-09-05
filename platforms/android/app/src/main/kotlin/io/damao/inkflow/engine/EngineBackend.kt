package io.damao.inkflow.engine

internal interface EngineBackend {
    fun openSession()

    /** Returns true only when this owner actually closed the active session. */
    fun closeSession(): Boolean

    fun processKey(event: EngineKeyEvent): EngineUpdate

    fun commit(): EngineUpdate

    fun selectCandidate(index: Int): EngineUpdate

    fun changePage(backward: Boolean): EngineUpdate

    fun reset(): EngineUpdate
}
