/**
       This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
       Copyright © Adguard Software Limited. All rights reserved.
 
       Adguard for iOS is free software: you can redistribute it and/or modify
       it under the terms of the GNU General Public License as published by
       the Free Software Foundation, either version 3 of the License, or
       (at your option) any later version.
 
       Adguard for iOS is distributed in the hope that it will be useful,
       but WITHOUT ANY WARRANTY; without even the implied warranty of
       MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
       GNU General Public License for more details.
 
       You should have received a copy of the GNU General Public License
       along with Adguard for iOS.  If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation

// MARK: - service protocol
/**
 ContentBlockerService is responsible for the composition of safari content blocker rules files
 */
protocol ContentBlockerServiceProtocol {
    /**
     recompile all content blocker files and reloads it to safari
    */
    func reloadJsons(backgroundUpdate: Bool, completion:@escaping (Error?)->Void)
    
    /**
     validates rule text
     It returns true if rule can be converted to safari content blocker rule by converter, false for unsupported rules
     */
    func validateRule(_ ruleText: String)->Bool
}

@objc
class ContentBlockerService: NSObject, ContentBlockerServiceProtocol {
    
    var antibanner: AESAntibannerProtocol
    
    // MARK: - error constants
    static let contentBlockerServiceErrorDomain = "ContentBlockerServiceErrorDomain"
    static let contentBlockerConverterErrorCode = 1
    static let contentBlockerDBErrorCode = 2
    
    // MARK: - private properties
    private var resources: AESharedResourcesProtocol
    private var safariService: SafariServiceProtocol
    private var rulesProcessor: RulesProcessorProtocol = RulesProcessor()
    private var safariProtection: SafariProtectionServiceProtocol
    
    private let workQueue = DispatchQueue(label: "content_blocker")
    
    static let groupsByContentBlocker: [ContentBlockerType: [Int]] =
            [.general:                      [FilterGroupId.ads, FilterGroupId.languageSpecific, FilterGroupId.user],
             .privacy:                      [FilterGroupId.privacy, FilterGroupId.user],
             .socialWidgetsAndAnnoyances:   [FilterGroupId.socialWidgets, FilterGroupId.annoyances, FilterGroupId.user],
             .other:                        [FilterGroupId.other, FilterGroupId.user],
             .custom:                       [FilterGroupId.custom, FilterGroupId.user],
             .security:                     [FilterGroupId.security, FilterGroupId.user]
            ]
    
    static let defaultsCountKeyByBlocker: [ContentBlockerType: String] = [
        .general:                       AEDefaultsGeneralContentBlockerRulesCount,
        .privacy:                       AEDefaultsPrivacyContentBlockerRulesCount,
        .socialWidgetsAndAnnoyances:    AEDefaultsSocialContentBlockerRulesCount,
        .other:                         AEDefaultsOtherContentBlockerRulesCount,
        .custom:                        AEDefaultsCustomContentBlockerRulesCount,
        .security:                      AEDefaultsSecurityContentBlockerRulesCount
    ]
    
    static let defaultsOverLimitCountKeyByBlocker: [ContentBlockerType: String] = [
        .general:                       AEDefaultsGeneralContentBlockerRulesOverLimitCount,
        .privacy:                       AEDefaultsPrivacyContentBlockerRulesOverLimitCount,
        .socialWidgetsAndAnnoyances:    AEDefaultsSocialContentBlockerRulesOverLimitCount,
        .other:                         AEDefaultsOtherContentBlockerRulesOverLimitCount,
        .custom:                        AEDefaultsCustomContentBlockerRulesOverLimitCount,
        .security:                      AEDefaultsSecurityContentBlockerRulesOverLimitCount
    ]
    
    // MARK: - init
    init(resources: AESharedResourcesProtocol, safariService: SafariServiceProtocol, antibanner: AESAntibannerProtocol, safariProtection: SafariProtectionServiceProtocol) {
        self.resources = resources
        self.safariService = safariService
        self.antibanner = antibanner
        self.safariProtection = safariProtection
        super.init()
    }
    
