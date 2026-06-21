import Foundation
import Darwin
@preconcurrency import WebKit

struct UBlockOriginContentBlockerStatus {
    let version: String
    let ruleCount: Int
    let blockRuleCount: Int
    let exceptionRuleCount: Int
    let parsedLineCount: Int
    let skippedLineCount: Int
    let sourceFileCount: Int
    let usedCachedRuleList: Bool

    var summary: String {
        let cacheText = usedCachedRuleList ? "cached" : "compiled"
        return "uBlock Origin \(version) active: \(ruleCount) \(cacheText) WebKit rules from \(sourceFileCount) bundled lists."
    }
}

@MainActor
final class UBlockOriginContentBlocker {
    static let version = "1.71.0"
    static let releaseURL = URL(string: "https://github.com/gorhill/uBlock/releases/tag/1.71.0")!

    private static let ruleListIdentifier = "org.quartz.uBlockOrigin.1.71.0.webkit-subset.3"

    private let userContentController: WKUserContentController
    private let store: WKContentRuleListStore

    init(
        userContentController: WKUserContentController,
        store: WKContentRuleListStore = WKContentRuleListStore.default()
    ) {
        self.userContentController = userContentController
        self.store = store
    }

    func install(completion: @escaping (Result<UBlockOriginContentBlockerStatus, Error>) -> Void) {
        let compiledRules: CompiledUBlockOriginRules

        do {
            compiledRules = try UBlockOriginRuleCompiler().makeContentRuleList()
        } catch {
            DispatchQueue.main.async {
                completion(.failure(error))
            }
            return
        }

        print("uBlock Origin \(Self.version): prepared \(compiledRules.ruleCount) WebKit content rules from \(compiledRules.sourceFileCount) bundled lists.")

        store.lookUpContentRuleList(forIdentifier: Self.ruleListIdentifier) { [weak self] existingRuleList, _ in
            guard let self else {
                return
            }

            if let existingRuleList {
                self.install(
                    existingRuleList,
                    compiledRules: compiledRules,
                    usedCachedRuleList: true,
                    completion: completion
                )
                return
            }

            self.store.compileContentRuleList(
                forIdentifier: Self.ruleListIdentifier,
                encodedContentRuleList: compiledRules.encodedRuleList
            ) { [weak self] ruleList, error in
                guard let self else {
                    return
                }

                if let error {
                    DispatchQueue.main.async {
                        completion(.failure(error))
                    }
                    return
                }

                guard let ruleList else {
                    DispatchQueue.main.async {
                        completion(.failure(UBlockOriginContentBlockerError.compilationProducedNoRuleList))
                    }
                    return
                }

                self.install(
                    ruleList,
                    compiledRules: compiledRules,
                    usedCachedRuleList: false,
                    completion: completion
                )
            }
        }
    }

    private func install(
        _ ruleList: WKContentRuleList,
        compiledRules: CompiledUBlockOriginRules,
        usedCachedRuleList: Bool,
        completion: @escaping (Result<UBlockOriginContentBlockerStatus, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            self.userContentController.add(ruleList)
            completion(.success(UBlockOriginContentBlockerStatus(
                version: Self.version,
                ruleCount: compiledRules.ruleCount,
                blockRuleCount: compiledRules.blockRuleCount,
                exceptionRuleCount: compiledRules.exceptionRuleCount,
                parsedLineCount: compiledRules.parsedLineCount,
                skippedLineCount: compiledRules.skippedLineCount,
                sourceFileCount: compiledRules.sourceFileCount,
                usedCachedRuleList: usedCachedRuleList
            )))
        }
    }
}

