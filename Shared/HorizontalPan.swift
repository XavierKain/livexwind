import SwiftUI
#if canImport(UIKit)
import UIKit

/// Zone de saisie qui ne réagit qu'aux glissements horizontaux.
///
/// Posée sur le graphe à l'intérieur d'une `ScrollView`, elle laisse passer le
/// défilement vertical : le reconnaisseur refuse de démarrer quand le doigt part
/// vers le haut ou le bas, donc la `ScrollView` garde la main sans compétition.
/// `simultaneousGesture` ne suffit pas ici — une fois qu'un `DragGesture` SwiftUI
/// a commencé, il retient le toucher.
struct HorizontalPanArea: UIViewRepresentable {
    /// Position du doigt, dans le repère de la zone.
    var onChange: (CGPoint) -> Void
    var onEnd: () -> Void = {}

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handle(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.onEnd = onEnd
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange, onEnd: onEnd)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: (CGPoint) -> Void
        var onEnd: () -> Void

        init(onChange: @escaping (CGPoint) -> Void, onEnd: @escaping () -> Void) {
            self.onChange = onChange
            self.onEnd = onEnd
        }

        /// Appelé juste avant que le geste ne démarre : c'est là qu'on tranche.
        /// On penche du côté du défilement — il faut un geste franchement
        /// horizontal pour prendre la main sur le graphe.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handle(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began, .changed:
                onChange(pan.location(in: pan.view))
            case .ended, .cancelled, .failed:
                onEnd()
            default:
                break
            }
        }
    }
}
#endif