    // MARK: - public methods
    @objc
    func reloadJsons(backgroundUpdate: Bool, completion:@escaping (Error?)->Void) {
        DDLogInfo("(ContentBlockerService) reloadJsons")
        
#if !APP_EXTENSION
        let backgroundTaskId = UIApplication.shared.beginBackgroundTask { }
#endif
        
        workQueue.async { [weak self] in
            guard let self = self else { return }
            
            let error = self.updateContentBlockers(background: backgroundUpdate)
#if !APP_EXTENSION
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
#endif
            completion(error)
            return            
        }
    }
    
    func validateRule(_ ruleText: String) -> Bool {
        
        let trimmedRule = ruleText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedRule.count == 0 {
            return false
        }
        
        if  trimmedRule.contains(OLD_INJECT_RULES) ||
            trimmedRule.contains(MASK_CONTENT_RULE) ||
            trimmedRule.contains(MASK_CONTENT_EXCEPTION_RULE) ||
            trimmedRule.contains(MASK_JS_RULE) ||
            trimmedRule.contains(MASK_FILTER_UNSUPPORTED_RULE){
            return false
        }
        
        return true
    }

    // MARK: - whitelist operations
    
    /**
     Adds whitelist domain, modifies content blocking JSONs
     and replaces these JSONs in shared resources asynchronously.
     Method performs completionBlock when done on service working queue.
     */
    func addWhitelistDomain(_ domain: String, completion: @escaping (Error?)->Void) {
        
        processWhitelistDomain(domain, enabled: true, completion: completion, processRules: {(rules) in
            let rule = AEWhitelistDomainObject(domain: domain).rule
            rule.isEnabled = NSNumber(booleanLiteral: true)
            
            return (rules + [rule], true)
        }, processData: { [weak self] (jsonData, jsonRuleData, contentBlocker) in
            guard let sSelf = self else { return Data() }
            
            let converted = sSelf.resources.sharedDefaults().integer(forKey: ContentBlockerService.defaultsCountKeyByBlocker[contentBlocker]!)
            let limit = sSelf.resources.sharedDefaults().integer(forKey: AEDefaultsJSONMaximumConvertedRules)
            let overlimit = converted == limit
                
            let (resultData, _) = sSelf.rulesProcessor.addDomainToWhitelist(domain: domain, enabled: true, jsonData: jsonData as Data, overlimit: overlimit)
            
            return resultData ?? Data()
        })
    }
    
    
    
    func removeWhitelistDomain(_ domain: String, completion: @escaping (Error?)->Void) {
        
        processWhitelistDomain(domain, enabled: false, completion: completion, processRules: {(rules) in
            var found = false
            let rule = AEWhitelistDomainObject(domain: domain).rule
            let resultRules = rules.filter() { (testRule) in
                if rule.isEqualRuleText(testRule) {
                    found = true
                    return false
                }
                return true
            }
            return (resultRules, found)
        }, processData: { [weak self] (jsonData, domain, _) in
            guard let sSelf = self else { return Data() }
            
            let (resultJsonData, _) = sSelf.rulesProcessor.removeWhitelistDomain(domain: domain, jsonData: jsonData)
            
            return resultJsonData ?? Data()
        })
    }
    
    func replaceWhitelistDomain(_ domain: String, with newDomain: String, enabled: Bool, completion: @escaping (Error?)->Void) {
        processWhitelistDomain(domain, enabled: enabled, completion: completion, processRules: {(rules) in
            var found = false
            let rule = AEWhitelistDomainObject(domain: domain).rule
            let resultRules = rules.map() { (testRule)->ASDFilterRule in
                if rule.isEqualRuleText(testRule) {
                    found = true
                    let newRule = AEWhitelistDomainObject(domain: newDomain).rule
                    newRule.isEnabled = NSNumber(booleanLiteral: enabled)
                    return newRule
                }
                return testRule
            }
            return (resultRules, found)
        }, processData: { [weak self] (jsonData, ruleData, _) in
            guard let sSelf = self else { return jsonData }
            
            let (removed, _) = sSelf.rulesProcessor.removeWhitelistDomain(domain: domain, jsonData: jsonData)
            
            let (result, _) = sSelf.rulesProcessor.addDomainToWhitelist(domain: newDomain, enabled: enabled, jsonData: removed ?? Data(), overlimit: false)
            
            return result ?? Data()
        })
    }
    
