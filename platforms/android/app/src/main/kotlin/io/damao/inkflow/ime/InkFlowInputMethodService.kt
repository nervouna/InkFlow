package io.damao.inkflow.ime

import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import io.damao.inkflow.R
import io.damao.inkflow.engine.CandidateToken
import io.damao.inkflow.engine.DirectInput
import io.damao.inkflow.engine.EditorPrivacyPolicy
import io.damao.inkflow.engine.EngineController
import io.damao.inkflow.engine.EngineKeyEvent
import io.damao.inkflow.engine.EngineKeys
import io.damao.inkflow.engine.EngineUpdate
import io.damao.inkflow.engine.InkFlowEngineProcess
import io.damao.inkflow.engine.NativeRimeEngine
import java.util.concurrent.Executor

class InkFlowInputMethodService : InputMethodService() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { command -> mainHandler.post(command) }

    private lateinit var controller: EngineController
    private var candidateRow: LinearLayout? = null
    private val selectionGuard = EditorSelectionGuard()
    private val compositionOwnership = EditorCompositionOwnership()
    private var connectionMutationDepth = 0
    private var pendingSelectionRecovery: EditorSelectionState? = null
    private var selectionRecoveryPosted = false
    private var selectionRecoveryInProgress = false
    private var editorActive = false
    private var editorSensitive = true
    private var editorGeneration: Long? = null
    private var editorEnterRoute: EditorEnterRoute = EditorEnterRoute.SendEnterKeyEvents
    private val unknownSelection = EditorSelectionState(-1, -1, -1, -1)
    private val engineListener = object : EngineController.Listener {
        override fun onEngineUpdate(
            token: CandidateToken,
            fallback: DirectInput?,
            update: EngineUpdate,
        ) {
            handleEngineUpdate(token, fallback, update)
        }

        override fun onDirectInput(generation: Long, input: DirectInput) {
            handleDirectInput(generation, input)
        }

        override fun onEngineFailure(generation: Long, fallback: DirectInput?) {
            handleEngineFailure(generation, fallback)
        }
    }

    override fun onCreate() {
        super.onCreate()
        controller = EngineController(
            backend = NativeRimeEngine(applicationContext),
            worker = InkFlowEngineProcess.executor,
            main = mainExecutor,
            listener = engineListener,
        )
    }

    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        clearCandidates()
        editorActive = true
        editorSensitive = attribute == null || EditorPrivacyPolicy.isSensitive(
            inputType = attribute.inputType,
            imeOptions = attribute.imeOptions,
        )
        editorEnterRoute = EditorEnterRoute.resolve(
            hasCustomAction = attribute?.actionLabel != null,
            customActionId = attribute?.actionId ?: 0,
            imeOptions = attribute?.imeOptions ?: EditorInfo.IME_ACTION_NONE,
        )
        val initialSelection = if (!editorSensitive && attribute != null &&
            attribute.initialSelStart >= 0 && attribute.initialSelEnd >= 0
        ) {
            EditorSelectionState(
                selectionStart = attribute.initialSelStart,
                selectionEnd = attribute.initialSelEnd,
                candidatesStart = -1,
                candidatesEnd = -1,
            )
        } else {
            null
        }
        pendingSelectionRecovery = null
        selectionGuard.reset(initialSelection)
        val generation = controller.startEditor(editorSensitive)
        editorGeneration = generation
        compositionOwnership.startEditor(generation, editorSensitive)
    }

    override fun onFinishInput() {
        editorGeneration = null
        editorEnterRoute = EditorEnterRoute.SendEnterKeyEvents
        compositionOwnership.finishEditor()
        controller.finishEditor()
        editorActive = false
        pendingSelectionRecovery = null
        selectionGuard.reset()
        currentInputConnection?.finishComposingText()
        clearCandidates()
        super.onFinishInput()
    }

    override fun onDestroy() {
        editorGeneration = null
        editorEnterRoute = EditorEnterRoute.SendEnterKeyEvents
        compositionOwnership.finishEditor()
        controller.finishEditor()
        editorActive = false
        pendingSelectionRecovery = null
        selectionGuard.reset()
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        val keyboard = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
        }

        val candidateStrip = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
            addView(LinearLayout(this@InkFlowInputMethodService).also { row ->
                row.orientation = LinearLayout.HORIZONTAL
                candidateRow = row
            })
        }
        keyboard.addView(candidateStrip)

        listOf("qwertyuiop", "asdfghjkl", "zxcvbnm").forEach { letters ->
            keyboard.addView(keyRow(letters))
        }
        keyboard.addView(actionRow())
        return keyboard
    }

    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        candidatesStart: Int,
        candidatesEnd: Int,
    ) {
        super.onUpdateSelection(
            oldSelStart,
            oldSelEnd,
            newSelStart,
            newSelEnd,
            candidatesStart,
            candidatesEnd,
        )
        if (!editorActive || editorSensitive) {
            clearCandidates()
            return
        }

        val selection = EditorSelection(
            oldSelectionStart = oldSelStart,
            oldSelectionEnd = oldSelEnd,
            selectionStart = newSelStart,
            selectionEnd = newSelEnd,
            candidatesStart = candidatesStart,
            candidatesEnd = candidatesEnd,
        )
        if (pendingSelectionRecovery != null && !selectionRecoveryInProgress) {
            requestSelectionRecovery(selection.afterState())
            return
        }
        if (selectionGuard.accepts(selection)) return

        requestSelectionRecovery(selection.afterState())
    }

    private fun handleEngineUpdate(
        token: CandidateToken,
        fallback: DirectInput?,
        update: EngineUpdate,
    ) {
        if (editorGeneration != token.generation) return
        val connection = currentInputConnection ?: return
        applyPlan(
            connection = connection,
            commands = EditorMutationPlanner.forUpdate(
                update = update,
                fallback = fallback,
                ownsComposingText = compositionOwnership.ownsComposition(token.generation),
            ),
            trackSelection = true,
            generation = token.generation,
        )
        if (pendingSelectionRecovery == null && controller.isCandidateTokenCurrent(token)) {
            showCandidates(update, token)
        } else {
            clearCandidates()
        }
    }

    private fun handleDirectInput(generation: Long, input: DirectInput) {
        if (editorGeneration != generation) return
        val connection = currentInputConnection ?: return
        // This path is used for passwords and no-personalized-learning fields.
        // Do not inspect surrounding or extracted text here.
        applyPlan(
            connection = connection,
            commands = EditorMutationPlanner.forDirectInput(input),
            trackSelection = false,
            generation = generation,
        )
        clearCandidates()
    }

    private fun handleEngineFailure(generation: Long, fallback: DirectInput?) {
        if (editorGeneration != generation) return
        val connection = currentInputConnection ?: return
        applyPlan(
            connection = connection,
            commands = EditorMutationPlanner.forFailure(
                fallback = fallback,
                ownsComposingText = compositionOwnership.ownsComposition(generation),
            ),
            trackSelection = true,
            generation = generation,
        )
        clearCandidates()
    }

    private fun keyRow(letters: String): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        letters.forEach { letter ->
            addView(keyButton(letter.toString()) {
                dispatchKey(
                    EngineKeyEvent(letter.code),
                    DirectInput.Text(letter.toString()),
                )
            })
        }
    }

    private fun actionRow(): View = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        addView(
            keyButton(
                getString(R.string.key_next_input_method),
                action = ::switchToNextAvailableInputMethod,
            ),
        )
        addView(keyButton("⌫") {
            dispatchKey(
                EngineKeyEvent(EngineKeys.BACKSPACE),
                DirectInput.DeleteBackward,
            )
        })
        addView(keyButton(getString(R.string.key_space), weight = 2f) {
            dispatchKey(
                EngineKeyEvent(' '.code),
                DirectInput.Text(" "),
            )
        })
        addView(keyButton("↵") {
            dispatchKey(
                EngineKeyEvent(EngineKeys.RETURN),
                DirectInput.Enter,
            )
        })
    }

    private fun keyButton(
        label: String,
        weight: Float = 1f,
        action: () -> Unit,
    ): Button = Button(this).apply {
        text = label
        isAllCaps = false
        layoutParams = LinearLayout.LayoutParams(
            0,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            weight,
        )
        setOnClickListener { action() }
    }

    private fun applyPlan(
        connection: InputConnection,
        commands: List<EditorCommand>,
        trackSelection: Boolean,
        generation: Long,
    ) {
        withConnectionMutation {
            connection.beginBatchEdit()
            try {
                for (command in commands) {
                    if (pendingSelectionRecovery != null || editorGeneration != generation) break
                    when (command) {
                        is EditorCommand.CommitText -> {
                            compositionOwnership.consumeForCommit(generation)
                            expectNonComposingSelection(
                                trackSelection = trackSelection,
                                replacementLengthUtf16 = command.value.length,
                            )
                            if (!connection.commitText(command.value, 1) && trackSelection) {
                                requestConnectionMutationRecovery(generation)
                            }
                        }

                        is EditorCommand.SetComposingText -> applyComposingText(
                            connection = connection,
                            command = command,
                            trackSelection = trackSelection,
                            generation = generation,
                        )

                        EditorCommand.ClearComposingText -> {
                            if (!compositionOwnership.consumeForClear(generation)) continue
                            expectNonComposingSelection(
                                trackSelection = trackSelection,
                                replacementLengthUtf16 = 0,
                            )
                            if (!connection.commitText("", 1) && trackSelection) {
                                requestConnectionMutationRecovery(generation)
                            }
                        }

                        EditorCommand.SendDeleteKeyEvents -> {
                            if (trackSelection) {
                                selectionGuard.expect(
                                    EditorSelectionExpectation.DeleteBackward,
                                )
                            }
                            sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL)
                        }

                        EditorCommand.PerformEditorEnter -> {
                            compositionOwnership.consumeForCommit(generation)
                            val route = editorEnterRoute
                            if (route == EditorEnterRoute.SendEnterKeyEvents) {
                                expectNonComposingSelection(
                                    trackSelection = trackSelection,
                                    replacementLengthUtf16 = 1,
                                )
                            }
                            val succeeded = EditorEnterDispatcher.dispatch(
                                route = route,
                                performEditorAction = connection::performEditorAction,
                                sendEnterKeyEvents = { sendEnterKeyEvents(connection) },
                            )
                            if (!succeeded) requestConnectionMutationRecovery(generation)
                        }
                    }
                }
            } finally {
                connection.endBatchEdit()
            }
        }
    }

    private fun applyComposingText(
        connection: InputConnection,
        command: EditorCommand.SetComposingText,
        trackSelection: Boolean,
        generation: Long,
    ) {
        val selectionPlan = EditorSelectionPlanner.forComposing(command)

        if (trackSelection) {
            selectionGuard.expect(selectionPlan.fallbackExpectation)
        }
        val compositionStart = if (trackSelection) {
            selectionGuard.predictedCompositionStart()
        } else {
            null
        }
        val ownershipAttempt = compositionOwnership.beginSetComposingText(generation)
        val succeeded = connection.setComposingText(command.value, 1)
        compositionOwnership.completeSetComposingText(ownershipAttempt, succeeded)
        if (!succeeded) {
            if (trackSelection) requestConnectionMutationRecovery(generation)
            return
        }
        if (pendingSelectionRecovery != null || editorGeneration != generation) return

        if (!selectionPlan.requiresAbsoluteSelection) return

        // Interior preedit selections are best-effort. The transition journal
        // provides the composing anchor without reading any editor text.
        val absoluteSelection = selectionPlan.resolveAbsoluteSelection(compositionStart) ?: return

        if (trackSelection) {
            selectionGuard.expect(selectionPlan.requestedExpectation)
        }
        if (!connection.setSelection(
            absoluteSelection.selectionStart,
            absoluteSelection.selectionEnd,
        ) && trackSelection
        ) {
            requestConnectionMutationRecovery(generation)
        }
    }

    private fun expectNonComposingSelection(
        trackSelection: Boolean,
        replacementLengthUtf16: Int,
    ) {
        if (trackSelection) {
            selectionGuard.expect(
                EditorSelectionExpectation.NonComposing(replacementLengthUtf16),
            )
        }
    }

    private fun sendEnterKeyEvents(connection: InputConnection): Boolean {
        val downTime = SystemClock.uptimeMillis()
        val flags = KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
        val downSent = connection.sendKeyEvent(
            KeyEvent(
                downTime,
                downTime,
                KeyEvent.ACTION_DOWN,
                KeyEvent.KEYCODE_ENTER,
                0,
                0,
                KeyCharacterMap.VIRTUAL_KEYBOARD,
                0,
                flags,
            ),
        )
        val upSent = connection.sendKeyEvent(
            KeyEvent(
                downTime,
                SystemClock.uptimeMillis(),
                KeyEvent.ACTION_UP,
                KeyEvent.KEYCODE_ENTER,
                0,
                0,
                KeyCharacterMap.VIRTUAL_KEYBOARD,
                0,
                flags,
            ),
        )
        return downSent && upSent
    }

    private inline fun withConnectionMutation(block: () -> Unit) {
        connectionMutationDepth += 1
        try {
            block()
        } finally {
            connectionMutationDepth -= 1
            if (connectionMutationDepth == 0 && !selectionRecoveryInProgress) {
                postSelectionRecoveryIfNeeded()
            }
        }
    }

    private fun requestSelectionRecovery(selection: EditorSelectionState) {
        compositionOwnership.invalidate(editorGeneration)
        selectionGuard.invalidate()
        pendingSelectionRecovery = selection
        clearCandidates()
        if (connectionMutationDepth == 0 && !selectionRecoveryInProgress) {
            postSelectionRecoveryIfNeeded()
        }
    }

    private fun requestConnectionMutationRecovery(generation: Long) {
        if (!editorActive || editorSensitive) return
        mutateIfEditorGenerationCurrent(generation, currentGeneration = { editorGeneration }) {
            compositionOwnership.invalidate(generation)
            selectionGuard.invalidate()
            if (pendingSelectionRecovery == null) pendingSelectionRecovery = unknownSelection
            clearCandidates()
            if (connectionMutationDepth == 0 && !selectionRecoveryInProgress) {
                postSelectionRecoveryIfNeeded()
            }
        }
    }

    private fun postSelectionRecoveryIfNeeded() {
        if (pendingSelectionRecovery == null || selectionRecoveryPosted) return
        selectionRecoveryPosted = true
        mainHandler.post {
            selectionRecoveryPosted = false
            recoverSelectionIfNeeded()
        }
    }

    private fun recoverSelectionIfNeeded() {
        val selection = pendingSelectionRecovery ?: return
        pendingSelectionRecovery = null
        if (!editorActive || editorSensitive) return

        selectionGuard.reset(selection)
        clearCandidates()
        val generation = controller.startEditor(sensitive = false)
        editorGeneration = generation
        compositionOwnership.startEditor(generation, sensitive = false)
        val connection = currentInputConnection ?: return
        selectionGuard.expect(EditorSelectionExpectation.FinishComposing)

        selectionRecoveryInProgress = true
        try {
            withConnectionMutation {
                if (!connection.finishComposingText()) {
                    mutateIfEditorGenerationCurrent(
                        generation,
                        currentGeneration = { editorGeneration },
                    ) {
                        selectionGuard.invalidate()
                    }
                }
            }
        } finally {
            selectionRecoveryInProgress = false
        }

        if (editorGeneration != generation) {
            postSelectionRecoveryIfNeeded()
            return
        }

        // A reentrant, unmatched callback from finishComposingText is already
        // the editor's latest state. Adopt it without recursively finishing.
        pendingSelectionRecovery?.let { latest ->
            pendingSelectionRecovery = null
            selectionGuard.reset(latest)
            clearCandidates()
        }
    }

    private fun dispatchKey(event: EngineKeyEvent, fallback: DirectInput) {
        clearCandidates()
        controller.processKey(event, fallback)
    }

    private fun showCandidates(update: EngineUpdate, token: CandidateToken) {
        val row = candidateRow ?: return
        row.removeAllViews()
        if (update.hasPreviousPage) {
            row.addView(candidateButton("‹") {
                clearCandidates()
                controller.changePage(backward = true, expectedToken = token)
            })
        }
        update.candidates.forEachIndexed { index, candidate ->
            val label = candidate.comment?.takeIf(String::isNotBlank)?.let { comment ->
                "${candidate.text} $comment"
            } ?: candidate.text
            row.addView(candidateButton(label) {
                clearCandidates()
                controller.selectCandidate(index, expectedToken = token)
            })
        }
        if (update.hasNextPage) {
            row.addView(candidateButton("›") {
                clearCandidates()
                controller.changePage(backward = false, expectedToken = token)
            })
        }
    }

    private fun candidateButton(label: String, action: () -> Unit): Button = Button(this).apply {
        text = label
        isAllCaps = false
        setOnClickListener { action() }
    }

    private fun clearCandidates() {
        candidateRow?.removeAllViews()
    }

    private fun switchToNextAvailableInputMethod() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            switchToNextInputMethod(false)
            return
        }
        val token = window.window?.attributes?.token ?: return
        val manager = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        manager.switchToNextInputMethod(token, false)
    }
}