@MainActor
enum UBlockOriginContentBlockerValidator {
    static func runAndExit() -> Never {
        do {
            let compiledRules = try UBlockOriginRuleCompiler().makeContentRuleList()
            let identifier = "org.quartz.uBlockOrigin.validation.\(UUID().uuidString)"
            print("uBlock Origin \(UBlockOriginContentBlocker.version): validating \(compiledRules.ruleCount) WebKit content rules.")

            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: compiledRules.encodedRuleList
            ) { _, error in
                if let error {
                    print("uBlock Origin validation failed: \(error.localizedDescription)")
                    exit(1)
                }

                print("uBlock Origin validation succeeded.")
                exit(0)
            }

            RunLoop.main.run()
            fatalError("uBlock Origin validation run loop exited unexpectedly.")
        } catch {
            print("uBlock Origin validation failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}

private struct CompiledUBlockOriginRules {
    let encodedRuleList: String
    let ruleCount: Int
    let blockRuleCount: Int
    let exceptionRuleCount: Int
    let parsedLineCount: Int
    let skippedLineCount: Int
    let sourceFileCount: Int
}

private enum UBlockOriginContentBlockerError: LocalizedError {
    case missingBundledResource(String)
    case compilationProducedNoRuleList

    var errorDescription: String? {
        switch self {
        case .missingBundledResource(let path):
            "Missing bundled uBlock Origin resource: \(path)"
        case .compilationProducedNoRuleList:
            "WebKit did not return a compiled content rule list."
        }
    }
}

private struct UBlockOriginRuleCompiler {
    private let filterPaths = [
        "uBlockOrigin/assets/ublock/filters.min.txt",
        "uBlockOrigin/assets/ublock/privacy.min.txt",
        "uBlockOrigin/assets/ublock/badware.min.txt",
        "uBlockOrigin/assets/ublock/quick-fixes.min.txt",
        "uBlockOrigin/assets/ublock/unbreak.min.txt",
        "uBlockOrigin/assets/thirdparties/easylist/easylist.txt",
        "uBlockOrigin/assets/thirdparties/easylist/easyprivacy.txt",
        "uBlockOrigin/assets/thirdparties/urlhaus-filter/urlhaus-filter-online.txt"
    ]

    func makeContentRuleList() throws -> CompiledUBlockOriginRules {
        var blockRules = [WebKitContentRule]()
        var exceptionRules = [WebKitContentRule]()
        var seenRules = Set<String>()
        var parsedLineCount = 0
        var skippedLineCount = 0

        for path in filterPaths {
            let text = try loadBundledText(at: path)
            text.enumerateLines { line, _ in
                parsedLineCount += 1

                guard let parsedRule = UBlockOriginFilterParser.parse(line) else {
                    skippedLineCount += 1
                    return
                }

                guard seenRules.insert(parsedRule.rule.signature).inserted else {
                    skippedLineCount += 1
                    return
                }

                if parsedRule.isException {
                    exceptionRules.append(parsedRule.rule)
                } else {
                    blockRules.append(parsedRule.rule)
                }
            }
        }

        let rules = blockRules + exceptionRules
        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(rules)

        return CompiledUBlockOriginRules(
            encodedRuleList: String(decoding: encodedData, as: UTF8.self),
            ruleCount: rules.count,
            blockRuleCount: blockRules.count,
            exceptionRuleCount: exceptionRules.count,
            parsedLineCount: parsedLineCount,
            skippedLineCount: skippedLineCount,
            sourceFileCount: filterPaths.count
        )
    }

    private func loadBundledText(at path: String) throws -> String {
        guard let resourceRootURL = Bundle.module.resourceURL else {
            throw UBlockOriginContentBlockerError.missingBundledResource(path)
        }

        let pathPreservingURL = resourceRootURL.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: pathPreservingURL.path) {
            return try String(contentsOf: pathPreservingURL, encoding: .utf8)
        }

        let sourceURL = URL(fileURLWithPath: path)
        let resourceName = sourceURL.deletingPathExtension().lastPathComponent
        let resourceExtension = sourceURL.pathExtension

        if let processedURL = Bundle.module.url(forResource: resourceName, withExtension: resourceExtension),
           FileManager.default.fileExists(atPath: processedURL.path) {
            return try String(contentsOf: processedURL, encoding: .utf8)
        }

        throw UBlockOriginContentBlockerError.missingBundledResource(path)
    }
}

private struct ParsedUBlockOriginRule {
    let rule: WebKitContentRule
    let isException: Bool
}

private enum UBlockOriginFilterParser {
    private static let cosmeticMarkers = [
        "##",
        "#@#",
        "#?#",
        "#@?#",
        "#$#",
        "#%#"
    ]

    static func parse(_ rawLine: String) -> ParsedUBlockOriginRule? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        guard line.isEmpty == false,
              line.hasPrefix("!") == false,
              line.hasPrefix("[") == false else {
            return nil
        }

        guard cosmeticMarkers.contains(where: { line.contains($0) }) == false else {
            return nil
        }

        let isException = line.hasPrefix("@@")
        if isException {
            line.removeFirst(2)
        }

        guard line.isEmpty == false,
              line.hasPrefix("/") == false || line.hasSuffix("/") == false else {
            return nil
        }

        let splitLine = splitFilter(line)
        let pattern = splitLine.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pattern.isEmpty == false else {
            return nil
        }

        let options = UBlockOriginFilterOptions(rawOptions: splitLine.options)
        guard options.shouldSkip == false,
              let urlFilter = makeURLFilter(from: pattern),
              isValidRegularExpression(urlFilter) else {
            return nil
        }

        let trigger = WebKitContentRuleTrigger(
            urlFilter: urlFilter,
            resourceType: options.resourceTypes,
            loadType: options.loadTypes,
            ifDomain: options.ifDomains,
            unlessDomain: options.unlessDomains,
            urlFilterIsCaseSensitive: options.isCaseSensitive ? true : nil
        )
        let action = WebKitContentRuleAction(type: isException ? "ignore-previous-rules" : "block")

        return ParsedUBlockOriginRule(
            rule: WebKitContentRule(trigger: trigger, action: action),
            isException: isException
        )
    }

    private static func splitFilter(_ line: String) -> (pattern: String, options: String?) {
        guard let optionStart = line.firstIndex(of: "$") else {
            return (line, nil)
        }

        return (
            String(line[..<optionStart]),
            String(line[line.index(after: optionStart)...])
        )
    }

    private static func makeURLFilter(from pattern: String) -> String? {
        var workingPattern = pattern
        var anchorsAtEnd = false

        if workingPattern.hasSuffix("|") {
            anchorsAtEnd = true
            workingPattern.removeLast()
        }

        if workingPattern.hasPrefix("||") {
            return makeDomainAnchoredURLFilter(from: String(workingPattern.dropFirst(2)), anchorsAtEnd: anchorsAtEnd)
        }

        var anchorsAtStart = false
        if workingPattern.hasPrefix("|") {
            anchorsAtStart = true
            workingPattern.removeFirst()
        }

        guard let regex = makePatternRegex(from: workingPattern) else {
            return nil
        }

        let prefix = anchorsAtStart ? "^" : ".*"
        let suffix = anchorsAtEnd ? "$" : ".*"
        return prefix + regex + suffix
    }

    private static func makeDomainAnchoredURLFilter(from pattern: String, anchorsAtEnd: Bool) -> String? {
        let hostEnd = pattern.firstIndex { character in
            isHostPatternCharacter(character) == false
        } ?? pattern.endIndex

        let hostPattern = String(pattern[..<hostEnd])
        guard hostPattern.isEmpty == false,
              hostPattern.contains("."),
              hostPattern.contains("..") == false,
              let hostRegex = makeHostRegex(from: hostPattern) else {
            return nil
        }

        let remainder = String(pattern[hostEnd...])
        let remainderRegex: String

        if remainder.isEmpty {
            remainderRegex = "[/:?#]"
        } else {
            guard let regex = makePatternRegex(from: remainder) else {
                return nil
            }
            remainderRegex = regex
        }

        let suffix = anchorsAtEnd ? "$" : ".*"
        return "^[a-z][a-z0-9+.-]*://([^/?#]+\\.)?" + hostRegex + remainderRegex + suffix
    }

    private static func makeHostRegex(from hostPattern: String) -> String? {
        var regex = ""

        for character in hostPattern {
            switch character {
            case "*":
                regex += "[^/?#]*"
            case ".":
                regex += "\\."
            case "-", "_":
                regex.append(character)
            default:
                guard character.isASCII && (character.isLetter || character.isNumber) else {
                    return nil
                }
                regex.append(character.lowercased())
            }
        }

        return regex
    }

    private static func makePatternRegex(from pattern: String) -> String? {
        guard pattern.isEmpty == false, pattern != "*" else {
            return nil
        }

        var regex = ""
        for character in pattern {
            switch character {
            case "*":
                regex += ".*"
            case "^":
                regex += "[^A-Za-z0-9_.%-]"
            default:
                guard character.isASCII else {
                    return nil
                }
                regex += escapedRegularExpressionCharacter(character)
            }
        }

        guard regex.count <= 1_500 else {
            return nil
        }

        return regex
    }

    private static func escapedRegularExpressionCharacter(_ character: Character) -> String {
        let text = String(character)
        if #"[]{}()+?.\|$"#.contains(character) {
            return "\\" + text
        }
        return text
    }

