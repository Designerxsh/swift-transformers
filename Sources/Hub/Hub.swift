//
//  Hub.swift
//  
//
//  Created by Pedro Cuenca on 18/5/23.
//

import Foundation

public struct Hub {}

public extension Hub {
    enum HubClientError: Error {
        case parse
        case authorizationRequired
        case unexpectedError
        case httpStatusCode(Int)
    }
    
    enum RepoType: String {
        case models
        case datasets
        case spaces
    }
    
    struct Repo {
        let id: String
        let type: RepoType
        
        public init(id: String, type: RepoType = .models) {
            self.id = id
            self.type = type
        }
    }
}

// MARK: - Configuration files with dynamic lookup

@dynamicMemberLookup
public struct Config {
    public private(set) var dictionary: [String: Any]

    public init(_ dictionary: [String: Any]) {
        self.dictionary = dictionary
    }

    func camelCase(_ string: String) -> String {
        return string
            .split(separator: "_")
            .enumerated()
            .map { $0.offset == 0 ? $0.element.lowercased() : $0.element.capitalized }
            .joined()
    }
    
    func uncamelCase(_ string: String) -> String {
        let scalars = string.unicodeScalars
        var result = ""
        
        var previousCharacterIsLowercase = false
        for scalar in scalars {
            if CharacterSet.uppercaseLetters.contains(scalar) {
                if previousCharacterIsLowercase {
                    result += "_"
                }
                let lowercaseChar = Character(scalar).lowercased()
                result += lowercaseChar
                previousCharacterIsLowercase = false
            } else {
                result += String(scalar)
                previousCharacterIsLowercase = true
            }
        }
        
        return result
    }


    public subscript(dynamicMember member: String) -> Config? {
        let key = dictionary[member] != nil ? member : uncamelCase(member)
        if let value = dictionary[key] as? [String: Any] {
            return Config(value)
        } else if let value = dictionary[key] {
            return Config(["value": value])
        }
        return nil
    }

    public var value: Any? {
        return dictionary["value"]
    }
    
    public var intValue: Int? { value as? Int }
    public var boolValue: Bool? { value as? Bool }
    public var stringValue: String? { value as? String }
    
    // Instead of doing this we could provide custom classes and decode to them
    public var arrayValue: [Config]? {
        guard let list = value as? [Any] else { return nil }
        return list.map { Config($0 as! [String : Any]) }
    }
}

public class LanguageModelConfigurationFromHub {
    struct Configurations {
        var modelConfig: Config
        var tokenizerConfig: Config?
        var tokenizerData: Config
    }

    private var configPromise: Task<Configurations, Error>? = nil

    public init(modelName: String) {
        self.configPromise = Task.init {
            return try await self.loadConfig(modelName: modelName)
        }
    }

    public var modelConfig: Config {
        get async throws {
            try await configPromise!.value.modelConfig
        }
    }

    public var tokenizerConfig: Config? {
        get async throws {
            if let hubConfig = try await configPromise!.value.tokenizerConfig {
                // Try to guess the class if it's not present and the modelType is
                if let _ = hubConfig.tokenizerClass?.stringValue { return hubConfig }
                guard let modelType = try await modelType else { return hubConfig }
                var configuration = hubConfig.dictionary
                configuration["tokenizer_class"] = "\(modelType.capitalized)Tokenizer"
                return Config(configuration)
            }

            // Fallback tokenizer config, if available
            guard let modelType = try await modelType else { return nil }
            return Self.fallbackTokenizerConfig(for: modelType)
        }
    }

    public var tokenizerData: Config {
        get async throws {
            try await configPromise!.value.tokenizerData
        }
    }

    public var modelType: String? {
        get async throws {
            try await modelConfig.modelType?.stringValue
        }
    }

    func loadConfig(modelName: String, hfToken: String? = nil) async throws -> Configurations {
        let hubApi = HubApi(hfToken: hfToken)
        let filesToDownload = ["config.json", "tokenizer_config.json", "tokenizer.json"]
        let repo = Hub.Repo(id: modelName)
        try await hubApi.snapshot(from: repo, matching: filesToDownload)

        // Note tokenizerConfig may be nil (does not exist in all models)
        let modelConfig = try hubApi.configuration(from: "config.json", in: repo)
        let tokenizerConfig = try? hubApi.configuration(from: "tokenizer_config.json", in: repo)
        let tokenizerVocab = try hubApi.configuration(from: "tokenizer.json", in: repo)
        
        let configs = Configurations(modelConfig: modelConfig, tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerVocab)
        return configs
    }

    static func fallbackTokenizerConfig(for modelType: String) -> Config? {
        guard let url = Bundle.module.url(forResource: "\(modelType)_tokenizer_config", withExtension: "json") else { return nil }
        do {
            let data = try Data(contentsOf: url)
            let parsed = try JSONSerialization.jsonObject(with: data, options: [])
            guard let dictionary = parsed as? [String: Any] else { return nil }
            return Config(dictionary)
        } catch {
            return nil
        }
    }
}
