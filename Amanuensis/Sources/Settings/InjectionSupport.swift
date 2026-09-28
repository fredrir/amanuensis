#if DEBUG
    import Combine
    import Foundation
    import InjectionLite

    enum InjectionSupport {
        static func bootstrap() {
            _ = InjectionLite.self
        }
    }

    final class InjectionObserver: ObservableObject, @unchecked Sendable {
        static let shared = InjectionObserver()

        @Published private(set) var counter = 0
        private var cancellable: AnyCancellable?

        private init() {
            cancellable = NotificationCenter.default
                .publisher(for: Notification.Name("INJECTION_BUNDLE_NOTIFICATION"))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.counter += 1
                }
        }
    }
#endif