    private static func isHostPatternCharacter(_ character: Character) -> Bool {
        character.isASCII && (
            character.isLetter ||
            character.isNumber ||
            character == "." ||
            character == "-" ||
            character == "_" ||
            character == "*"
        )
    }

    private static func isValidRegularExpression(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }
}

private struct UBlockOriginFilterOptions {
    private static let allWebKitResourceTypes: Set<String> = [
        "document",
        "image",
        "style-sheet",
        "script",
        "font",
        "raw",
        "svg-document",
        "media",
        "popup"
    ]

    private static let resourceTypeMap: [String: Set<String>] = [
        "document": ["document"],
        "doc": ["document"],
        "subdocument": ["document"],
        "frame": ["document"],
        "image": ["image"],
        "img": ["image"],
        "stylesheet": ["style-sheet"],
        "css": ["style-sheet"],
        "script": ["script"],
        "font": ["font"],
        "media": ["media"],
        "object": ["raw"],
        "xmlhttprequest": ["raw"],
        "xhr": ["raw"],
        "fetch": ["raw"],
        "ping": ["raw"],
        "websocket": ["raw"],
        "other": ["raw"],
        "popup": ["popup"]
    ]

    private static let skipOptionPrefixes = [
        "badfilter",
        "cname",
        "csp",
        "denyallow",
        "permissions",
        "removeparam",
        "replace",
        "queryprune",
        "uritransform",
        "urlskip",
        "header",
        "requestheader",
        "responseheader",
        "from",
        "ghide",
        "ehide",
        "shide",
        "generichide",
        "genericblock",
        "elemhide",
        "specifichide",
        "jsinject",
        "ipaddress",
        "method",
        "webrtc",
        "popunder",
        "strict1p",
        "strict3p",
        "to",
        "top",
        "empty"
    ]

