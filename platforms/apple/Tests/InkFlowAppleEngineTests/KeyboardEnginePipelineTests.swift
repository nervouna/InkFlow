import Foundation
@testable import InkFlowAppleEngine
import XCTest

@MainActor
private final class PipelineOutputRecorder {
    private let expectedCount: Int
    private var outputs: [KeyboardPipelineOutput] = []
    private var waiter: CheckedContinuation<[KeyboardPipelineOutput], Never>?

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    func record(_ output: KeyboardPipelineOutput) {
        outputs.append(output)
        guard outputs.count == expectedCount else { return }
        waiter?.resume(returning: outputs)
        waiter = nil
    }

    func values() async -> [KeyboardPipelineOutput] {
        if outputs.count == expectedCount { return outputs }
        return await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
private final class ContextBoundCommitSink {
    private(set) var context = KeyboardContextGeneration()
    private(set) var commits: [String] = []
    private(set) var cancellationRequests = 0

    func captureGeneration() -> UInt64 {
        context.generation
    }

    @discardableResult
    func invalidateForExternalChange() -> Bool {
        let shouldCancel = context.beginExternalCallback() != nil
        if shouldCancel { cancellationRequests += 1 }
        return shouldCancel
    }

    func endExternalCallbackBatch() {
        context.endExternalCallbackBatch()
    }

    func consume(
        _ output: KeyboardPipelineOutput,
        capturedGeneration: UInt64
    ) {
        guard context.accepts(capturedGeneration),
              let commit = output.update?.commitText,
              !commit.isEmpty else { return }
        commits.append(commit)
    }
}

@MainActor
private final class ControllerPipelineSink {
    private(set) var context = KeyboardContextGeneration()
    private var visibility = KeyboardVisibilityEpoch()
    private var finishGuard = KeyboardFinishGuard()
    private(set) var resetBarrier = KeyboardResetBarrier()
    private(set) var insertedTexts: [String] = []
    private(set) var preedit = ""
    private(set) var candidateTexts: [String] = []
    private(set) var advanceCount = 0

    var isFinishing: Bool {
        finishGuard.isFinishing
    }

    var allowsEngineInput: Bool {
        visibility.allowsEngineInput
            && !finishGuard.isFinishing
            && !resetBarrier.isBlocking
    }

    init() {
        visibility.beginAppearance()
    }

    func beginFinish() -> KeyboardFinishGuard.Token? {
        finishGuard.begin(visibilityEpoch: visibility.value)
    }

    func captureGeneration() -> UInt64 {
        context.generation
    }

    func consume(
        _ output: KeyboardPipelineOutput,
        capturedGeneration: UInt64
    ) {
        guard context.accepts(capturedGeneration) else { return }
        consumeAccepted(output)
    }

    func completeFinish(
        _ output: KeyboardPipelineOutput,
        token: KeyboardFinishGuard.Token,
        advances: Bool = true
    ) {
        guard finishGuard.complete(
            token,
            currentVisibilityEpoch: visibility.value
        ) else { return }
        consumeAccepted(output)
        context.invalidateForLifecycleBoundary()
        resetBarrier.invalidate()
        clearComposition()
        if advances { advanceCount += 1 }
    }

    func beginExternalReset() -> KeyboardResetBarrier.Token? {
        guard let generation = context.beginExternalCallback() else { return nil }
        finishGuard.invalidate()
        clearComposition()
        return resetBarrier.begin(generation: generation)
    }

    func completeExternalReset(_ token: KeyboardResetBarrier.Token) -> Bool {
        resetBarrier.engineResetCompleted(
            token,
            currentGeneration: context.generation
        )
    }

    func endExternalCallbackBatch() {
        context.endExternalCallbackBatch()
    }

    private func consumeAccepted(_ output: KeyboardPipelineOutput) {
        switch output.action {
        case let .update(update):
            switch KeyboardUpdateRendering(update) {
            case let .clearAfterCommit(text):
                insertedTexts.append(text)
                clearComposition()
            case let .composition(newPreedit, candidates):
                preedit = newPreedit
                candidateTexts = candidates.map(\.text)
            }
        case let .insertText(text):
            insertedTexts.append(text)
        case .deleteBackward:
            break
        case .noOp:
            break
        }
    }

    private func clearComposition() {
        preedit = ""
        candidateTexts = []
    }
}

@MainActor
final class KeyboardEnginePipelineTests: XCTestCase {
    func testActionsAreExecutedAndDeliveredFIFO() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let recorder = PipelineOutputRecorder(expectedCount: 3)

        for scalar in "nih".unicodeScalars {
            pipeline.process(EngineKeyEvent(key: scalar.value)) { output in
                recorder.record(output)
            }
        }

        let outputs = await recorder.values()
        XCTAssertEqual(outputs.map(\.revision), [1, 2, 3])
        XCTAssertEqual(outputs.compactMap(\.update?.preedit), ["n", "ni", "nih"])
    }

    func testStaleCandidateRevisionDoesNotSelectChangedComposition() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)