    // MARK: - inverted whitelist rules
    
    func addInvertedWhitelistDomain(_ domain: String, completion: @escaping (Error?)->Void) {
        
        processInvertedWhitelistDomain(processRules: { (rules) -> ([ASDFilterRule], Bool) in
            var newRules = rules
            newRules.append(ASDFilterRule(text: domain, enabled: true))
            return (newRules, true)
        }, processData: { [weak self] (jsonData, contentBlocker) -> Data in
            guard let self = self else { return Data() }
            let converted = self.resources.sharedDefaults().integer(forKey: ContentBlockerService.defaultsCountKeyByBlocker[contentBlocker]!)
            let limit = self.resources.sharedDefaults().integer(forKey: AEDefaultsJSONMaximumConvertedRules)
            let overlimit = converted == limit
            
            let (data, _) = self.rulesProcessor.addDomainToInvertedWhitelist(rule: domain, jsonData: jsonData, overlimit: overlimit)
            
            return data ?? Data()
            
        }) { (error) in
            completion(error)
        }
    }
    
    func removeInvertedWhitelistDomain(_ ruleToRemove: String, completion: @escaping (Error?)->Void) {
    
        processInvertedWhitelistDomain(processRules: { (rules) -> ([ASDFilterRule], Bool) in
            let filteredDomains = rules.filter({ (rule) -> Bool in
                return ruleToRemove != rule.ruleText
            })
            return(filteredDomains, true)
        }, processData: { [weak self] (jsonData, contentBlocker) -> Data in
            guard let sSelf = self else { return Data() }
            
            let (data, _) = sSelf.rulesProcessor.removeInvertedWhitelistDomain(rule: ruleToRemove, jsonData: jsonData)
            
            return data ?? Data()
        }) { (error) in
            completion(error)
        }
    }
    
    // MARK: - private methods
    
    private func updateContentBlockers(background: Bool)->Error? {
        
        DDLogInfo("(ContentBlockerService) updateContentBlockers")
        let filtersByGroup = activeGroups()
        let allFilters = filtersByGroup.flatMap { $0.value }
        let rulesByFilter = rules(forFilters: allFilters)
        
        // get map of rules by content blocker
        var rulesByContentBlocker = [ContentBlockerType: [ASDFilterRule]]()
        var rulesByAffinityBlocks = [ContentBlockerType: [ASDFilterRule]]()
        
        for (contentBlocker, groups) in ContentBlockerService.groupsByContentBlocker {
            var contentBlockerRules = [ASDFilterRule]()
            for groupID in groups {
                
                guard let filters = filtersByGroup[groupID as NSNumber] else { continue }
                for filterID in filters {
                    
                    guard let filterRules = rulesByFilter[filterID] else { continue }
                    sortWithAffinityBlocks(filterRules: filterRules, contentBlockerRules: &contentBlockerRules, rulesByAffinityBlocks: &rulesByAffinityBlocks)
                }
            }
            
            rulesByContentBlocker[contentBlocker] = contentBlockerRules
        }
        
        for type in ContentBlockerType.allCases {
            if rulesByContentBlocker[type] == nil {
                rulesByContentBlocker[type] = [ASDFilterRule]()
            }
            rulesByContentBlocker[type]?.append(contentsOf: rulesByAffinityBlocks[type] ?? [])
        }
        
        return convertRulesAndInvalidateSafari(background: background,rulesByContentBlocker: rulesByContentBlocker)
    }
    
