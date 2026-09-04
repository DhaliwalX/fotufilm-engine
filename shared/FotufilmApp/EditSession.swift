import Foundation
import Observation

struct EditPersistenceFailure: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

@MainActor
@Observable
final class EditSession {

    /// Where a settled edit is written, and what it takes to write it.
    struct PersistenceSink {
        /// Whether there is anything to write for yet.
        var isReady: @MainActor () -> Bool = { false }
        /// The owner's media generation.
        var generation: @MainActor () -> Int = { 0 }
        /// The debounced write itself.
        var save: @MainActor (EditState) async -> Bool = { _ in false }
        /// The close-time write.
        var flush: @MainActor (EditState) -> Void = { _ in }
        /// Clears the owner's persistence state after closing.
        var reset: @MainActor () -> Void = {}
    }

    var persistence = PersistenceSink()

    /// Where a changed edit goes to be seen.
    var onApply: ((_ state: EditState, _ previous: EditState,
                   _ restoring: Bool) -> Void)?

    var edit = EditState() {
        didSet { editChanged(from: oldValue) }
    }

    private func editChanged(from old: EditState) {
        guard edit != old else { return }
        recordHistory(from: old)
        if !isRestoringHistory { storeWanted = true }
        if storeWanted { schedulePersist() }
        onApply?(edit, old, isRestoringHistory)
    }

    private(set) var canUndo = false
    private(set) var canRedo = false
    private var undoStack: [EditState] = []
    private var redoStack: [EditState] = []
    private var isRestoringHistory = false
    private var gestureStart: EditState?
    private var lastUndoPush = Date.distantPast

    var isContinuousEditActive: Bool { gestureStart != nil }

    /// Marks the start of a continuous gesture (a ruler drag); everything
    /// until `endContinuousEdit` collapses into a single undo point.
    func beginContinuousEdit() {
        if gestureStart == nil { gestureStart = edit }
    }

    func endContinuousEdit() {
        guard let start = gestureStart else { return }
        gestureStart = nil
        guard start != edit else { return }
        undoStack.append(start)
        redoStack.removeAll()
        lastUndoPush = Date()
        updateHistoryFlags()
    }

    /// The whole timeline, oldest first: everything undo would walk back through, the state
    /// standing now, and everything redo would walk forward into.
    var history: [EditState] { undoStack + [edit] + redoStack.reversed() }

    /// A modal editor's entry state, including the timeline that Cancel must put back.
    struct HistoryCheckpoint {
        fileprivate let edit: EditState
        fileprivate let undoStack: [EditState]
        fileprivate let redoStack: [EditState]
        fileprivate let gestureStart: EditState?
        fileprivate let lastUndoPush: Date
    }

    func historyCheckpoint() -> HistoryCheckpoint {
        HistoryCheckpoint(edit: edit, undoStack: undoStack,
                          redoStack: redoStack, gestureStart: gestureStart,
                          lastUndoPush: lastUndoPush)
    }

    /// Cancels every edit made since a modal surface took its checkpoint.
    func restoreHistoryCheckpoint(_ checkpoint: HistoryCheckpoint) {
        withoutHistory { edit = checkpoint.edit }
        undoStack = checkpoint.undoStack
        redoStack = checkpoint.redoStack
        gestureStart = checkpoint.gestureStart
        lastUndoPush = checkpoint.lastUndoPush
        updateHistoryFlags()
    }

    /// Current position in `history`.
    var historyIndex: Int { undoStack.count }

    /// Applies undo or redo steps until reaching `index`.
    func goToHistory(_ index: Int) {
        let steps = index - historyIndex
        guard steps != 0, index >= 0, index < history.count else { return }
        for _ in 0..<abs(steps) {
            steps < 0 ? undo() : redo()
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(edit)
        applyHistory(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        applyHistory(next)
    }

    /// Restores saved state without creating a history entry.
    func restoreEdit(_ state: EditState) {
        withoutHistory { edit = state }
    }

    /// Runs state changes without adding an undo entry.
    func withoutHistory(_ body: () -> Void) {
        isRestoringHistory = true
        body()
        isRestoringHistory = false
    }

    /// Forgets the timeline.
    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        gestureStart = nil
        updateHistoryFlags()
    }

    private func applyHistory(_ state: EditState) {
        updateHistoryFlags()
        isRestoringHistory = true
        edit = state
        isRestoringHistory = false
    }

    private func recordHistory(from old: EditState) {
        guard !isRestoringHistory, gestureStart == nil else { return }
        let now = Date()
        defer { lastUndoPush = now }
        redoStack.removeAll()
        if now.timeIntervalSince(lastUndoPush) < 0.8, !undoStack.isEmpty {
            updateHistoryFlags()
            return
        }
        undoStack.append(old)
        updateHistoryFlags()
    }

    private func updateHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private(set) var storeWanted = false
    private var persistTask: Task<Void, Never>?

    /// Enables persistence for subsequent edits.
    func armPersistence() { storeWanted = true }

    /// Cancels pending persistence when the entry is deleted or its media is replaced.
    func disarmPersistence() {
        persistTask?.cancel()
        persistTask = nil
        storeWanted = false
    }

    /// One debounced write behind the newest state.
    func schedulePersist() {
        guard storeWanted, persistence.isReady() else { return }
        persistTask?.cancel()
        let generation = persistence.generation()
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self,
                  self.persistence.generation() == generation else { return }
            await self.persistNow()
        }
    }

    private func persistNow() async {
        guard storeWanted, persistence.isReady() else { return }
        _ = await persistence.save(edit)
    }

    /// Retries a failed background write without ending the open editing session.
    @discardableResult
    func retryPersistence() async -> Bool {
        guard storeWanted, persistence.isReady() else { return false }
        return await persistence.save(edit)
    }

    /// Cancels the debounce and verifies the newest state reached the shelf before a screen closes.
    /// A failed write remains armed, so the caller can offer Retry without losing the state.
    func persistBeforeClose() async -> Bool {
        persistTask?.cancel()
        persistTask = nil
        guard storeWanted else { return true }
        guard persistence.isReady() else { return false }
        let saved = await persistence.save(edit)
        guard saved else { return false }
        persistence.reset()
        storeWanted = false
        return true
    }

    /// The close-time write: whatever the debounce was still holding, said
    /// now, and then the shelf let go of.
    func flushPersistence() {
        persistTask?.cancel()
        persistTask = nil
        defer {
            persistence.reset()
            storeWanted = false
        }
        guard storeWanted, persistence.isReady() else { return }
        persistence.flush(edit)
    }
}
