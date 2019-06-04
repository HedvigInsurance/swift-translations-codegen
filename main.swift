#!/usr/bin/env swift

import Foundation

let colorWhite = "\u{001B}[0;0m"
let colorRed = "\u{001B}[0;31m"
let colorYellow = "\u{001B}[0;33m"
let colorGreen = "\u{001B}[0;32m"

let currrentVersion = "1.0.0"

let cwd = FileManager.default.currentDirectoryPath
let swiftTranslationsCodegenVersionCheckPath = "\(cwd)/.swiftTranslationsCodegen"

if FileManager.default.fileExists(atPath: swiftTranslationsCodegenVersionCheckPath) {
    let requiredVersion = try String(contentsOf: URL(fileURLWithPath: swiftTranslationsCodegenVersionCheckPath), encoding: .utf8).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    
    if requiredVersion != currrentVersion && CommandLine.arguments.index(of: "--ignore-versions") == nil {
        print("\(colorRed)Project requires version '\(requiredVersion)' but you are running '\(currrentVersion)' adjust '.swiftTranslationsCodegen' or pass '--ignore-versions'")
        exit(1)
    }
}

let placeholderRegex = try NSRegularExpression(pattern: "(\\{[a-zA-Z0-9_]+\\})")
let placeholderKeyRegex = try NSRegularExpression(pattern: "([a-zA-Z0-9_]+)")

if CommandLine.arguments.index(of: "--help") != nil {
    print("""
        \(colorWhite)Hedvig Translations Codegen
        
        Arguments:
        \(colorWhite)--projects: The projects you want to fetch translations for (for example: "[App, IOS]") \u{001B}[0;31mREQUIRED
        \(colorWhite)--destination: Full path of desired destination for generated Swift file (including ".swift", for example "translations/translations.swift") \(colorRed)REQUIRED
        \(colorWhite)--swiftformat-path: The path to the Swiftformat CLI \(colorYellow)OPTIONAL
        \(colorWhite)--curl-path: The path to Curl \(colorYellow)OPTIONAL
        \(colorWhite)--ignore-versions: Ignores checking '.swiftTranslationsCodegen' version \(colorYellow)OPTIONAL
        \(colorWhite)--default-language: Set's the default language in Localization.Language \(colorYellow)OPTIONAL
        \(colorWhite)--exclude-objc-apis: Excludes features that depends on the Obj-c runtime \(colorYellow)OPTIONAL
        """)
    exit(1)
}

if CommandLine.arguments.index(of: "--projects") == nil {
    print("\(colorRed)You need to pass in argument '--projects'")
    exit(1)
}

if CommandLine.arguments.index(of: "--destination") == nil {
    print("\(colorRed)You need to pass in argument '--destination'")
    exit(1)
}

let excludeObjcAPIs = CommandLine.arguments.index(of: "--exclude-objc-apis") != nil

let swiftFormatCLIArgumentIndex = CommandLine.arguments.index(of: "--swiftformat-path")
let swiftFormatCLIPath = swiftFormatCLIArgumentIndex != nil ? CommandLine.arguments[swiftFormatCLIArgumentIndex! + 1] : "/usr/local/bin/swiftformat"

let curlCLIArgumentIndex = CommandLine.arguments.index(of: "--curl-path")
let curlCLIPath = curlCLIArgumentIndex != nil ? CommandLine.arguments[curlCLIArgumentIndex! + 1] : "/usr/bin/curl"

if !FileManager.default.fileExists(atPath: swiftFormatCLIPath) {
    print("\(colorRed)Swiftformat not installed at '\(swiftFormatCLIPath)'")
    exit(1)
}

if !FileManager.default.fileExists(atPath: curlCLIPath) {
    print("\(colorRed)Curl not installed at '\(curlCLIPath)'")
    exit(1)
}

let projects = CommandLine.arguments[CommandLine.arguments.index(of: "--projects")! + 1]
let destination = CommandLine.arguments[CommandLine.arguments.index(of: "--destination")! + 1]

let defaultLanguageArgumentIndex = CommandLine.arguments.index(of: "--default-language")
let defaultLanguage = defaultLanguageArgumentIndex == nil ? nil : CommandLine.arguments[defaultLanguageArgumentIndex! + 1]

let curlTask = Process()

