import Foundation
import InkFlowDictionary
import InkFlowPortable

// Both Rust staticlibs (libinkflow_rime.a and libinkflow_dictionary.a) and the source-built
// librime must link into one process; the app cutover depends on it.
let engineABI = ifr_abi_version()
let dictionaryRecipe = ifd_recipe_version()
precondition(engineABI > 0, "ifr_abi_version returned \(engineABI)")
precondition(dictionaryRecipe > 0, "ifd_recipe_version returned \(dictionaryRecipe)")
print("PASS portable-abi-tests: libinkflow_rime ABI \(engineABI) and inkflow_dictionary recipe \(dictionaryRecipe) in one binary")
