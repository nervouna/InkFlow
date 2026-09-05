package io.damao.inkflow.engine

import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** One serialized engine queue for the lifetime of the IME process. */
internal object InkFlowEngineProcess {
    val executor: Executor = Executors.newSingleThreadExecutor { command ->
        Thread(command, "InkFlowEngine").apply { isDaemon = true }
    }
}
