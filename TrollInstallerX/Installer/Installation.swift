//
//  Installation.swift
//  TrollInstallerX
//
//  Created by Alfie on 22/03/2024.
//

import Foundation

let fileManager = FileManager.default
let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].path
let kernelPath = docsDir + "/kernelcache"


func checkForMDCUnsandbox() -> Bool {
    return fileManager.fileExists(atPath: docsDir + "/full_disk_access_sandbox_token.txt")
}

func getKernel(_ device: Device) -> Bool {
    if !fileManager.fileExists(atPath: kernelPath) {
        if MacDirtyCow.supports(device) && checkForMDCUnsandbox() {
            let fd = open(docsDir + "/full_disk_access_sandbox_token.txt", O_RDONLY)
            if fd > 0 {
                let tokenData = get_NSString_from_file(fd)
                sandbox_extension_consume(tokenData)
                Logger.log("Copying kernelcache")
                let path = get_kernelcache_path()
                do {
                    try fileManager.copyItem(atPath: path!, toPath: kernelPath)
                    return true
                } catch {
                    Logger.log("Failed to copy kernelcache", type: .error)
                    NSLog("Failed to copy kernelcache - \(error)")
                }
            }
        }
        Logger.log("Downloading kernel")
        if !grab_kernelcache(kernelPath) {
            Logger.log("Failed to download kernel", type: .error)
            return false
        }
    }
    
    return true
}


func cleanup_private_preboot() -> Bool {
    // Remove /private/preboot/tmp
    let fileManager = FileManager.default
    do {
        try fileManager.removeItem(atPath: "/private/preboot/tmp")
    } catch let e {
        print("Failed to remove /private/preboot/tmp! \(e.localizedDescription)")
        return false
    }
    return true
}

func selectExploit(_ device: Device) -> Exploit {
    let flavour = (UserDefaults.standard.string(forKey: "exploitFlavour") ?? (physpuppet.supports(device) ? "physpuppet" : "landa"))
    if flavour == "landa" { return landa }
    if flavour == "physpuppet" { return physpuppet }
    if flavour == "smith" { return smith }
    return landa
}

func modelIdentifier() -> String {
    if let simulatorModelIdentifier = ProcessInfo().environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulatorModelIdentifier }
    var sysinfo = utsname()
    uname(&sysinfo) // ignore return value
    return String(bytes: Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN)), encoding: .ascii)!.trimmingCharacters(in: .controlCharacters)
}

func getCandidates() -> [InstalledApp] {
    var apps = [InstalledApp]()
    for candidate in persistenceHelperCandidates {
        if candidate.isInstalled { apps.append(candidate) }
    }
    return apps
}

