//
//  RootView.swift
//  VoiceAgent
//
//  Created by Spectra Esports  on 9/6/26.
//

import SwiftUI
import Supabase
import Combine

@MainActor
final class RooViewModel: ObservableObject {
    
    @Published var userSession: UserSession = .idle
    
    func startListenAuthCHanges() async {
        for await (event, session) in SupabaseService.client.auth.authStateChanges {
            userSession = .init(event: event, session: session)
        }
    }
    
    func signIn() {
        Task {
            do {
                try await SupabaseService.client.auth.signIn(email: "test@test.com", password: "test")
            } catch {
                print(error.localizedDescription)
            }
        }
    }
}

struct RootView: View {

    @ObservedObject private var viewModel: RooViewModel = .init()
    
    var body: some View {
        ZStack {
            switch viewModel.userSession {
            case .authenticated:
                AppView()
            case .idle, .loading:
                Text(viewModel.userSession.description)
            case .unauthenticated:
                Button {
                    viewModel.signIn()
                } label: {
                    Text("Sign in")
                }
            }
        }
        .task {
            await viewModel.startListenAuthCHanges()
        }
    }
}
