import Foundation

struct GitHubIssueReporter {
    private let owner: String
    private let repository: String
    private let configuration: IssueSubmissionConfiguration

    init(
        owner: String,
        repository: String,
        configuration: IssueSubmissionConfiguration = .current()
    ) {
        self.owner = owner
        self.repository = repository
        self.configuration = configuration
    }

    var repositoryName: String {
        "\(owner)/\(repository)"
    }

    func createIssue(title: String, body: String, context: IssueSubmissionContext) async throws -> GitHubIssue {
        guard let endpointURL = configuration.endpointURL else {
            throw GitHubIssueReporterError.missingSubmissionEndpoint
        }

        let payload = IssueSubmissionPayload(
            repository: repositoryName,
            title: title,
            body: body,
            pageURL: context.pageURL,
            pageTitle: context.pageTitle,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appName: "Quartz"
        )

        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 20
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Quartz", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubIssueReporterError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? JSONDecoder().decode(IssueSubmissionErrorResponse.self, from: data).message)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw GitHubIssueReporterError.submissionFailed(message: message, statusCode: httpResponse.statusCode)
        }

        return try JSONDecoder().decode(GitHubIssue.self, from: data)
    }
}

struct IssueSubmissionConfiguration {
    let endpointURL: URL?

    static func current() -> IssueSubmissionConfiguration {
        let configuredURLString = [
            UserDefaults.standard.string(forKey: "QuartzIssueSubmissionURL"),
            ProcessInfo.processInfo.environment["QUARTZ_ISSUE_SUBMISSION_URL"],
            Bundle.main.object(forInfoDictionaryKey: "QuartzIssueSubmissionURL") as? String
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }

        return IssueSubmissionConfiguration(endpointURL: configuredURLString.flatMap(endpointURL(from:)))
    }

    private static func endpointURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil
        else {
            return nil
        }

        return url
    }
}

struct IssueSubmissionContext {
    let pageURL: String?
    let pageTitle: String?
}

struct GitHubIssue: Decodable {
    let number: Int
    let htmlURL: URL

    private enum CodingKeys: String, CodingKey {
        case number
        case htmlURL = "html_url"
        case url
    }

    init(number: Int, htmlURL: URL) {
        self.number = number
        self.htmlURL = htmlURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)

        let urlString = try container.decodeIfPresent(String.self, forKey: .htmlURL)
            ?? container.decode(String.self, forKey: .url)

        guard let url = URL(string: urlString) else {
            throw GitHubIssueReporterError.invalidIssueURL
        }

        htmlURL = url
    }
}

private struct IssueSubmissionPayload: Encodable {
    let repository: String
    let title: String
    let body: String
    let pageURL: String?
    let pageTitle: String?
    let operatingSystem: String
    let appName: String
}

private struct IssueSubmissionErrorResponse: Decodable {
    let message: String
}

private enum GitHubIssueReporterError: LocalizedError {
    case missingSubmissionEndpoint
    case invalidResponse
    case invalidIssueURL
    case submissionFailed(message: String, statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .missingSubmissionEndpoint:
            "Quartz issue submission is not configured. Set QuartzIssueSubmissionURL in the app bundle or QUARTZ_ISSUE_SUBMISSION_URL when running locally."
        case .invalidResponse:
            "The issue submission service did not return a valid HTTP response."
        case .invalidIssueURL:
            "The issue was submitted, but Quartz could not read its GitHub URL."
        case .submissionFailed(let message, let statusCode):
            "The issue submission service returned \(statusCode): \(message)"
        }
    }
}