    private func convertRulesAndInvalidateSafari(background: Bool, rulesByContentBlocker: [ContentBlockerType: [ASDFilterRule]])->Error? {
        var resultError: Error?
        
        let concurrentQueue = DispatchQueue(label: "update_cb", attributes: DispatchQueue.Attributes.concurrent)
        let group = DispatchGroup()
        
        // run conversion to jsons in concurrent queue.
        for type in ContentBlockerType.allCases {
            group.enter()
            concurrentQueue.async { [weak self] in
                guard let self = self else { return }
                
                let error = self.updateJson(blockerRules: rulesByContentBlocker[type]!, forContentBlocker: type)
                
                if error == nil {
                    if background {
                        group.leave()
                    }
                    else {
                        // immediately update the safari without waiting for the conversion of other jsons
                        self.safariService.invalidateBlockingJson(type: type) { (error) in
                            if error != nil {
                                resultError = error
                            }
                            group.leave()
                        }
                    }
                }
                else {
                    resultError = error
                    group.leave()
                }
            }
        }
        
        group.wait()
        
        let result = resultError == nil ? "SUCCCESS" : "FAILURE"
        DDLogInfo("(ContentBlockerService) convertRulesAndInvalidateSafari - all content blockers are updated. Result - \(result)")
        
        return resultError
    }
    
    private func sortWithAffinityBlocks(filterRules: [ASDFilterRule], contentBlockerRules: inout [ASDFilterRule], rulesByAffinityBlocks: inout [ContentBlockerType: [ASDFilterRule]]) {
        
        for rule in filterRules {
            if rule.affinity != nil {
                
                for type in ContentBlockerType.allCases {
                    let affinity = affinityMaskByContentBlockerType[type]
                    if (affinity != nil) {
                        if (rule.affinity == 0 || Affinity(rawValue: UInt8(truncating: rule.affinity!)).contains(affinity!)) {
                            if rulesByAffinityBlocks[type] == nil {
                                rulesByAffinityBlocks[type] = [ASDFilterRule]()
                            }
                            rulesByAffinityBlocks[type]?.append(rule)
                        }
                    }
                }
                
            } else {
                contentBlockerRules.append(rule)
            }
        }
    }
    
    private let affinityMaskByContentBlockerType: [ContentBlockerType: Affinity] =
        [.general: Affinity.general,
         .privacy: Affinity.privacy,
         .socialWidgetsAndAnnoyances: Affinity.socialWidgetsAndAnnoyances,
         .other: Affinity.other,
         .custom: Affinity.custom,
         .security: Affinity.security ]
    
    private func updateJson(blockerRules: [ASDFilterRule], forContentBlocker contentBlocker: ContentBlockerType)->Error? {
        DDLogInfo("(ContentBlockerService) updateJson for contentBlocker \(contentBlocker) rulesCount: \(blockerRules.count)")
        
        let safariProtectionEnabled = safariProtection.safariProtectionEnabled
        
        if safariProtectionEnabled{
            return autoreleasepool {
                var rules = blockerRules
                
                // add user rules
                
                let userFilterEnabled = resources.safariUserFilterEnabled
                
                let userRules = userFilterEnabled ? antibanner.activeRules(forFilter: ASDF_USER_FILTER_ID as NSNumber) : [ASDFilterRule]()
                
                
                DDLogInfo("(ContentBlockerService) updateJson append \(userRules.count) user rules")
                
                rules = userRules + rules
                
                // add whitelist rules
                
                let inverted = resources.sharedDefaults().bool(forKey: AEDefaultsInvertedWhitelist)
                
                let whitelistEnabled = resources.safariWhitelistEnabled
                
                if whitelistEnabled {
                    if inverted {
                        
                        if resources.invertedWhitelistContentBlockingObject == nil {
                            resources.invertedWhitelistContentBlockingObject = AEInvertedWhitelistDomainsObject(rules: [])
                        }
                        
                        if let invertedRule = resources.invertedWhitelistContentBlockingObject?.rule {
                            DDLogInfo("(ContentBlockerService) updateJson append inverted whitelist rule")
                            rules.append(invertedRule)
                        }
                    }
                    else {
                        if let whitelistRules = resources.whitelistContentBlockingRules {
                            DDLogInfo("(ContentBlockerService) updateJson append \(whitelistRules.count) user rules")
                            rules.append(contentsOf: whitelistRules as! [ASDFilterRule])
                        }
                    }
                }
                
                var resultData = Data()
                var resultError: Error?
                if rules.count != 0 {
                    DDLogInfo("(ContentBlockerService) updateJson - convert \(rules.count) rules")
                    let (jsonData, converted, overLimit, _, error) = convertRulesToJson(rules)
                    resources.sharedDefaults().set(overLimit, forKey: ContentBlockerService.defaultsOverLimitCountKeyByBlocker[contentBlocker]!)
                    
                    if jsonData != nil { resultData = jsonData! }
                    resources.sharedDefaults().set(converted, forKey: ContentBlockerService.defaultsCountKeyByBlocker[contentBlocker]!)
                    
                    resultError = error
                    if error != nil {
                        DDLogError("(ContentBlockerService) updateJson - error converting rules - \(error!.localizedDescription)")
                    }
                } else {
                    DDLogInfo("(ContentBlockerService) updateJson - no rules to convert")
                    resources.sharedDefaults().set(0, forKey: ContentBlockerService.defaultsOverLimitCountKeyByBlocker[contentBlocker]!)
                    resources.sharedDefaults().set(0, forKey: ContentBlockerService.defaultsCountKeyByBlocker[contentBlocker]!)
                }
                
                safariService.save(json: resultData, type: contentBlocker)
                
                return resultError
            }
        } else {
            DDLogInfo("(ContentBlockerService) updateJson safari protection is disabled. Save empty data instead of rules json")
            safariService.save(json: Data(), type: contentBlocker)
            return nil
        }
    }
    
