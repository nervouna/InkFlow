package io.damao.inkflow.engine

import android.content.Context

/** Called only by EngineController's single serial executor. */
internal class NativeRimeEngine(
    context: Context,
) : EngineBackend {
    private val applicationContext = context.applicationContext
    private val session = OwnedNativeSession(JniNativeSessionBridge)
    private var initialized = false

    override fun openSession() {
        if (!initialized) {
            val paths = SchemaAssets.install(applicationContext)
            NativeBridge.initialize(
                sharedDataDirectory = paths.shared.absolutePath,
                userDataDirectory = paths.user.absolutePath,
                prebuiltDataDirectory = paths.prebuilt.absolutePath,
                stagingDataDirectory = paths.staging.absolutePath,
            )
            initialized = true
        }
        session.openSession()
    }

    override fun closeSession(): Boolean = session.closeSession()

    override fun processKey(event: EngineKeyEvent): EngineUpdate =
        session.processKey(event)

    override fun commit(): EngineUpdate = session.commit()

    override fun selectCandidate(index: Int): EngineUpdate =
        session.selectCandidate(index)

    override fun changePage(backward: Boolean): EngineUpdate =
        session.changePage(backward)

    override fun reset(): EngineUpdate = session.reset()
}
