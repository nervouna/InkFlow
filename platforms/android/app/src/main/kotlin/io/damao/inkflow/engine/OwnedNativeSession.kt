package io.damao.inkflow.engine

/** Injectable facade keeps owner-token behavior covered by host JVM tests. */
internal interface NativeSessionBridge {
    fun openSession(): Long

    fun closeSession(ownerToken: Long): Boolean

    fun processKey(ownerToken: Long, event: EngineKeyEvent): EngineUpdate

    fun commit(ownerToken: Long): EngineUpdate

    fun selectCandidate(ownerToken: Long, index: Int): EngineUpdate

    fun changePage(ownerToken: Long, backward: Boolean): EngineUpdate

    fun reset(ownerToken: Long): EngineUpdate
}

internal object JniNativeSessionBridge : NativeSessionBridge {
    override fun openSession(): Long = NativeBridge.openSession()

    override fun closeSession(ownerToken: Long): Boolean =
        NativeBridge.closeSession(ownerToken)

    override fun processKey(ownerToken: Long, event: EngineKeyEvent): EngineUpdate =
        NativeBridge.processKey(ownerToken, event.keyCode, event.modifiers).toEngineUpdate()

    override fun commit(ownerToken: Long): EngineUpdate =
        NativeBridge.commit(ownerToken).toEngineUpdate()

    override fun selectCandidate(ownerToken: Long, index: Int): EngineUpdate =
        NativeBridge.selectCandidate(ownerToken, index).toEngineUpdate()

    override fun changePage(ownerToken: Long, backward: Boolean): EngineUpdate =
        NativeBridge.changePage(ownerToken, backward).toEngineUpdate()

    override fun reset(ownerToken: Long): EngineUpdate =
        NativeBridge.reset(ownerToken).toEngineUpdate()
}

/** Each engine instance owns only the token returned by its own open call. */
internal class OwnedNativeSession(
    private val bridge: NativeSessionBridge,
) : EngineBackend {
    private var ownerToken: Long? = null

    override fun openSession() {
        ownerToken = null
        ownerToken = bridge.openSession().also { token ->
            check(token > 0) { "Native session returned an invalid owner token" }
        }
    }

    override fun closeSession(): Boolean {
        val token = ownerToken ?: return false
        ownerToken = null
        return bridge.closeSession(token)
    }

    override fun processKey(event: EngineKeyEvent): EngineUpdate =
        bridge.processKey(requireOwnerToken(), event)

    override fun commit(): EngineUpdate = bridge.commit(requireOwnerToken())

    override fun selectCandidate(index: Int): EngineUpdate =
        bridge.selectCandidate(requireOwnerToken(), index)

    override fun changePage(backward: Boolean): EngineUpdate =
        bridge.changePage(requireOwnerToken(), backward)

    override fun reset(): EngineUpdate = bridge.reset(requireOwnerToken())

    private fun requireOwnerToken(): Long =
        checkNotNull(ownerToken) { "InkFlow session is not open" }
}