    let resourceTypes: [String]?
    let loadTypes: [String]?
    let ifDomains: [String]?
    let unlessDomains: [String]?
    let isCaseSensitive: Bool
    let shouldSkip: Bool

    init(rawOptions: String?) {
        var parsedResourceTypes = Set<String>()
        var hasResourceTypeConstraint = false
        var parsedLoadTypes = Set<String>()
        var parsedIfDomains = Set<String>()
        var parsedUnlessDomains = Set<String>()
        var parsedIsCaseSensitive = false
        var parsedShouldSkip = false

        if let rawOptions {
            for rawOption in rawOptions.split(separator: ",") {
                let optionText = rawOption.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard optionText.isEmpty == false else {
                    continue
                }

                let isNegated = optionText.hasPrefix("~")
                let normalizedOption = isNegated ? String(optionText.dropFirst()) : optionText
                let optionParts = normalizedOption.split(separator: "=", maxSplits: 1).map(String.init)
                let optionName = optionParts[0]
                let optionValue = optionParts.count > 1 ? optionParts[1] : nil

                if Self.skipOptionPrefixes.contains(where: { optionName == $0 || optionName.hasPrefix($0 + "=") }) {
                    parsedShouldSkip = true
                    continue
                }

                if optionName == "important" || optionName == "all" {
                    continue
                }

                if optionName == "match-case" {
                    parsedIsCaseSensitive = true
                    continue
                }

                if optionName == "third-party" || optionName == "3p" {
                    parsedLoadTypes.insert(isNegated ? "first-party" : "third-party")
                    continue
                }

                if optionName == "first-party" || optionName == "1p" {
                    parsedLoadTypes.insert(isNegated ? "third-party" : "first-party")
                    continue
                }

                if optionName == "domain" {
                    guard isNegated == false, let optionValue else {
                        parsedShouldSkip = true
                        continue
                    }
                    let domains = Self.parseDomainOption(optionValue)
                    // Dropping unsupported domains would widen a scoped filter into a global one.
                    guard domains.containsUnsupportedDomain == false else {
                        parsedShouldSkip = true
                        continue
                    }
                    parsedIfDomains.formUnion(domains.ifDomains)
                    parsedUnlessDomains.formUnion(domains.unlessDomains)
                    continue
                }

                if optionName == "redirect" || optionName == "redirect-rule" {
                    continue
                }

                if let mappedResourceTypes = Self.resourceTypeMap[optionName] {
                    hasResourceTypeConstraint = true
                    if isNegated {
                        if parsedResourceTypes.isEmpty {
                            parsedResourceTypes = Self.allWebKitResourceTypes
                        }
                        parsedResourceTypes.subtract(mappedResourceTypes)
                    } else {
                        parsedResourceTypes.formUnion(mappedResourceTypes)
                    }
                    continue
                }

                parsedShouldSkip = true
            }
        }

        if parsedResourceTypes == Self.allWebKitResourceTypes {
            hasResourceTypeConstraint = false
            parsedResourceTypes.removeAll()
        }

        if parsedIfDomains.isEmpty == false && parsedUnlessDomains.isEmpty == false {
            parsedShouldSkip = true
        }

        resourceTypes = hasResourceTypeConstraint && parsedResourceTypes.isEmpty == false
            ? parsedResourceTypes.sorted()
            : nil
        loadTypes = parsedLoadTypes.isEmpty ? nil : parsedLoadTypes.sorted()
        ifDomains = parsedIfDomains.isEmpty ? nil : parsedIfDomains.sorted()
        unlessDomains = parsedUnlessDomains.isEmpty ? nil : parsedUnlessDomains.sorted()
        isCaseSensitive = parsedIsCaseSensitive
        shouldSkip = parsedShouldSkip
    }