@discardableResult
func doInstall(_ device: Device) async -> Bool {
    
    let exploit = selectExploit(device)
    
    let iOS14 = !device.version.supportsMajorVersion(15)
    let supportsFullPhysRW = (device.isArm64e && device.version >= Version(major: 15, minor: 2)) || (!device.isArm64e && device.version.supportsMajorVersion(15))
    
    Logger.log("Running on an \(modelIdentifier()) on iOS \(device.version.readableString)")
    
    if !iOS14 {
        if !(getKernel(device)) {
            Logger.log("Failed to get kernel", type: .error)
            return false
        }
    }
    
    Logger.log("Gathering kernel information")
    if !initialise_kernel_info(kernelPath, iOS14) {
        Logger.log("Failed to patchfind kernel", type: .error)
        return false
    }
    
    Logger.log("Exploiting kernel (\(exploit.name))")
    if !exploit.initialise!() {
        Logger.log("Failed to exploit the kernel", type: .error)
        return false
    }
    Logger.log("Successfully exploited the kernel", type: .success)
    post_kernel_exploit(iOS14)
    
    var trollstoreTarData: Data?
    if FileManager.default.fileExists(atPath: docsDir + "/TrollStore.tar") {
        trollstoreTarData = try? Data(contentsOf: docsURL.appendingPathComponent("TrollStore.tar"))
    }
    
    if supportsFullPhysRW {
        if device.isArm64e {
            Logger.log("Bypassing PPL (\(dmaFail.name))")
            if !dmaFail.initialise!() {
                Logger.log("Failed to bypass PPL", type: .error)
                return false
            }
            Logger.log("Successfully bypassed PPL", type: .success)
        }
        
        if #available(iOS 16, *) {
            libjailbreak_kalloc_pt_init()
        }
        
        if !build_physrw_primitive() {
            Logger.log("Failed to build physical R/W primitive", type: .error)
            return false
        }
        
        if device.isArm64e {
            Logger.log("Deinitialising PPL bypass (\(dmaFail.name))")
            if !dmaFail.deinitialise!() {
                Logger.log("Failed to deinitialise \(dmaFail.name)", type: .error)
                return false
            }
        }
        
        Logger.log("Deinitialising kernel exploit (\(exploit.name))")
        if !exploit.deinitialise!() {
            Logger.log("Failed to deinitialise \(exploit.name)", type: .error)
            return false
        }
        
        Logger.log("Unsandboxing")
        if !unsandbox() {
            Logger.log("Failed to unsandbox", type: .error)
            return false
        }
        
        Logger.log("Escalating privileges")
        if !get_root_pplrw() {
            Logger.log("Failed to escalate privileges", type: .error)
            return false
        }
        if !platformise() {
            Logger.log("Failed to platformise", type: .error)
            return false
        }
    } else {
        
        Logger.log("Unsandboxing and escalating privileges")
        if !get_root_krw(iOS14) {
            Logger.log("Failed to unsandbox and escalate privileges", type: .error)
            return false
        }
    }
    
    remount_private_preboot()
    
    if let data = trollstoreTarData {
        do {
            try FileManager.default.createDirectory(atPath: "/private/preboot/tmp", withIntermediateDirectories: false)
            FileManager.default.createFile(atPath: "/private/preboot/tmp/TrollStore.tar", contents: nil)
            try data.write(to: URL(string: "file:///private/preboot/tmp/TrollStore.tar")!)
        } catch {
            print("Failed to write out TrollStore.tar - \(error.localizedDescription)")
        }
    }
    
    // Prevents download finishing between extraction and installation
    let useLocalCopy = FileManager.default.fileExists(atPath: "/private/preboot/tmp/TrollStore.tar")

    if !fileManager.fileExists(atPath: "/private/preboot/tmp/trollstorehelper") {
        Logger.log("Extracting TrollStore.tar")
        if !extract_trollstore(useLocalCopy) {
            Logger.log("Failed to extract TrollStore.tar", type: .error)
            return false
        }
    }
    
    DispatchQueue.main.sync {
        HelperAlert.shared.showAlert = true
        HelperAlert.shared.objectWillChange.send()
    }
    while HelperAlert.shared.showAlert { }
    let persistenceID = UserDefaults.standard.string(forKey: "persistenceHelper")
    
    if persistenceID != "" {
        if install_persistence_helper(persistenceID) {
            Logger.log("Successfully installed persistence helper", type: .success)
        } else {
            Logger.log("Failed to install persistence helper", type: .error)
        }
    }
    
    Logger.log("Installing TrollStore")
    if !install_trollstore(useLocalCopy ? "/private/preboot/tmp/TrollStore.tar" : Bundle.main.bundlePath + "/TrollStore.tar") {
        Logger.log("Failed to install TrollStore", type: .error)
    } else {
        Logger.log("Successfully installed TrollStore", type: .success)
    }
    
    if !cleanup_private_preboot() {
        Logger.log("Failed to clean up /private/preboot", type: .error)
    }
    
    if !supportsFullPhysRW {
        if !drop_root_krw(iOS14) {
            Logger.log("Failed to drop root privileges", type: .error)
            return false
        }
        Logger.log("Deinitialising kernel exploit (\(exploit.name))")
        if !exploit.deinitialise!() {
            Logger.log("Failed to deinitialise \(exploit.name)", type: .error)
            return false
        }
    }
    
    return true
}
