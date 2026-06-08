//
//  UserSession.swift
//  VoiceAgent
//
//  Created by Spectra Esports  on 9/6/26.
//

import Foundation
import Supabase

nonisolated enum UserSession: Sendable, Hashable {
    case idle
    case loading
    case authenticated
    case unauthenticated
}

extension UserSession: CustomStringConvertible {
    var description: String {
        switch self {
        case .idle:
            return "idle"
        case .loading:
            return "loading"
        case .authenticated:
            return "authenticated"
        case .unauthenticated:
            return "unauthenticated"
        }
    }
}

extension UserSession {
    init(event: AuthChangeEvent, session: Session?) {
        switch event {
        case .signedOut, .userDeleted:
            self = .unauthenticated
        case .initialSession,
             .signedIn,
             .tokenRefreshed,
             .userUpdated,
             .passwordRecovery,
             .mfaChallengeVerified:
            self = .init(session: session)
        @unknown default:
            self = .init(session: session)
        }
    }

    private init(session: Session?) {
        switch session {
        case .none:
            self = .unauthenticated
        case .some(let session):
            self = session.isExpired ? .loading : .authenticated
        }
    }
}
