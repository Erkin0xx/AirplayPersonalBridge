//
//  SleepResumePolicy.swift
//  AirplayPersonalBridge
//

/// La décision de reprendre une diffusion au réveil, sans notification ni minuterie.
///
/// Elle tient en peu de chose, mais les enchaînements comptent : une seconde veille tombée pendant
/// le délai de reprise ne doit pas faire oublier qu'il fallait reprendre, et un clic sur Arrêter
/// pendant ce même délai doit l'emporter sur elle.
struct SleepResumePolicy {
    /// Une diffusion a été interrompue par la veille, et attend d'être reprise.
    private(set) var shouldResumeAfterWake = false

    /// Le Mac s'endort. Rend `true` s'il faut arrêter la diffusion.
    mutating func systemWillSleep(isStreaming: Bool) -> Bool {
        guard isStreaming else { return false }
        shouldResumeAfterWake = true
        return true
    }

    /// La reprise part : elle ne se rejouera pas à la prochaine veille.
    mutating func resumeDidStart() {
        shouldResumeAfterWake = false
    }

    /// L'utilisateur a décidé lui-même, ce qui rend caduque toute reprise programmée.
    mutating func userTookOver() {
        shouldResumeAfterWake = false
    }
}