    /** returns map [filterID: [Rule]]*/
    private func rules(forFilters filterIDs: [NSNumber]) -> [NSNumber: [ASDFilterRule]] {
        var rulesByFilter = [NSNumber: [ASDFilterRule]]()
        
        for filterID in filterIDs {
            rulesByFilter[filterID] = antibanner.activeRules(forFilter: filterID)
        }
        
        return rulesByFilter
    }
    
    /** returns map [groupId: [filterId]] */
    private func activeGroups()->[NSNumber: [NSNumber]] {
        var filterByGroup = [NSNumber:[NSNumber]]()
        
        let groupIDs = antibanner.activeGroupIDs()
        
        for groupID in groupIDs {
            let filterIDs = antibanner.activeFilterIDs(byGroupID: groupID)
            filterByGroup[groupID] = filterIDs
        }
        
        return filterByGroup
    }
    
    private func processWhitelistDomain(_ domain: String, enabled: Bool, completion: @escaping (Error?)->Void, processRules: @escaping(_ rules: [ASDFilterRule])->([ASDFilterRule], Bool), processData: @escaping(_ jsonData: Data, _ domain: String, _ contentBlocker: ContentBlockerType)->Data) {
        
        workQueue.async { [weak self] in
            guard let sSelf = self else { return }
            
            var error: Error?
            var modified = false
            
            var savedDatas:[ContentBlockerType: Data] = [:]
            var savedRules:[ASDFilterRule] = []
            
            var rollback: ()->Void = {
                for (_, obj) in savedDatas.enumerated() {
                    sSelf.safariService.save(json: obj.value, type: obj.key)
                    sSelf.resources.whitelistContentBlockingRules = (savedRules as NSArray).mutableCopy() as? NSMutableArray
                }
            }
            
            defer {
            
                if error != nil {
                    sSelf.finishReloadingConetentBlocker(completion: completion, error: error)
                    rollback()
                }
                else if error == nil && modified {
                    sSelf.safariService.invalidateBlockingJsons { (error) in
                        sSelf.finishReloadingConetentBlocker(completion: completion, error: error)
                        
                        if error != nil {
                            rollback()
                            sSelf.safariService.invalidateBlockingJsons { (error) in
                            }
                        }
                    }
                }
                else {
                    sSelf.finishReloadingConetentBlocker(completion: completion, error: error)
                }
            }
            
            var whitelistRules = sSelf.resources.whitelistContentBlockingRules as? [ASDFilterRule] ?? []
            savedRules = Array(whitelistRules)
            var succeded = false
            (whitelistRules, succeded) = processRules(whitelistRules)
            
            if !succeded {
                error = NSError(domain: ContentBlockerService.contentBlockerServiceErrorDomain,
                               code: ContentBlockerService.contentBlockerDBErrorCode,
                               userInfo: [NSLocalizedDescriptionKey: ACLocalizedString("support_unexpected_error", "")])
                return
            }
            
            sSelf.resources.whitelistContentBlockingRules = (whitelistRules as NSArray).mutableCopy() as? NSMutableArray
            
            // change all content blocker jsons
            ContentBlockerType.allCases.forEach { (type) in
                autoreleasepool {
                    guard let data = sSelf.safariService.readJson(forType: type) else { return }
                    savedDatas[type] = data
                    let jsonData = processData(data, domain, type)
                    
                    sSelf.safariService.save(json: jsonData as Data, type: type)
                }
            }
            
            modified = true
            return
        }
    }
    