    private static func parseDomainOption(_ optionValue: String) -> (
        ifDomains: Set<String>,
        unlessDomains: Set<String>,
        containsUnsupportedDomain: Bool
    ) {
        var ifDomains = Set<String>()
        var unlessDomains = Set<String>()
        var containsUnsupportedDomain = false

        for rawDomain in optionValue.split(separator: "|") {
            let domainText = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard domainText.isEmpty == false else {
                continue
            }

            let isNegated = domainText.hasPrefix("~")
            let domain = isNegated ? String(domainText.dropFirst()) : domainText
            guard let webKitDomain = makeWebKitDomainCondition(from: domain) else {
                containsUnsupportedDomain = true
                continue
            }

            if isNegated {
                unlessDomains.insert(webKitDomain)
            } else {
                ifDomains.insert(webKitDomain)
            }
        }

        return (ifDomains, unlessDomains, containsUnsupportedDomain)
    }

    private static func makeWebKitDomainCondition(from domain: String) -> String? {
        var normalizedDomain = domain.lowercased()

        if normalizedDomain.hasPrefix("*.") {
            normalizedDomain.removeFirst(2)
        }

        guard normalizedDomain.isEmpty == false,
              normalizedDomain.contains("*") == false,
              normalizedDomain.contains("/") == false,
              normalizedDomain.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else {
            return nil
        }

        return "*" + normalizedDomain
    }
}

private struct WebKitContentRule: Encodable {
    let trigger: WebKitContentRuleTrigger
    let action: WebKitContentRuleAction

    var signature: String {
        [
            trigger.signature,
            action.type,
            action.selector ?? ""
        ].joined(separator: "|")
    }
}

private struct WebKitContentRuleTrigger: Encodable {
    let urlFilter: String
    let resourceType: [String]?
    let loadType: [String]?
    let ifDomain: [String]?
    let unlessDomain: [String]?
    let urlFilterIsCaseSensitive: Bool?

    enum CodingKeys: String, CodingKey {
        case urlFilter = "url-filter"
        case resourceType = "resource-type"
        case loadType = "load-type"
        case ifDomain = "if-domain"
        case unlessDomain = "unless-domain"
        case urlFilterIsCaseSensitive = "url-filter-is-case-sensitive"
    }

    var signature: String {
        let resourceTypeSignature = resourceType?.joined(separator: ",") ?? ""
        let loadTypeSignature = loadType?.joined(separator: ",") ?? ""
        let ifDomainSignature = ifDomain?.joined(separator: ",") ?? ""
        let unlessDomainSignature = unlessDomain?.joined(separator: ",") ?? ""
        let caseSensitivitySignature = urlFilterIsCaseSensitive.map(String.init) ?? ""

        return [
            urlFilter,
            resourceTypeSignature,
            loadTypeSignature,
            ifDomainSignature,
            unlessDomainSignature,
            caseSensitivitySignature
        ].joined(separator: "|")
    }
}

private struct WebKitContentRuleAction: Encodable {
    let type: String
    let selector: String?

    init(type: String, selector: String? = nil) {
        self.type = type
        self.selector = selector
    }
}
