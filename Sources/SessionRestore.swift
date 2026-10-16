import Foundation

@MainActor extension AppDelegate {
    // Disconnect/quit can invalidate an in-flight commit even after its panel closes.
    func commitRestoredSession(generation:Int,serviceInstall:@MainActor () async->Void,engineInstall:@MainActor () async->Void) async->Bool {
        guard !Task.isCancelled,generation==sessionGeneration else {return false}
        await serviceInstall()
        guard !Task.isCancelled,generation==sessionGeneration else {return false}
        await engineInstall()
        return !Task.isCancelled && generation==sessionGeneration
    }
}
