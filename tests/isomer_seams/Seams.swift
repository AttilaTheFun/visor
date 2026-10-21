// A call site of visor's pasteboard and camera seams, as visor's libraries
// write them (SwiftUI and the seams' modules only): the overrides must answer
// them unambiguously wherever Isomer's own modifier is visible too.

import Foundation
import SwiftUI
import VisorCamera
import VisorPasteboard

struct SeamsView: View {
    @State private var capturing = false
    @State private var photo: URL?

    var body: some View {
        Button("Copy") { Pasteboard.string = photo?.path ?? Pasteboard.string }
            .disabled(!Camera.available)
            .cameraCapture(isPresented: $capturing) { photo = $0 }
    }
}
