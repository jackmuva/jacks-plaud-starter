import UIKit

extension UIView {
    /// Horizontal shake animation (for input validation failure feedback)
    func shake() {
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.duration = 0.4
        anim.values = [-10, 10, -8, 8, -5, 5, 0]
        layer.add(anim, forKey: "shake")
    }
}
