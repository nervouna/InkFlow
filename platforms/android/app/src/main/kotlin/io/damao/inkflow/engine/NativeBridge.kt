package io.damao.inkflow.engine

/** JNI entry points are registered explicitly from JNI_OnLoad. */
internal object NativeBridge {
    init {
        System.loadLibrary("inkflow_android")
    }

    @JvmStatic
    external fun apiVersion(): Int

    @JvmStatic
    external fun initialize(
        sharedDataDirectory: String,
        userDataDirectory: String,
        prebuiltDataDirectory: String,
        stagingDataDirectory: String,
    )

    @JvmStatic
    external fun openSession(): Long

    @JvmStatic
    external fun closeSession(ownerToken: Long): Boolean

    @JvmStatic
    external fun processKey(
        ownerToken: Long,
        keyCode: Int,
        modifiers: Int,
    ): NativeEngineUpdate

    @JvmStatic
    external fun commit(ownerToken: Long): NativeEngineUpdate

    @JvmStatic
    external fun selectCandidate(ownerToken: Long, index: Int): NativeEngineUpdate

    @JvmStatic
    external fun changePage(ownerToken: Long, backward: Boolean): NativeEngineUpdate

    @JvmStatic
    external fun reset(ownerToken: Long): NativeEngineUpdate
}