curlTask.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
curlTask.arguments = [
    "-s",
    "https://api-euwest.graphcms.com/v1/cjmawd9hw036a01cuzmjhplka/master",
    "-H",
    "Accept-Encoding: gzip",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Accept: */*",
    "-H",
    "Connection: keep-alive",
    "--data-binary",
    """
    {"query":"query AppTranslationsMeta { languages { code translations(where: { project_in: \(projects) }) { text key { value translations { text } } language { code } } } keys(where: { translations_some: { project_in: \(projects) } }) { value description translations { text } } }","variables":null,"operationName":"AppTranslationsMeta"}
    """,
    "--compressed",
]

let outPipe = Pipe()
curlTask.standardOutput = outPipe

curlTask.launch()

let jsonData = outPipe.fileHandleForReading.readDataToEndOfFile()

curlTask.waitUntilExit()

struct GraphCMSTranslation: Decodable {
    let text: String
    let key: GraphCMSKey?
}

struct GraphCMSLanguage: Decodable {
    let code: String
    let translations: [GraphCMSTranslation]
}

struct GraphCMSKey: Decodable {
    let value: String
    let description: String?
    let translations: [GraphCMSTranslation]
}

struct GraphCMSData: Decodable {
    let languages: [GraphCMSLanguage]
    let keys: [GraphCMSKey]
}

struct GraphCMSRoot: Decodable {
    let data: GraphCMSData
}

let graphCMSRoot = try? JSONDecoder().decode(GraphCMSRoot.self, from: jsonData)

guard let graphCMSRoot = graphCMSRoot else {
    let plainJsonRepsonse = String(data: jsonData, encoding: .utf8)
    print("\(colorRed)Could not fetch translations from GraphCMS correctly, returned response was: \n\n\(colorWhite)\(plainJsonRepsonse ?? "nil")")
    exit(1)
}

func findReplacements(_ text: String) -> [String] {
    let range = NSRange(location: 0, length: text.utf16.count)
    
    let results = placeholderRegex.matches(in: text, options: [], range: range)
    
    return Array(Set(results.compactMap {
        String(text[Range($0.range, in: text)!])
    })).sorted { $0 < $1 }
}

func removeCurlyBraces(_ text: String, replaceOpeningWith: String = "", replaceClosingWith: String = "") -> String {
    return text.replacingOccurrences(of: "{", with: replaceOpeningWith).replacingOccurrences(of: "}", with: replaceClosingWith)
}

extension String {
    public func camelCased(with separator: Character) -> String {
        if !self.contains(separator) {
            return self.prefix(self.count).allSatisfy { char in ("A"..."Z").contains(char) } ? self.lowercased() : self
        }

        return self.lowercased()
            .split(separator: separator)
            .enumerated()
            .map { $0.offset > 0 ? $0.element.capitalized : $0.element.lowercased() }
            .joined()
    }
}

/// removes curly braces from replacements and camelCases them
func cleanReplacements(_ replacements: [String]) -> [String] {
    return replacements
        .map { removeCurlyBraces($0) }
        .map { $0.camelCased(with: "_") }
}

func indent(_ string: String, _ numberOfIndents: Int) -> String {
    var resultingString = "\(string)"
    
    for _ in 0 ... numberOfIndents {
        resultingString = " \(resultingString)"
    }
    
    return resultingString
}

func languageEnumCases() -> String {
    let cases = graphCMSRoot.data.languages.map { language -> String in
        let enumCase = indent("case \(language.code)", 6)
        
        if language.code == graphCMSRoot.data.languages.last!.code {
            return enumCase
        }
        
        return "\(enumCase)\n"
    }
    
    return cases.joined(separator: "")
}

func keysEnumCases() -> String {
    let keys = graphCMSRoot.data.keys.filter { key in
        if key.translations.count == 0 {
            return false
        }
        
        return true
    }.map { key -> String in
        print("\(colorGreen)Generating: \(key.value)\n")
        print("\(colorWhite)\(key.description ?? "")\n\n")
        
        let description = key.description != nil ? "\(indent("/// \(key.description ?? "")", 6))\n" : ""
        
        let replacementArguments = graphCMSRoot.data.languages.map { language -> [GraphCMSTranslation] in
            return language.translations.filter { $0.key?.value != nil }.filter { $0.key!.value == key.value }
            }.flatMap { $0.map { findReplacements($0.text) } }.flatMap { $0 }
        
        if replacementArguments.count != 0 {
            let argumentNames = cleanReplacements(replacementArguments)
            let argumentNamesSyntax = Array(Set(argumentNames)).sorted { $0 < $1 }.map { "\($0): String" }.joined(separator: ", ")
            
            return "\(description)\(indent("case \(key.value)(\(argumentNamesSyntax))", 6))"
        }
        
        return "\(description)\(indent("case \(key.value)", 6))"
    }
    
    return keys.joined(separator: "\n")
}

func languageStructs() -> String {
    func getStaticForFunc(_ content: String) -> String {
        let switchStatementEnd = indent("}", 10)
        let switchStatement = indent("switch key {\n\(content)\n\(switchStatementEnd)", 10)
        return indent("""
            static func `for`(key: Localization.Key) -> String {\n\(switchStatement)\n\(indent("}", 8))
            """, 8)
    }
    
    func getSwitchCases(_ language: GraphCMSLanguage) -> String {
        var handledKeys: [String] = []
        
        let switchCases: [String] = language.translations.filter { 
            if $0.key?.value == nil {
                print("\(colorYellow)WARNING \(colorWhite)hanging translation with the value: \(colorYellow)\"\($0.text)\"\(colorWhite)\n")
                return false
            }

            return true
         }.filter {
            if handledKeys.contains($0.key!.value) {
                return false
            }

            handledKeys.append($0.key!.value)
            return true
        }.filter { translation in
            let key = graphCMSRoot.data.keys.first { key in key.value == translation.key!.value }
            
            if key == nil {
                print("\(colorYellow)WARNING \(colorWhite)hanging translation that is referencing key: \(colorYellow)\(translation.key!.value)\(colorWhite), it had the value: \(colorYellow)\"\(translation.text)\"\(colorWhite)\n")
                return false
            }
            
            return true
            }.map { translation in
                let replacements = findReplacements(translation.text)
                var translationsRepoReplacements = replacements
                    .map { removeCurlyBraces($0) }
                    .map { name in "\"\(name)\": \(name.camelCased(with: "_"))" }.joined(separator: ", ")
                
                if translationsRepoReplacements.count == 0 {
                    translationsRepoReplacements = ":"
                }
                
                let translationsRepoReturnStatement = indent("return text", 12)
                let translationsRepoClosingBracket = indent("}", 10)
                let translationsRepo = indent("""
                    if let text = TranslationsRepo.findWithReplacements(key, replacements: [\(translationsRepoReplacements)]) {
                    \(translationsRepoReturnStatement)
                    \(translationsRepoClosingBracket)
                    
                    """, 10)
                
                var fallbackInterpolation = removeCurlyBraces(translation.text, replaceOpeningWith: "\\(", replaceClosingWith: ")")

                replacements.map { removeCurlyBraces($0) }.forEach {
                    fallbackInterpolation = fallbackInterpolation.replacingOccurrences(of: "\\(\($0))", with: "\\(\($0.camelCased(with: "_")))")
                }

                let fallbackValue = indent("""
                    return \"\"\"
                    \(indent(fallbackInterpolation, 10))
                    \(indent("\"\"\"", 10))
                    """, 10)
                
                let body = "\(translationsRepo)\n\(fallbackValue)"
                
                if replacements.count != 0 {
                    let arguments = cleanReplacements(replacements).map { "\($0)" }.joined(separator: ", ")
                    return indent("case let .\(translation.key!.value)(\(arguments)):\n\(body)\n", 12)
                }
                
                return indent("case .\(translation.key!.value):\n\(body)\n", 12)
            }
        
        let switchCasesString = switchCases.joined(separator: "").dropLast(1)
        let defaultStatement = language.translations.count < graphCMSRoot.data.keys.count ? indent("default: return String(describing: key)", 12) : ""
        
        return "\(String(switchCasesString))\n\(defaultStatement)"
    }
    
    let structs = graphCMSRoot.data.languages.map {
        indent("""
            struct \($0.code) {
            \(getStaticForFunc(getSwitchCases($0)))\n
            """, 6)
        }.map { "\($0)\(indent("}\n", 6))" }.joined()
    
    return String(structs.dropLast(1))
}

func getLocalizationKeyReflection() -> String {
    if excludeObjcAPIs {
        return ""
    }
    
    return """
    static var localizationKey: UInt8 = 0

    var localizationKey: Localization.Key? {
        get {
            guard let value = objc_getAssociatedObject(
                self,
                &String.localizationKey
            ) as? Localization.Key? else {
                return nil
            }

            return value
        }
        set(newValue) {
            objc_setAssociatedObject(
                self,
                &String.localizationKey,
                newValue,
                objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
    """
}

let output = """
// Generated automagically, don't edit yourself

import Foundation

// swiftlint:disable identifier_name type_body_length type_name line_length nesting file_length

extension String {
    \(getLocalizationKeyReflection())

    init(key: Localization.Key, locale: Localization.Locale = Localization.Locale.currentLocale) {
        switch locale {
            \(graphCMSRoot.data.languages.map { "case .\($0.code): self = Localization.Translations.\($0.code).for(key: key)" }.joined(separator: "\n"))
        }

        \(excludeObjcAPIs ? "" : "localizationKey = key")
    }
}

public struct Localization {
enum Locale: String, CaseIterable {
    static var currentLocale: Locale = .\(defaultLanguage != nil ? defaultLanguage! : graphCMSRoot.data.languages.first!.code)
\(languageEnumCases())
}

enum Key {
\(keysEnumCases())
}

struct Translations {
\(languageStructs())
}
}
"""

let file: ()? = try? output.write(toFile: "\(destination)", atomically: true, encoding: .utf8)

if file == nil {
    print("\(colorRed)Couldn't write file to destination '\(destination)'")
    exit(1)
}

let swiftFormatTask = Process()
swiftFormatTask.executableURL = URL(fileURLWithPath: "/usr/local/bin/swiftformat")
swiftFormatTask.arguments = [destination, "--quiet"]

swiftFormatTask.launch()

swiftFormatTask.waitUntilExit()

print("\(colorGreen)File generation completed!")
print("\(colorWhite)")