    private func processInvertedWhitelistDomain(processRules: @escaping(_ rules: [ASDFilterRule])->([ASDFilterRule], Bool), processData: @escaping(_ jsonData: Data, _ contentBlocker: ContentBlockerType)->Data, completion: @escaping (Error?)->Void) {
        
        workQueue.async { [weak self] in
            guard let sSelf = self else { return }
            
            var error: Error?
            var modified = false
            
            var savedDatas:[ContentBlockerType: Data] = [:]
            let invertedObject = sSelf.resources.invertedWhitelistContentBlockingObject
            
            var rollback: ()->Void = {
                for (_, obj) in savedDatas.enumerated() {
                    sSelf.safariService.save(json: obj.value, type: obj.key)
                    sSelf.resources.invertedWhitelistContentBlockingObject = invertedObject
                }
            }
            
            defer {
                
                if error != nil {
                    sSelf.finishReloadingConetentBlocker(completion: completion, error: error)
                    rollback()
                }
                else if error == nil && modified {
                    sSelf.safariService.invalidateBlockingJsons { (error) in
                        sSelf.finishReloadingConetentBlocker(completion: completion, error: error)
                    }
                }
                else {
                    sSelf.finishReloadingConetentBlocker(completion: completion, error: error)
                }
            }
            
            var rules = invertedObject?.rules ?? []
        
            var succeded = false
            (rules, succeded) = processRules(rules)
            
            if !succeded {
                error = NSError(domain: ContentBlockerService.contentBlockerServiceErrorDomain,
                                code: ContentBlockerService.contentBlockerDBErrorCode,
                                userInfo: [NSLocalizedDescriptionKey: ACLocalizedString("support_unexpected_error", "")])
                return
            }
            
            let newInvertedObject = AEInvertedWhitelistDomainsObject(rules: rules)
        
            sSelf.resources.invertedWhitelistContentBlockingObject = newInvertedObject
            
            // change all content blocker jsons
            ContentBlockerType.allCases.forEach { (type) in
                autoreleasepool {
                    guard let data = sSelf.safariService.readJson(forType: type) else { return }
                    savedDatas[type] = data
                    
                    let jsonData = processData(data, type)
                    
                    sSelf.safariService.save(json: jsonData, type: type)
                }
            }
            
            modified = true
            return
        }
    }
    
    private func finishReloadingConetentBlocker(completion: ((Error?)->Void)?, error: Error?) {
        workQueue.async {
            if completion != nil {
                self.workQueue.async {
                    completion!(error)
                }
            }
        }
    }
    
