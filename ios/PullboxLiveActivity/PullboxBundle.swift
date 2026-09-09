import WidgetKit
import SwiftUI

@main
struct PullboxLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.1, *) {
            PullboxLiveActivityWidget()
        }
    }
}
