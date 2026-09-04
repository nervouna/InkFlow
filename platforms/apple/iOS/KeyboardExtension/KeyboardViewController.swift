import InkFlowAppleEngine
import UIKit

@MainActor
final class KeyboardViewController: UIInputViewController {
    private let preeditLabel = UILabel()
    private let candidateStack = UIStackView()
    private var pipeline: KeyboardEnginePipeline?
    private var latestRevision: UInt64 = 0
    private var contextGeneration = KeyboardContextGeneration()
    private var visibilityEpoch = KeyboardVisibilityEpoch()
    private var resetBarrier = KeyboardResetBarrier()
    private var finishGuard = KeyboardFinishGuard()
    private var candidateButtonMetadata: [ObjectIdentifier: (index: Int, revision: UInt64)] = [:]
    private var engineInputButtons: [UIButton] = []
    private var isLoadingEngine = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureKeyboard()
        configureEngine()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        visibilityEpoch.beginAppearance()
        finishGuard.invalidate()
        contextGeneration.invalidateForLifecycleBoundary()
        resetBarrier.invalidate()
        clearCompositionPresentation()
        if pipeline != nil {
            _ = enqueueEngineReset(generation: contextGeneration.generation)
        }
        if pipeline == nil { configureEngine() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        visibilityEpoch.beginDisappearance()
        finishGuard.invalidate()
        contextGeneration.invalidateForLifecycleBoundary()
        resetBarrier.invalidate()
        clearCompositionPresentation()
        finishComposition(advanceToNextKeyboard: false)
        super.viewWillDisappear(animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        visibilityEpoch.completeDisappearance()
        finishGuard.invalidate()
        contextGeneration.invalidateForLifecycleBoundary()
        resetBarrier.invalidate()
        clearCompositionPresentation()
        super.viewDidDisappear(animated)
    }

    override func textWillChange(_ textInput: UITextInput?) {
        observeExternalContextCallback()
        super.textWillChange(textInput)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        observeExternalContextCallback()
        super.textDidChange(textInput)
        if pipeline == nil { configureEngine() }
    }

    override func selectionWillChange(_ textInput: UITextInput?) {
        observeExternalContextCallback()
        super.selectionWillChange(textInput)
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        observeExternalContextCallback()
        super.selectionDidChange(textInput)
        if pipeline == nil { configureEngine() }
    }

    private func configureEngine() {
        guard pipeline == nil, !isLoadingEngine else { return }
        isLoadingEngine = true
        preeditLabel.text = "InkFlow 正在启动…"
        setEngineButtonsEnabled(false)
        Task { [weak self] in
            let pipeline = await Task.detached(priority: .userInitiated) {
                guard let session = try? KeyboardEngineHost.shared.makeSession() else {
                    return nil as KeyboardEnginePipeline?
                }
                return try? KeyboardEnginePipeline(session: session)
            }.value
            guard let self else { return }
            self.isLoadingEngine = false
            guard let pipeline else {
                self.preeditLabel.text = "InkFlow 无法启动"
                return
            }
            self.pipeline = pipeline
            self.preeditLabel.text = nil
            let generation = self.contextGeneration.generation
            _ = self.enqueueEngineReset(generation: generation)
        }
    }

    private func configureKeyboard() {
        preeditLabel.font = .preferredFont(forTextStyle: .body)
        preeditLabel.textAlignment = .center
        preeditLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        candidateStack.axis = .horizontal
        candidateStack.distribution = .fillEqually
        candidateStack.spacing = 4

        let root = UIStackView()
        root.axis = .vertical
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(preeditLabel)
        root.addArrangedSubview(candidateStack)

        for letters in ["qwertyuiop", "asdfghjkl", "zxcvbnm"] {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 4
            for letter in letters {
                let key = button(title: String(letter), action: #selector(letterPressed(_:)))
                key.isEnabled = false
                engineInputButtons.append(key)
                row.addArrangedSubview(key)
            }
            root.addArrangedSubview(row)
        }

        let controls = UIStackView()
        controls.axis = .horizontal
        controls.distribution = .fillProportionally
        controls.spacing = 6
        controls.addArrangedSubview(button(title: "🌐", action: #selector(nextKeyboardPressed)))
        let space = button(title: "空格", action: #selector(spacePressed))
        space.isEnabled = false
        engineInputButtons.append(space)
        controls.addArrangedSubview(space)
        controls.addArrangedSubview(button(title: "⌫", action: #selector(backspacePressed)))
        let enter = button(title: "换行", action: #selector(returnPressed))
        enter.isEnabled = false
        engineInputButtons.append(enter)
        controls.addArrangedSubview(enter)
        root.addArrangedSubview(controls)

        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
            candidateStack.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func button(title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func letterPressed(_ sender: UIButton) {
        guard let scalar = sender.title(for: .normal)?.unicodeScalars.first else { return }
        process(EngineKeyEvent(key: scalar.value))
    }

    @objc private func backspacePressed() {
        guard visibilityEpoch.allowsEngineInput,
              !finishGuard.isFinishing,
              !resetBarrier.isBlocking else { return }
        guard let pipeline else {
            textDocumentProxy.deleteBackward()
            return
        }
        let generation = contextGeneration.generation
        pipeline.backspace { [weak self] output in
            guard let self, self.contextGeneration.accepts(generation) else { return }
            self.consume(output)
        }
    }

    @objc private func spacePressed() {
        enqueue { pipeline, completion in pipeline.space(completion: completion) }
    }

    @objc private func returnPressed() {
        enqueue { pipeline, completion in pipeline.enter(completion: completion) }
    }

    @objc private func nextKeyboardPressed() {
        finishCompositionAndAdvance()
    }

    @objc private func candidatePressed(_ sender: UIButton) {
        guard visibilityEpoch.allowsEngineInput,
              !finishGuard.isFinishing,
              !resetBarrier.isBlocking,
              let metadata = candidateButtonMetadata[ObjectIdentifier(sender)],
              let pipeline else { return }
        let generation = contextGeneration.generation
        pipeline.selectCandidate(
            at: metadata.index,
            expectedRevision: metadata.revision
        ) { [weak self] output in
            guard let self, self.contextGeneration.accepts(generation) else { return }
            self.consume(output)
        }
    }

    private func process(_ event: EngineKeyEvent) {
        enqueue { pipeline, completion in
            pipeline.process(event, completion: completion)
        }
    }

    private func enqueue(
        _ operation: (
            KeyboardEnginePipeline,
            @escaping KeyboardEnginePipeline.Completion
        ) -> Void
    ) {
        guard visibilityEpoch.allowsEngineInput,
              !finishGuard.isFinishing,
              !resetBarrier.isBlocking,
              let pipeline else { return }
        let generation = contextGeneration.generation
        operation(pipeline) { [weak self] output in
            guard let self, self.contextGeneration.accepts(generation) else { return }
            self.consume(output)
        }
    }

    private func consume(_ output: KeyboardPipelineOutput) {
        latestRevision = output.revision
        switch output.action {
        case let .update(update):
            apply(update, revision: output.revision)
        case let .insertText(text):
            performProxyInsertion(text)
        case .deleteBackward:
            performProxyDeletion()
        case .noOp:
            break
        }
    }

    private func apply(_ update: EngineUpdate, revision: UInt64) {
        switch KeyboardUpdateRendering(update) {
        case let .clearAfterCommit(commit):
            performProxyInsertion(commit)
            clearCompositionPresentation()
        case let .composition(preedit, candidates):
            preeditLabel.text = preedit
            updateCandidateButtons(candidates, revision: revision)
        }
    }

    private func observeExternalContextCallback() {
        guard let generation = contextGeneration.beginExternalCallback() else { return }
        finishGuard.invalidate()
        clearCompositionPresentation()
        _ = enqueueEngineReset(generation: generation)

        // UITextDocumentProxy has no completion or mutation-origin token, and
        // UIKit does not promise callbacks for our own proxy writes. Treat every
        // callback as external; this coalescing only avoids duplicate resets.
        DispatchQueue.main.async { [weak self] in
            self?.contextGeneration.endExternalCallbackBatch()
        }
    }

    private func clearCompositionPresentation() {
        preeditLabel.text = nil
        updateCandidateButtons([], revision: latestRevision)
    }

    @discardableResult
    private func enqueueEngineReset(generation: UInt64) -> KeyboardResetBarrier.Token {
        let token = resetBarrier.begin(generation: generation)
        setEngineButtonsEnabled(false)
        guard let pipeline else {
            _ = resetBarrier.engineResetCompleted(
                token,
                currentGeneration: contextGeneration.generation
            )
            return token
        }
        pipeline.cancel { [weak self] _ in
            guard let self,
                  self.resetBarrier.engineResetCompleted(
                    token,
                    currentGeneration: self.contextGeneration.generation
                  ) else { return }
            self.setEngineButtonsEnabled(true)
        }
        return token
    }

    private func finishCompositionAndAdvance() {
        finishComposition(advanceToNextKeyboard: true)
    }

    private func finishComposition(advanceToNextKeyboard: Bool) {
        guard visibilityEpoch.allowsFinish, !finishGuard.isFinishing else { return }
        guard !resetBarrier.isBlocking else {
            finishGuard.invalidate()
            contextGeneration.invalidateForLifecycleBoundary()
            resetBarrier.invalidate()
            clearCompositionPresentation()
            if advanceToNextKeyboard { advanceToNextInputMode() }
            return
        }

        let capturedVisibilityEpoch = visibilityEpoch.value
        guard let token = finishGuard.begin(
            visibilityEpoch: capturedVisibilityEpoch
        ) else { return }
        setEngineButtonsEnabled(false)
        guard let pipeline else {
            finishGuard.invalidate()
            contextGeneration.invalidateForLifecycleBoundary()
            clearCompositionPresentation()
            if advanceToNextKeyboard { advanceToNextInputMode() }
            return
        }
        pipeline.finishComposition { [self] output in
            guard self.finishGuard.complete(
                token,
                currentVisibilityEpoch: self.visibilityEpoch.value
            ) else { return }
            self.consume(output)
            self.contextGeneration.invalidateForLifecycleBoundary()
            self.resetBarrier.invalidate()
            self.clearCompositionPresentation()
            if advanceToNextKeyboard {
                self.advanceToNextInputMode()
            }
        }
    }

    private func performProxyInsertion(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    private func performProxyDeletion() {
        textDocumentProxy.deleteBackward()
    }

    private func updateCandidateButtons(
        _ candidates: [EngineCandidate],
        revision: UInt64
    ) {
        candidateButtonMetadata.removeAll(keepingCapacity: true)
        candidateStack.arrangedSubviews.forEach {
            candidateStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, candidate) in candidates.prefix(5).enumerated() {
            let button = button(title: candidate.text, action: #selector(candidatePressed(_:)))
            button.tag = index
            candidateButtonMetadata[ObjectIdentifier(button)] = (index, revision)
            candidateStack.addArrangedSubview(button)
        }
    }

    private func setEngineButtonsEnabled(_ enabled: Bool) {
        let effectiveValue = enabled
            && pipeline != nil
            && visibilityEpoch.allowsEngineInput
            && !resetBarrier.isBlocking
            && !finishGuard.isFinishing
        engineInputButtons.forEach { $0.isEnabled = effectiveValue }
        candidateStack.isUserInteractionEnabled = effectiveValue
    }
}
