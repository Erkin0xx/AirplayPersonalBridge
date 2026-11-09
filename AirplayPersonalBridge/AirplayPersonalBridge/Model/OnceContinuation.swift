//
//  OnceContinuation.swift
//  AirplayPersonalBridge
//

import Foundation

/// Reprise unique d'une attente, par celui qui arrive le premier : la fin d'une tâche, une échéance,
/// la fin d'un processus fils.
///
/// Deux reprises d'une `CheckedContinuation` sont fatales, et les concurrents ne s'attendent pas l'un
/// l'autre. Verrouillée : le gestionnaire de fin d'un `Process` la reprend hors du MainActor, sur une
/// file quelconque, pendant qu'une échéance peut la reprendre depuis le MainActor.
nonisolated final class OnceContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

extension OnceContinuation where Value == Void {
    func resume() { resume(returning: ()) }
}
