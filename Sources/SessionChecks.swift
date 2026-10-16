import AppKit
import Security
import LocalAuthentication

@MainActor extension AppDelegate {
    func checkSessionStorage(_ path:String) async {
        var checks:[String:Any]=[:]
        let fixture=SessionCredentials(cookie:"SAPISID=synthetic-persistence-fixture",authUser:"0",pageID:nil,browserCookies:[BrowserCookie(name:"SAPISID",value:"synthetic-persistence-fixture",domain:".youtube.com",path:"/",secure:true,httpOnly:true,expires:4_000_000_000,sameSite:"None")])
        do {
            let encoded=try JSONEncoder().encode(fixture)
            var initialInteraction:DarwinBoolean=false
            let initialStatus=SecKeychainGetUserInteractionAllowed(&initialInteraction)
            let oldMarker=UserDefaults.standard.object(forKey:"google-session-executable.v4")
            defer {if let oldMarker {UserDefaults.standard.set(oldMarker,forKey:"google-session-executable.v4")} else {UserDefaults.standard.removeObject(forKey:"google-session-executable.v4")}}
            UserDefaults.standard.set("previous-build-hash",forKey:"google-session-executable.v4")
            var readCalled=false,noninteractive=false,legacyNoninteractive=false
            let restored=try KeychainSession.load(reader:{query in
                readCalled=true;noninteractive=(query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed==true
                var legacy:DarwinBoolean=true;legacyNoninteractive=SecKeychainGetUserInteractionAllowed(&legacy)==errSecSuccess && !legacy.boolValue
                return (errSecSuccess,encoded)
            })
            checks["staleBuildMarkerDoesNotBlockRestore"]=readCalled && restored?.cookie==fixture.cookie && restored?.browserCookies?.count==1
            checks["startupNeverPromptsKeychain"]=noninteractive
            checks["legacyKeychainStartupNeverPrompts"]=legacyNoninteractive
            var interactionAllowed=false,legacyInteractionAllowed=false
            let interactive=try KeychainSession.load(allowInteraction:true,reader:{query in
                interactionAllowed=(query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed==false
                var legacy:DarwinBoolean=false;legacyInteractionAllowed=SecKeychainGetUserInteractionAllowed(&legacy)==errSecSuccess && legacy.boolValue
                return (errSecSuccess,encoded)
            })
            checks["explicitRestoreAllowsMacOSAuthorization"]=interactionAllowed && legacyInteractionAllowed && interactive?.cookie==fixture.cookie
            checks["absentItemReturnsNil"]=try KeychainSession.load(reader:{_ in (errSecItemNotFound,nil)})==nil
            for status in [errSecInteractionNotAllowed,errSecAuthFailed,errSecUserCanceled] {
                var needsAccess=false
                do {_=try KeychainSession.load(reader:{_ in (status,nil)})}catch SessionAccessError.authorizationRequired {needsAccess=true}
                checks["permissionStatus\(status)PreservesRecovery"]=needsAccess
            }
            var malformedRejected=false
            do {_=try KeychainSession.load(reader:{_ in (errSecSuccess,Data("invalid".utf8))})}catch {malformedRejected=true}
            checks["malformedSessionIsNotAccepted"]=malformedRejected
            var finalInteraction:DarwinBoolean=false
            checks["keychainInteractionRestoredAfterSuccessAndErrors"]=initialStatus==errSecSuccess && SecKeychainGetUserInteractionAllowed(&finalInteraction)==errSecSuccess && initialInteraction.boolValue==finalInteraction.boolValue
            showConnection()
            checks["restoreButtonPresent"]=connection?.restore.title=="Відновити збережений вхід" && connection?.restore.isEnabled==true
            cancelConnection()
            let generation=sessionGeneration
            var engineTouched=false
            let cancelledCommit=await commitRestoredSession(generation:generation,serviceInstall:{self.sessionGeneration+=1},engineInstall:{engineTouched=true})
            checks["invalidatedServiceCommitDoesNotTouchEngine"] = !cancelledCommit && !engineTouched
            var installedService=false,installedEngine=false
            let successfulCommit=await commitRestoredSession(generation:sessionGeneration,serviceInstall:{installedService=true},engineInstall:{installedEngine=installedService})
            checks["validSessionCommitInstallsServiceThenEngine"]=successfulCommit && installedService && installedEngine
            if let identifier=argument("--session-fixture-id"),UUID(uuidString:identifier) != nil,let phase=argument("--session-fixture-phase") {
                // This namespace is test-only. Never read, change or delete the personal session.
                let query:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.retroamp.qa.persistence",kSecAttrAccount as String:identifier]
                switch phase {
                case "seed":
                    var add=query;add[kSecValueData as String]=encoded;add[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                    checks["realKeychainSeed"]=SecItemAdd(add as CFDictionary,nil)==errSecSuccess
                    checks["realKeychainRead"]=try KeychainSession.loadItem(query,allowInteraction:false)?.cookie==fixture.cookie
                case "read":
                    checks["realKeychainSurvivedProcessRestart"]=try KeychainSession.loadItem(query,allowInteraction:false)?.cookie==fixture.cookie
                case "update":
                    do {checks["updatedBuildRecoversWithoutGoogle"]=try KeychainSession.loadItem(query,allowInteraction:false)?.cookie==fixture.cookie}
                    catch SessionAccessError.authorizationRequired {
                        checks["updatedBuildRequiresMacOSPermissionInsteadOfGoogle"]=true
                    }
                case "cleanup":
                    checks["updateAttemptPreservedSavedSession"]=try KeychainSession.loadItem(query,allowInteraction:false)?.cookie==fixture.cookie
                    checks["testItemRemoved"]=SecItemDelete(query as CFDictionary)==errSecSuccess
                default:checks["validPhase"]=false
                }
            }
        } catch {checks["error"]=error.localizedDescription}
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true};writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}