    private func convertRulesToJson(_ rules: [ASDFilterRule])->(data: Data?, converted: Int, overlimit: Int, totalConverted: Int, error: Error?) {
        
        NotificationCenter.default.post(name: NSNotification.Name.ShowStatusView, object: self, userInfo: [AEDefaultsShowStatusViewInfo : ACLocalizedString("converting_rules", nil)])
        
        defer {
            NotificationCenter.default.post(name: NSNotification.Name.HideStatusView, object: self)
        }
        
        var error: Error?
        var converted = 0
        var overLimit = 0
        var totalConverted = 0
        var rulesData: Data?
        
        if rules.count == 0 {
            return (nil, 0, 0, 0, NSError(domain: ContentBlockerService.contentBlockerServiceErrorDomain, code: 0, userInfo: [:]))
        }
        
        // run converter
        let limit = UInt(resources.sharedDefaults().integer(forKey: AEDefaultsJSONMaximumConvertedRules))
        let optimize = resources.sharedDefaults().bool(forKey: AEDefaultsJSONConverterOptimize)
        
        let (converter, converterError) = createConverter()
        if converterError != nil {
            return (nil, 0, 0, 0, converterError)
        }
        
        if converter == nil {
            error = NSError(domain: ContentBlockerService.contentBlockerServiceErrorDomain,
                            code: ContentBlockerService.contentBlockerConverterErrorCode,
                            userInfo: nil)
            return (nil, 0, 0, 0, error)
        }
        
        let converterResult = converter!.json(fromRules: rules, upTo: limit, optimize: optimize) as? [String: Any]
        
        error = converterResult?[AESFConvertedErrorKey] as? Error
        if error != nil {
            return (nil, 0, 0, 0, error)
        }
        
        converted = converterResult?[AESFConvertedCountKey] as? Int ?? 0
        totalConverted = converterResult?[AESFTotalConvertedCountKey] as? Int ?? 0
        overLimit = totalConverted - converted
        
        // obtain rules
        let jsonString = converterResult?[AESFConvertedRulesKey] as? String
        if jsonString == nil || jsonString! == "undefined" {
            error = NSError(domain: ContentBlockerService.contentBlockerServiceErrorDomain,
                            code: ContentBlockerService.contentBlockerConverterErrorCode,
                            userInfo: nil)
            return (nil, 0, 0, 0, error)
        }
        
        rulesData = jsonString?.data(using: .utf8)
        
        return (rulesData, converted, overLimit, totalConverted, error)
    }
    
    func replaceUserFilter(_ rules: [ASDFilterRule])->Error? {
        
        let success = antibanner.import(rules, filterId: ASDF_USER_FILTER_ID as NSNumber)
        
        return success ? nil : NSError(domain: ContentBlockerService.contentBlockerServiceErrorDomain,
                       code: ContentBlockerService.contentBlockerDBErrorCode,
                       userInfo: [NSLocalizedDescriptionKey: ACLocalizedString("support_unexpected_error", "")])
    }
    
    func convertOneRule(_ rule: ASDFilterRule)->([String: Any]?, Error?) {
        
        let optimize = resources.sharedDefaults().bool(forKey: AEDefaultsJSONConverterOptimize)
                    
        var convertResult: [String: Any]?
        
        let (converter, converterError) = createConverter()
        if converterError != nil { return (nil, converterError) }
        
        convertResult = converter!.json(fromRules: [rule], upTo: 1, optimize: optimize) as? [String: Any]
        
        if let error = convertResult?[AESFConvertedErrorKey] as? Error { return (nil, error) }
        
        let convertedCount = convertResult?[AESFConvertedCountKey] as? Int
        let errorsCount = convertResult?[AESErrorsCountKey] as? Int
        
        if convertedCount == 0 || errorsCount ?? 0 > 0 {
            let errorDescription = ACLocalizedString("rule_converting_error", nil)
            let error = NSError(domain: ContentBlockerService.contentBlockerServiceErrorDomain,
                                code: ContentBlockerService.contentBlockerConverterErrorCode,
                            userInfo: [NSLocalizedDescriptionKey: errorDescription])
            return(nil, error)
        }
        
        return (convertResult, nil)
    }
    
    var createConverter:()->(AESFilterConverterProtocol?, Error?) = {
        
        guard let converter = AESFilterConverter() else {
            DDLogError("(ContentBlockerService) Can't initialize converter to JSON format!")
            let errorDescription = ACLocalizedString("json_converting_error", nil)
            let error = NSError(domain: ContentBlockerService.contentBlockerServiceErrorDomain,
                                code: ContentBlockerService.contentBlockerConverterErrorCode,
                                userInfo: [NSLocalizedDescriptionKey: errorDescription])
            return (nil, error)
        }
        
        return (converter, nil)
    }
}
