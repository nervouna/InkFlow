use std::{env, path::PathBuf};

fn main() {
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let prefix = root
        .join("../../build/portable/prefix")
        .canonicalize()
        .expect("Run python3 Core/Portable/build-native.py first");
    let lib = prefix.join("lib");
    for file in ["libinkflow_rime_bridge.a", "librime.so", "librime.dylib"] {
        println!("cargo:rerun-if-changed={}", lib.join(file).display());
    }
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=static=inkflow_rime_bridge");
    println!("cargo:rustc-link-lib=dylib=rime");
    match env::var("CARGO_CFG_TARGET_OS").unwrap().as_str() {
        "linux" => println!("cargo:rustc-link-lib=dylib=stdc++"),
        "macos" => println!("cargo:rustc-link-lib=dylib=c++"),
        _ => panic!("Only Linux and macOS have been enabled"),
    }
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib.display());
}