        let ni = await process("ni", through: pipeline)
        let staleRevision = try XCTUnwrap(ni.last?.revision)
        let recorder = PipelineOutputRecorder(expectedCount: 2)
        pipeline.process(EngineKeyEvent(key: UInt32(Character("h").asciiValue!))) { output in
            recorder.record(output)
        }
        pipeline.selectCandidate(at: 0, expectedRevision: staleRevision) { output in
            recorder.record(output)
        }

        let outputs = await recorder.values()
        XCTAssertEqual(outputs.first?.update?.preedit, "nih")
        XCTAssertTrue(outputs.last?.isNoOp == true)
    }

    func testQueuedCandidateThenFinishCommitsExactlyOnce() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)

        let inputs = await process("nihao", through: pipeline)
        let composed = try XCTUnwrap(inputs.last?.update)
        let candidateIndex = try XCTUnwrap(
            composed.candidates.firstIndex(where: { $0.text == "你好" })
        )
        let revision = try XCTUnwrap(inputs.last?.revision)
        let recorder = PipelineOutputRecorder(expectedCount: 2)
        pipeline.selectCandidate(at: candidateIndex, expectedRevision: revision) { output in
            recorder.record(output)
        }
        pipeline.finishComposition { output in
            recorder.record(output)
        }

        let outputs = await recorder.values()
        let commits = outputs.compactMap(\.update?.commitText).filter { !$0.isEmpty }
        XCTAssertEqual(commits, ["你好"])
        XCTAssertTrue(outputs.last?.update?.preedit.isEmpty == true)
    }

    func testDoubleCandidateSelectionCommitsExactlyOnce() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)

        let inputs = await process("nihao", through: pipeline)
        let composed = try XCTUnwrap(inputs.last?.update)
        let candidateIndex = try XCTUnwrap(
            composed.candidates.firstIndex(where: { $0.text == "你好" })
        )
        let revision = try XCTUnwrap(inputs.last?.revision)
        let recorder = PipelineOutputRecorder(expectedCount: 2)
        for _ in 0..<2 {
            pipeline.selectCandidate(at: candidateIndex, expectedRevision: revision) { output in
                recorder.record(output)
            }
        }

        let outputs = await recorder.values()
        let commits = outputs.compactMap(\.update?.commitText).filter { !$0.isEmpty }
        XCTAssertEqual(commits, ["你好"])
        XCTAssertTrue(outputs.last?.isNoOp == true)
    }

    func testStaleNoOpDoesNotInvalidateCurrentCandidateRevision() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)

        let oldInputs = await process("niha", through: pipeline)
        let oldRevision = try XCTUnwrap(oldInputs.last?.revision)
        let currentInputs = await process("o", through: pipeline)
        let current = try XCTUnwrap(currentInputs.last?.update)
        let currentRevision = try XCTUnwrap(currentInputs.last?.revision)
        let candidateIndex = try XCTUnwrap(
            current.candidates.firstIndex(where: { $0.text == "你好" })
        )
        let recorder = PipelineOutputRecorder(expectedCount: 2)
        pipeline.selectCandidate(at: 0, expectedRevision: oldRevision) { output in
            recorder.record(output)
        }
        pipeline.selectCandidate(
            at: candidateIndex,
            expectedRevision: currentRevision
        ) { output in
            recorder.record(output)
        }

        let outputs = await recorder.values()
        XCTAssertTrue(outputs.first?.isNoOp == true)
        XCTAssertEqual(outputs.first?.revision, currentRevision)
        let commits = outputs.compactMap(\.update?.commitText).filter { !$0.isEmpty }
        XCTAssertEqual(commits, ["你好"])
    }

    func testTextAndSelectionCallbacksCoalesceOneContextInvalidation() {
        var context = KeyboardContextGeneration()
        let queuedGeneration = context.generation

        XCTAssertEqual(context.beginExternalCallback(), 1)
        XCTAssertNil(context.beginExternalCallback())
        XCTAssertFalse(context.accepts(queuedGeneration))

        context.endExternalCallbackBatch()
        XCTAssertEqual(context.beginExternalCallback(), 2)
        XCTAssertFalse(context.accepts(1))
    }

    func testEmptyCompositionSpaceInsertsOneLiteralSpace() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let sink = ControllerPipelineSink()
        let generation = sink.captureGeneration()
        let recorder = PipelineOutputRecorder(expectedCount: 2)

        pipeline.space { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }
        pipeline.finishComposition { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }

        let outputs = await recorder.values()
        XCTAssertEqual(sink.insertedTexts, [" "])
        XCTAssertEqual(outputs.first?.insertedText, " ")
        XCTAssertNil(outputs.last?.update?.commitText)
    }

    func testCandidateCompositionSpaceCommitsFirstCandidateWithoutLiteralSpace() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let inputs = await process("nihao", through: pipeline)
        XCTAssertFalse(try XCTUnwrap(inputs.last?.update?.candidates).isEmpty)
        let sink = ControllerPipelineSink()
        let generation = sink.captureGeneration()
        let recorder = PipelineOutputRecorder(expectedCount: 2)

        pipeline.space { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }
        pipeline.finishComposition { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }

        let outputs = await recorder.values()
        XCTAssertEqual(sink.insertedTexts, ["你好"])
        XCTAssertEqual(outputs.first?.update?.commitText, "你好")
        XCTAssertNil(outputs.first?.insertedText)
        XCTAssertNil(outputs.last?.update?.commitText)
    }

    func testUnmatchedCompositionSpaceCommitsInOrderAndFinishDoesNotRepeat() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let inputs = await process("n", through: pipeline)
        XCTAssertEqual(inputs.last?.update?.preedit, "n")
        XCTAssertTrue(try XCTUnwrap(inputs.last?.update?.candidates).isEmpty)
        let sink = ControllerPipelineSink()
        let generation = sink.captureGeneration()
        let recorder = PipelineOutputRecorder(expectedCount: 2)

        pipeline.space { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }
        pipeline.finishComposition { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }

        let outputs = await recorder.values()
        XCTAssertEqual(sink.insertedTexts, ["n"])
        XCTAssertEqual(outputs.first?.update?.commitText, "n")
        XCTAssertTrue(outputs.first?.update?.handled == true)
        XCTAssertNil(outputs.first?.insertedText)
        XCTAssertNil(outputs.last?.update?.commitText)
        XCTAssertEqual(sink.preedit, "")
    }

    func testSpaceThenLetterPreservesLetterComposition() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let sink = ControllerPipelineSink()
        let generation = sink.captureGeneration()
        let recorder = PipelineOutputRecorder(expectedCount: 2)

        pipeline.space { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }
        pipeline.process(EngineKeyEvent(key: UInt32(Character("n").asciiValue!))) { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }

        _ = await recorder.values()
        XCTAssertEqual(sink.insertedTexts, [" "])
        XCTAssertEqual(sink.preedit, "n")
        XCTAssertEqual(sink.captureGeneration(), generation)
        XCTAssertTrue(sink.allowsEngineInput)
        XCTAssertFalse(sink.resetBarrier.isBlocking)
    }

    func testSpaceLetterThenFinishCommitsAllAndAdvancesOnce() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let sink = ControllerPipelineSink()
        let generation = sink.captureGeneration()
        let recorder = PipelineOutputRecorder(expectedCount: 3)

        pipeline.space { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }
        pipeline.process(EngineKeyEvent(key: UInt32(Character("n").asciiValue!))) { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }
        let finishToken = try XCTUnwrap(sink.beginFinish())
        pipeline.finishComposition { output in
            sink.completeFinish(output, token: finishToken)
            recorder.record(output)
        }

        _ = await recorder.values()
        XCTAssertEqual(sink.insertedTexts, [" ", "n"])
        XCTAssertEqual(sink.preedit, "")
        XCTAssertEqual(sink.candidateTexts, [])
        XCTAssertEqual(sink.advanceCount, 1)
        XCTAssertFalse(sink.isFinishing)
        XCTAssertFalse(sink.resetBarrier.isBlocking)
    }

    func testConsecutivePlainInsertsAreNotLost() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let sink = ControllerPipelineSink()
        let generation = sink.captureGeneration()
        let recorder = PipelineOutputRecorder(expectedCount: 2)

        for _ in 0..<2 {
            pipeline.space { output in
                sink.consume(output, capturedGeneration: generation)
                recorder.record(output)
            }
        }

        _ = await recorder.values()
        XCTAssertEqual(sink.insertedTexts, [" ", " "])
        XCTAssertEqual(sink.captureGeneration(), generation)
        XCTAssertTrue(sink.allowsEngineInput)
        XCTAssertFalse(sink.resetBarrier.isBlocking)
    }

    func testExternalCallbackInvalidatesQueuedWorkAndResetsBeforeNewInput() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let sink = ControllerPipelineSink()
        let staleGeneration = sink.captureGeneration()
        let staleRecorder = PipelineOutputRecorder(expectedCount: 2)

        pipeline.process(EngineKeyEvent(key: UInt32(Character("n").asciiValue!))) { output in
            sink.consume(output, capturedGeneration: staleGeneration)
            staleRecorder.record(output)
        }
        let resetToken = try XCTUnwrap(sink.beginExternalReset())
        XCTAssertFalse(sink.allowsEngineInput)
        pipeline.cancel { output in
            _ = sink.completeExternalReset(resetToken)
            staleRecorder.record(output)
        }

        let staleOutputs = await staleRecorder.values()
        XCTAssertEqual(staleOutputs.first?.update?.preedit, "n")
        XCTAssertEqual(staleOutputs.last?.update?.preedit, "")
        XCTAssertEqual(sink.preedit, "")
        XCTAssertFalse(sink.resetBarrier.isBlocking)
        sink.endExternalCallbackBatch()
        XCTAssertTrue(sink.allowsEngineInput)

        let currentGeneration = sink.captureGeneration()
        let currentRecorder = PipelineOutputRecorder(expectedCount: 1)
        pipeline.process(EngineKeyEvent(key: UInt32(Character("h").asciiValue!))) { output in
            sink.consume(output, capturedGeneration: currentGeneration)
            currentRecorder.record(output)
        }

        _ = await currentRecorder.values()
        XCTAssertEqual(sink.preedit, "h")
        XCTAssertEqual(sink.insertedTexts, [])
    }

    func testStaleFinishCompletionCannotAlterNewerFinish() throws {
        var context = KeyboardContextGeneration()
        var visibility = KeyboardVisibilityEpoch()
        var resetBarrier = KeyboardResetBarrier()
        var finishGuard = KeyboardFinishGuard()

        visibility.beginAppearance()
        let finishA = try XCTUnwrap(
            finishGuard.begin(visibilityEpoch: visibility.value)
        )
        let invalidatedGeneration = try XCTUnwrap(
            context.beginExternalCallback()
        )
        finishGuard.invalidate()
        let resetToken = resetBarrier.begin(
            generation: invalidatedGeneration
        )
        XCTAssertTrue(
            resetBarrier.engineResetCompleted(
                resetToken,
                currentGeneration: context.generation
            )
        )

        let finishB = try XCTUnwrap(
            finishGuard.begin(visibilityEpoch: visibility.value)
        )
        XCTAssertFalse(
            finishGuard.complete(
                finishA,
                currentVisibilityEpoch: visibility.value
            )
        )
        XCTAssertTrue(finishGuard.isFinishing)
        XCTAssertTrue(
            finishGuard.complete(
                finishB,
                currentVisibilityEpoch: visibility.value
            )
        )
        XCTAssertFalse(finishGuard.isFinishing)
    }

    func testDisappearanceRejectsActiveFinishAndAppearanceRecovers() throws {
        var context = KeyboardContextGeneration()
        var visibility = KeyboardVisibilityEpoch()
        var resetBarrier = KeyboardResetBarrier()
        var finishGuard = KeyboardFinishGuard()

        visibility.beginAppearance()
        let hiddenFinish = try XCTUnwrap(
            finishGuard.begin(visibilityEpoch: visibility.value)
        )
        visibility.beginDisappearance()
        finishGuard.invalidate()
        context.invalidateForLifecycleBoundary()
        resetBarrier.invalidate()
        visibility.completeDisappearance()

        XCTAssertFalse(
            finishGuard.complete(
                hiddenFinish,
                currentVisibilityEpoch: visibility.value
            )
        )
        XCTAssertFalse(finishGuard.isFinishing)
        XCTAssertFalse(visibility.allowsEngineInput)

        visibility.beginAppearance()
        let currentFinish = try XCTUnwrap(
            finishGuard.begin(visibilityEpoch: visibility.value)
        )
        XCTAssertTrue(
            finishGuard.complete(
                currentFinish,
                currentVisibilityEpoch: visibility.value
            )
        )
        XCTAssertFalse(finishGuard.isFinishing)
        XCTAssertTrue(visibility.allowsEngineInput)
    }

    func testQueuedCommitBeforeFinishStillCompletesAndAdvances() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)

        let inputs = await process("nihao", through: pipeline)
        let composed = try XCTUnwrap(inputs.last?.update)
        let candidateIndex = try XCTUnwrap(
            composed.candidates.firstIndex(where: { $0.text == "你好" })
        )
        let revision = try XCTUnwrap(inputs.last?.revision)
        let sink = ControllerPipelineSink()
        let generation = sink.captureGeneration()
        let recorder = PipelineOutputRecorder(expectedCount: 2)

        pipeline.selectCandidate(
            at: candidateIndex,
            expectedRevision: revision
        ) { output in
            sink.consume(output, capturedGeneration: generation)
            recorder.record(output)
        }
        let finishToken = try XCTUnwrap(sink.beginFinish())
        pipeline.finishComposition { output in
            sink.completeFinish(output, token: finishToken)
            recorder.record(output)
        }

        _ = await recorder.values()
        XCTAssertEqual(sink.insertedTexts, ["你好"])
        XCTAssertEqual(sink.advanceCount, 1)
        XCTAssertFalse(sink.isFinishing)
    }

    func testCommittedUpdateCannotRenderItsStaleComposition() {
        let update = EngineUpdate(
            handled: true,
            commitText: "你好",
            preedit: "stale-preedit",
            cursorUTF16Offset: 2,
            selectionUTF16Range: NSRange(location: 0, length: 2),
            candidates: [EngineCandidate(text: "stale-candidate", comment: nil)],
            highlightedCandidateIndex: 0,
            hasPreviousPage: false,
            hasNextPage: true
        )

        XCTAssertEqual(
            KeyboardUpdateRendering(update),
            .clearAfterCommit("你好")
        )
    }

    func testSelectionChangeRejectsQueuedCommitAndDoesNotRepeatSideEffects() async throws {
        let session = try AppleEngineTestEnvironment.makeSession()
        _ = try session.reset()
        let pipeline = try KeyboardEnginePipeline(session: session)
        let sink = ContextBoundCommitSink()

        let inputs = await process("nihao", through: pipeline)
        let composed = try XCTUnwrap(inputs.last?.update)
        let candidateIndex = try XCTUnwrap(
            composed.candidates.firstIndex(where: { $0.text == "你好" })
        )
        let revision = try XCTUnwrap(inputs.last?.revision)
        let queuedGeneration = sink.captureGeneration()
        let staleRecorder = PipelineOutputRecorder(expectedCount: 2)
        pipeline.selectCandidate(
            at: candidateIndex,
            expectedRevision: revision
        ) { output in
            sink.consume(output, capturedGeneration: queuedGeneration)
            staleRecorder.record(output)
        }

        XCTAssertTrue(sink.invalidateForExternalChange())
        XCTAssertFalse(sink.invalidateForExternalChange())
        pipeline.cancel { output in
            staleRecorder.record(output)
        }

        let staleOutputs = await staleRecorder.values()
        XCTAssertEqual(
            staleOutputs.compactMap(\.update?.commitText).filter { !$0.isEmpty },
            ["你好"]
        )
        XCTAssertEqual(sink.commits, [])
        XCTAssertEqual(sink.cancellationRequests, 1)

        sink.endExternalCallbackBatch()
        let currentInputs = await process("nihao", through: pipeline)
        let current = try XCTUnwrap(currentInputs.last?.update)
        let currentCandidateIndex = try XCTUnwrap(
            current.candidates.firstIndex(where: { $0.text == "你好" })
        )
        let currentRevision = try XCTUnwrap(currentInputs.last?.revision)
        let currentGeneration = sink.captureGeneration()
        let currentRecorder = PipelineOutputRecorder(expectedCount: 1)
        pipeline.selectCandidate(
            at: currentCandidateIndex,
            expectedRevision: currentRevision
        ) { output in
            sink.consume(output, capturedGeneration: currentGeneration)
            currentRecorder.record(output)
        }

        _ = await currentRecorder.values()
        XCTAssertEqual(sink.commits, ["你好"])
    }

    private func process(
        _ text: String,
        through pipeline: KeyboardEnginePipeline
    ) async -> [KeyboardPipelineOutput] {
        let recorder = PipelineOutputRecorder(expectedCount: text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            pipeline.process(EngineKeyEvent(key: scalar.value)) { output in
                recorder.record(output)
            }
        }
        return await recorder.values()
    }
}

private extension KeyboardPipelineOutput {
    var update: EngineUpdate? {
        guard case let .update(update) = action else { return nil }
        return update
    }

    var isNoOp: Bool {
        guard case .noOp = action else { return false }
        return true
    }

    var insertedText: String? {
        guard case let .insertText(text) = action else { return nil }
        return text
    }
}
