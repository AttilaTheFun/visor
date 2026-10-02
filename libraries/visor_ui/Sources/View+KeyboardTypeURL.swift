import SwiftUI
import VisorClient
import VisorProtocol

extension View {
    /// The URL keyboard on a phone; nothing elsewhere.
    @ViewBuilder func keyboardTypeURL() -> some View {
        #if os(iOS)
        keyboardType(.URL).textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}
