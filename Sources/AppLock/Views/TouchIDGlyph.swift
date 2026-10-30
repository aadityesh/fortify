import LocalAuthentication
import LocalAuthenticationEmbeddedUI
import SwiftUI

/// Apple's inline Touch ID glyph. While it's on screen, Touch ID requests from
/// `session` show here instead of in the system "… is trying to unlock" dialog.
struct TouchIDGlyph: View {
    let session: BiometricSession
    var controlSize: NSControl.ControlSize = .small

    var body: some View {
        if let context = session.context {
            // LAAuthenticationView has no intrinsic size, so it needs an explicit,
            // square frame; at 0×0 LocalAuthentication cancels the request.
            Representable(session: session, laContext: context, controlSize: controlSize)
                .frame(width: side, height: side)
                .id(ObjectIdentifier(context))
        }
    }

    private var side: CGFloat {
        switch controlSize {
        case .mini: 18
        case .small: 24
        case .large, .extraLarge: 44
        default: 32
        }
    }

    private struct Representable: NSViewRepresentable {
        let session: BiometricSession
        let laContext: LAContext
        let controlSize: NSControl.ControlSize

        func makeNSView(context: Context) -> MountAwareAuthView {
            let view = MountAwareAuthView(context: laContext, controlSize: controlSize)
            view.onMount = { [session, laContext] in session.glyphMounted(for: laContext) }
            return view
        }

        func updateNSView(_ nsView: MountAwareAuthView, context: Context) {}
    }
}

/// Reports when the glyph is in a window *and* laid out at a usable size.
/// LocalAuthentication permanently cancels a request if its view is ever laid
/// out at zero size ("View did layout with invalid dimensions"), so evaluation
/// must not start before that.
final class MountAwareAuthView: LAAuthenticationView {
    var onMount: (() -> Void)?

    override func layout() {
        super.layout()
        guard window != nil, bounds.width >= 16, bounds.height >= 16, let onMount else { return }
        self.onMount = nil
        DispatchQueue.main.async(execute: onMount)
    }
}
