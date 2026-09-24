#!/usr/bin/env python3
"""Cross-process ad-hoc identity recovery using uniquely named fixture records."""
import os, pathlib, subprocess, tempfile, uuid
root=pathlib.Path(__file__).resolve().parent.parent
fixture=str(uuid.uuid4()).upper(); suite='com.cookzhang.LuckySQL.fixture.'+fixture
source=r'''
import Foundation
import Security
@main struct Probe {
 static func main() async throws {
  let args=CommandLine.arguments, id=UUID(uuidString: args[2])!, defaults=UserDefaults(suiteName: args[3])!
  let raw=KeychainStore(), recovering=RecoveringPasswordStore(defaults: defaults)
  setbuf(stdout, nil)
  switch args[1] {
  case "seed": try await raw.save("fixture-only", for: id)
  case "recover":
   do { _ = try await raw.password(for: id); print("Old identity remains readable on this host") }
   catch { print("Old identity read rejected: \((error as? KeychainError)?.status ?? -1)") }
   do { try await recovering.save("replacement-fixture", for: id) } catch { print("Recovery failed: \(error)"); throw error }
   guard try await recovering.password(for: id)=="replacement-fixture" else { fatalError("Recovery read failed") }
   print("Replacement saved and read; rotated=\(defaults.string(forKey: "passwordRecord.\(id.uuidString)") != nil)")
  case "verify":
   guard try await recovering.password(for: id)=="replacement-fixture" else { fatalError("Cross-process read failed") }
   print("Fresh process reads recovered secret")
  case "clean-new": try await recovering.deletePassword(for: id); defaults.removePersistentDomain(forName: args[3])
  case "clean-old": try await raw.deletePassword(for: id)
  default: fatalError("Unknown probe")
  }
 }
}
'''
with tempfile.TemporaryDirectory(prefix='luckysql-keychain-') as folder:
 p=pathlib.Path(folder); (p/'Probe.swift').write_text(source)
 env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(root/'Sources/LuckySQL/Infrastructure/KeychainStore.swift'),str(root/'Sources/LuckySQL/Infrastructure/RecoveringPasswordStore.swift'),str(p/'Probe.swift'),'-o',str(p/'old')],env=env,check=True)
 subprocess.run(['cp',str(p/'old'),str(p/'new')],check=True)
 for name in ['old','new']:
  subprocess.run(['codesign','--force','--sign','-','--identifier',suite+'.'+name,str(p/name)],check=True)
 def probe(binary,action,check=True):return subprocess.run([str(p/binary),action,fixture,suite],check=check)
 try:
  probe('old','seed');probe('new','recover');probe('new','verify')
 finally:
  probe('new','clean-new',False);probe('old','clean-old',False)
