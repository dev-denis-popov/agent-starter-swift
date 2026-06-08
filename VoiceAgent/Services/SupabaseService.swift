//
//  SupabaseService.swift
//  VoiceAgent
//
//  Created by Spectra Esports  on 9/6/26.
//

import Foundation
import Supabase

final class SupabaseService {
    static let client: SupabaseClient = SupabaseClient(
        supabaseURL: URL(string: "https://vcxwsuawqenaecvyvsnd.supabase.co")!,
        supabaseKey: "sb_publishable_Ublx3fS9Ip4-FonoUW29uA_uuoFvNxw",
        options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
    )
}
