//
//  HubApi.swift
//
//
//  Created by Pedro Cuenca on 20231230.
//

import Foundation

public struct HubApi {
    let endpoint = "https://huggingface.co/api"
    var downloadBase: URL
    var hfToken: String? = nil
    
    public typealias RepoType = Hub.RepoType
    public typealias Repo = Hub.Repo
    
    public init(downloadBase: URL? = nil, hfToken: String? = nil) {
        if downloadBase == nil {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.downloadBase = documents.appending(component: "huggingface")
        } else {
            self.downloadBase = downloadBase!
        }
        self.hfToken = hfToken
    }
    
    static let shared = HubApi()
}

/// File retrieval
public extension HubApi {
    /// Model data for parsed filenames
    struct Sibling: Codable {
        let rfilename: String
    }
    
    struct SiblingsResponse: Codable {
        let siblings: [Sibling]
    }
        
    /// Throws error if the response code is not 20X
    func httpGet(for url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        if let hfToken = hfToken {
            request.setValue("Bearer \(hfToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Hub.HubClientError.unexpectedError }
        
        switch response.statusCode {
        case 200..<300: break
        case 400..<500: throw Hub.HubClientError.authorizationRequired
        default       : throw Hub.HubClientError.httpStatusCode(response.statusCode)
        }

        return (data, response)
    }
    
    func getFilenames(from repo: Repo, matching globs: [String] = []) async throws -> [String] {
        // Read repo info and only parse "siblings"
        let url = URL(string: "\(endpoint)/\(repo.type)/\(repo.id)")!
        let (data, _) = try await httpGet(for: url)
        let response = try JSONDecoder().decode(SiblingsResponse.self, from: data)
        let filenames = response.siblings.map { $0.rfilename }
        guard globs.count > 0 else { return filenames }
        
        var selected: Set<String> = []
        for glob in globs {
            selected = selected.union(filenames.matching(glob: glob))
        }
        return Array(selected)
    }
    
    func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await getFilenames(from: Repo(id: repoId), matching: globs)
    }
    
    func getFilenames(from repo: Repo, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: repo, matching: [glob])
    }
    
    func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await getFilenames(from: Repo(id: repoId), matching: [glob])
    }
}

/// Configuration loading helpers
public extension HubApi {
    /// Assumes the file has already been downloaded.
    /// `filename` is relative to the download base.
    func configuration(from filename: String, in repo: Repo) throws -> Config {
        let url = localRepoLocation(repo).appending(path: filename)
        let data = try Data(contentsOf: url)
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [String: Any] else { throw Hub.HubClientError.parse }
        return Config(dictionary)
    }
}

/// Whoami
public extension HubApi {
    func whoami() async throws -> Config {
        guard hfToken != nil else { throw Hub.HubClientError.authorizationRequired }
        
        let url = URL(string: "\(endpoint)/whoami-v2")!
        let (data, _) = try await httpGet(for: url)

        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = parsed as? [String: Any] else { throw Hub.HubClientError.parse }
        return Config(dictionary)
    }
}

/// Snaphsot download
public extension HubApi {
    func localRepoLocation(_ repo: Repo) -> URL {
        downloadBase.appending(component: repo.type.rawValue).appending(component: repo.id)
    }
    
    struct HubFileDownloader {
        let repo: Repo
        let repoDestination: URL
        let relativeFilename: String
        let hfToken: String?
        
        var source: URL {
            // https://huggingface.co/coreml-projects/Llama-2-7b-chat-coreml/resolve/main/tokenizer.json?download=true
            var url = URL(string: "https://huggingface.co")!
            if repo.type != .models {
                url = url.appending(component: repo.type.rawValue)
            }
            url = url.appending(path: repo.id)
            url = url.appending(path: "resolve/main")  // TODO: revisions
            url = url.appending(path: relativeFilename)
            return url
        }
        
        var destination: URL {
            repoDestination.appending(path: relativeFilename)
        }
        
        var downloaded: Bool {
            FileManager.default.fileExists(atPath: destination.path)
        }
        
        func prepareDestination() throws {
            let directoryURL = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        }

        // Note we go from Combine in Downloader to callback-based progress reporting
        // We'll probably need to support Combine as well to play well with Swift UI
        // (See for example PipelineLoader in swift-coreml-diffusers)
        @discardableResult
        func download(progressHandler: @escaping (Double) -> Void) async throws -> URL {
            guard !downloaded else { return destination }
            
            try prepareDestination()
            let downloader = Downloader(from: source, to: destination, using: hfToken)
            let downloadSubscriber = downloader.downloadState.sink { state in
                if case .downloading(let progress) = state {
                    progressHandler(progress)
                }
            }
            // We need to assign the cancellable to a var so we keep receiving events, so we suppress the "unused var" warning here
            let _ = downloadSubscriber
            try downloader.waitUntilDone()
            return destination
        }
    }
    
    @discardableResult
    func snapshot(from repo: Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        let filenames = try await getFilenames(from: repo, matching: globs)
        let progress = Progress(totalUnitCount: Int64(filenames.count))
        let repoDestination = localRepoLocation(repo)
        for filename in filenames {
            let fileProgress = Progress(totalUnitCount: 100, parent: progress, pendingUnitCount: 1)
            let downloader = HubFileDownloader(repo: repo, repoDestination: repoDestination, relativeFilename: filename, hfToken: hfToken)
            try await downloader.download { fractionDownloaded in
                fileProgress.completedUnitCount = Int64(100 * fractionDownloaded)
                progressHandler(progress)
            }
            fileProgress.completedUnitCount = 100
        }
        progressHandler(progress)
        return repoDestination
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Repo(id: repoId), matching: globs, progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repo: Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: repo, matching: [glob], progressHandler: progressHandler)
    }
    
    @discardableResult
    func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await snapshot(from: Repo(id: repoId), matching: [glob], progressHandler: progressHandler)
    }
}

/// Stateless wrappers that use `HubApi` instances
public extension Hub {
    static func getFilenames(from repo: Hub.Repo, matching globs: [String] = []) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: repo, matching: globs)
    }
    
    static func getFilenames(from repoId: String, matching globs: [String] = []) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: Repo(id: repoId), matching: globs)
    }
    
    static func getFilenames(from repo: Repo, matching glob: String) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: repo, matching: glob)
    }
    
    static func getFilenames(from repoId: String, matching glob: String) async throws -> [String] {
        return try await HubApi.shared.getFilenames(from: Repo(id: repoId), matching: glob)
    }
    
    static func snapshot(from repo: Repo, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: repo, matching: globs, progressHandler: progressHandler)
    }
    
    static func snapshot(from repoId: String, matching globs: [String] = [], progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: Repo(id: repoId), matching: globs, progressHandler: progressHandler)
    }
    
    static func snapshot(from repo: Repo, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: repo, matching: glob, progressHandler: progressHandler)
    }
    
    static func snapshot(from repoId: String, matching glob: String, progressHandler: @escaping (Progress) -> Void = { _ in }) async throws -> URL {
        return try await HubApi.shared.snapshot(from: Repo(id: repoId), matching: glob, progressHandler: progressHandler)
    }
    
    static func whoami(token: String) async throws -> Config {
        return try await HubApi(hfToken: token).whoami()
    }
}

public extension Array<String> {
    func matching(glob: String) -> [String] {
        self.filter { fnmatch(glob, $0, 0) == 0 }
    }
}

