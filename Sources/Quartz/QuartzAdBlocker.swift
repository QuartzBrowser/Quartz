import Foundation
import WebKit

@MainActor
final class QuartzAdBlocker {
    private static let enabledDefaultsKey = "QuartzBuiltInAdBlockerEnabled"
    private static let ruleListIdentifier = "QuartzBasicAdBlocker"

    private let ruleListStore = WKContentRuleListStore.default()
    private weak var userContentController: WKUserContentController?
    private var contentRuleList: WKContentRuleList?

    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            return true
        }

        return UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func connect(to userContentController: WKUserContentController) {
        self.userContentController = userContentController
    }

    func prepare(completion: @escaping (Result<Void, Error>) -> Void) {
        guard isEnabled else {
            completion(.success(()))
            return
        }

        install(completion: completion)
    }

    func setEnabled(_ isEnabled: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard isEnabled else {
            disable()
            completion(.success(()))
            return
        }

        install { result in
            switch result {
            case .success:
                UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
            case .failure:
                self.disable()
            }

            completion(result)
        }
    }

    func disable() {
        UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
        remove()
    }

    private func install(completion: @escaping (Result<Void, Error>) -> Void) {
        guard let userContentController else {
            completion(.failure(QuartzAdBlockerError.missingUserContentController))
            return
        }

        if let contentRuleList {
            userContentController.remove(contentRuleList)
            userContentController.add(contentRuleList)
            completion(.success(()))
            return
        }

        guard let ruleListStore else {
            completion(.failure(QuartzAdBlockerError.contentRuleListStoreUnavailable))
            return
        }

        ruleListStore.compileContentRuleList(
            forIdentifier: Self.ruleListIdentifier,
            encodedContentRuleList: Self.ruleListJSON
        ) { [weak self] contentRuleList, error in
            Task { @MainActor in
                guard let self else {
                    return
                }

                if let error {
                    completion(.failure(error))
                    return
                }

                guard let contentRuleList else {
                    completion(.failure(QuartzAdBlockerError.compiledRuleListUnavailable))
                    return
                }

                self.contentRuleList = contentRuleList
                userContentController.add(contentRuleList)
                completion(.success(()))
            }
        }
    }

    private func remove() {
        guard let contentRuleList else {
            return
        }

        userContentController?.remove(contentRuleList)
    }

    private static let ruleListJSON = #"""
    [
      {
        "trigger": {
          "url-filter": ".*://([^/]+\\.)?doubleclick\\.net/.*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*://([^/]+\\.)?googlesyndication\\.com/.*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*://([^/]+\\.)?googleadservices\\.com/.*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*://([^/]+\\.)?adservice\\.google\\.[^/]+/.*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*://([^/]+\\.)?adnxs\\.com/.*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*://([^/]+\\.)?amazon-adsystem\\.com/.*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*://([^/]+\\.)?taboola\\.com/.*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*://([^/]+\\.)?outbrain\\.com/.*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*[./_-]ad[./_-].*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*[./_-]ads[./_-].*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*[./_-]advert[./_-].*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*[./_-]banner[./_-].*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*[./_-]sponsor[./_-].*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*[./_-]sponsored[./_-].*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*[./_-]promoted[./_-].*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      },
      {
        "trigger": {
          "url-filter": ".*[./_-]prebid[./_-].*",
          "resource-type": ["image", "script", "style-sheet", "raw"],
          "load-type": ["third-party"]
        },
        "action": { "type": "block" }
      }
    ]
    """#
}

private enum QuartzAdBlockerError: LocalizedError {
    case missingUserContentController
    case contentRuleListStoreUnavailable
    case compiledRuleListUnavailable

    var errorDescription: String? {
        switch self {
        case .missingUserContentController:
            "Quartz could not attach the built-in ad blocker to this browser window."
        case .contentRuleListStoreUnavailable:
            "WebKit content blocking is unavailable on this system."
        case .compiledRuleListUnavailable:
            "WebKit did not return a compiled ad-blocking rule list."
        }
    }
}
